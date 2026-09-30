defmodule SymphonyElixir.InstanceRegistry do
  @moduledoc """
  The instances the **hub** started: one JSON state file, and the operations over it.

  `Projects` says what this machine declares and `ProjectStatus` says what is answering right now.
  Neither can start or stop anything, and neither should: a table that can kill a process has to say
  *which* process it started, and that memory did not exist. This module is that memory --
  `~/code/symphony-instances.json`, one record per project the hub launched:

      {"version": 1,
       "instances": [
         {"project": "alpha", "workflow": ".../alpha.md", "port": 4003, "pid": 21456,
          "logs_root": ".../symphony-logs/alpha", "started_at": "2026-05-01T09:12:44Z"}
       ]}

  ## A record is not a running project

  A record means **the hub started that pid**, and nothing else. It is not evidence that the project
  is up: `ProjectStatus` is what answers that, by asking the instance's own `GET /api/v1/state`, and
  that answer is the only thing the page trusts. A record whose pid is gone is stale, and stale
  records are dropped -- at boot by `reconcile/1`, and again the moment a start or a stop looks at
  them -- so a crashed instance never leaves a row that claims the hub controls something that is
  not there.

  ## The boundaries, enforced here rather than described

    1. **Only registry-listed files.** `start_instance/2` takes a *project name* and looks the file
       up in `Projects`; there is no argument -- including a browser event -- that names a workflow
       path directly. A name the registry does not list is refused.
    2. **Loopback only.** A workflow that declares a `server.host` other than loopback is refused
       before anything is spawned. The hub adds no host override of its own (the CLI has no such
       switch), so the file's own host would otherwise be the whole answer -- and a `0.0.0.0` here
       would put an agent's HTTP surface on every interface of this machine.
    3. **No auto-start.** Nothing here runs at boot except `reconcile/1`, which only ever *drops*.
       An instance starts because a person pressed the button.
    4. **Nothing is inferred.** A port comes from the file or from the scan in `allocate/1`, a pid
       comes from the launcher's answer, and "running" comes from the instance's own state route.
       None of the three is guessed, and a record is never upgraded into a fact about a process.
    5. **The hub does not touch what it did not start.** The only pid it will ever kill is one in
       this file, under the name it was recorded with, and `stoppable?/2` refuses the hub's own port
       and its own process outright: the instance serving the page that offers the button is never a
       stop target.

  ## The injections

  Four functions have working defaults and are replaced in tests, the same way `ProjectStatus`
  injects its HTTP client -- so no test spawns a process, opens a socket or kills anything:
  `:launcher` (`launch/1`), `:held?` (`held?/1`), `:alive?` (`alive?/1`) and `:kill`
  (`Shell.kill_tree/1`). `:file`, `:records`, `:projects` and `:own_port` bypass the state file, the
  registry read and this instance's own port configuration.

  ## Ports

  `allocate/1` is pure apart from the `held?` check it is handed: given what the project declares,
  the ports the hub already holds, and that check, it decides. The decision is testable without a
  socket; the "is it held" part is the one thing that has to ask the operating system, because a
  table of who holds which port does not exist and would be wrong the moment anything else on the
  machine binds a port.
  """

  alias SymphonyElixir.{CLI, Config, Projects, Shell, Workflow}
  alias SymphonyElixir.Config.Schema

  @file_name "symphony-instances.json"
  @file_version 1
  @default_dir "~/code"
  @default_logs_dir "~/code/symphony-logs"

  # The block the hub hands ports out of: above the privileged ports, and the same one
  # `Projects.next_free_port/1` suggests from, so a suggestion and an assignment cannot disagree.
  @port_start 4001
  @port_end 4099

  @loopback_hosts ["127.0.0.1", "localhost", "::1", "[::1]"]

  # How long a start waits to see whether the shell it spawned died immediately. `cmd` stays alive
  # for as long as the instance does, so an exit inside this window means the instance never started.
  @settle_ms 300

  @typedoc "One recorded instance: the pid the hub started, and where it put it."
  @type instance :: %{
          project: String.t(),
          workflow: String.t(),
          port: pos_integer(),
          pid: pos_integer(),
          logs_root: String.t(),
          started_at: String.t() | nil
        }

  @typedoc "What a launcher is handed: everything it needs, and nothing it has to look up."
  @type launch_spec :: %{
          project: String.t(),
          workflow: String.t(),
          port: pos_integer(),
          logs_root: String.t()
        }

  @typedoc "Starts a process for a spec and answers its pid, or why it could not."
  @type launcher :: (launch_spec() -> {:ok, pos_integer()} | {:error, term()})

  # ── the state file ───────────────────────────────────────────────────────────

  @doc "Where the hub keeps its records. `config :symphony_elixir, :instances_file` to move it."
  @spec file(keyword()) :: Path.t()
  def file(opts \\ []) do
    Keyword.get(opts, :file) ||
      Application.get_env(:symphony_elixir, :instances_file) ||
      Path.expand(Path.join(@default_dir, @file_name))
  end

  @doc """
  Every record, keyed by project name.

  `:records` bypasses the file -- for a caller that already read it, and for tests -- and `:file`
  moves it. A file that is missing, empty, or not the shape above is `%{}`: a state file nobody can
  parse must not take the control plane down with it.
  """
  @spec records(keyword()) :: %{optional(String.t()) => instance()}
  def records(opts \\ []) do
    Keyword.get(opts, :records) || read(file(opts))
  end

  @doc "Reads a state file. Anything that is not a usable record is left out rather than guessed at."
  @spec read(Path.t()) :: %{optional(String.t()) => instance()}
  def read(path) when is_binary(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         instances when is_list(instances) <- decoded["instances"] do
      instances
      |> Enum.map(&normalize/1)
      |> Enum.reject(&is_nil/1)
      |> Map.new(&{&1.project, &1})
    else
      _other -> %{}
    end
  rescue
    _error -> %{}
  end

  @doc """
  Writes the records, atomically: a temporary file is renamed over the old one, so a reader sees
  either the whole old file or the whole new one, never half of each.
  """
  @spec write(%{optional(String.t()) => instance()}, Path.t()) :: :ok | {:error, term()}
  def write(records, path) when is_map(records) and is_binary(path) do
    body =
      Jason.encode!(%{
        "version" => @file_version,
        "instances" => records |> Map.values() |> Enum.sort_by(& &1.project)
      })

    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, body) do
      replace(tmp, path)
    end
  rescue
    error -> {:error, {:instances_write_raised, Exception.message(error)}}
  end

  # `File.rename/2` does replace an existing file on Windows (measured 2026-05-01), but a failed
  # rename must not cost the state file: the fallback removes the old one first, which leaves a
  # window only for the process that is already writing.
  defp replace(tmp, path) do
    case File.rename(tmp, path) do
      :ok ->
        :ok

      {:error, _reason} ->
        _ = File.rm(path)
        File.rename(tmp, path)
    end
  end

  defp normalize(raw) when is_map(raw) do
    record = %{
      project: raw["project"],
      workflow: raw["workflow"],
      port: raw["port"],
      pid: raw["pid"],
      logs_root: raw["logs_root"],
      started_at: raw["started_at"]
    }

    if usable?(record), do: record
  end

  defp normalize(_raw), do: nil

  # A record without a pid or a port is not something the hub can stop or ask, so it is not a record.
  defp usable?(%{project: project, workflow: workflow, logs_root: root, port: port, pid: pid}) do
    is_binary(project) and project != "" and is_binary(workflow) and is_binary(root) and
      is_integer(port) and port > 0 and is_integer(pid) and pid > 0
  end

  # ── boot ─────────────────────────────────────────────────────────────────────

  @doc """
  The boot step: a record whose pid is gone is stale and is dropped.

  Adoption is the *absence* of a drop: a pid that is still alive keeps its record, so "the hub
  started this" stays true across a hub restart, and a later stop still reaches it. Nothing else is
  inferred -- in particular a kept record is **not** turned into "running", because only the
  instance's own state route can say that.

  Answers what it did (`%{kept: names, dropped: names}`) and never raises: a hub whose state file is
  nonsense still has to boot. The file is rewritten only when something was actually dropped.
  """
  @spec reconcile(keyword()) :: %{kept: [String.t()], dropped: [String.t()]}
  def reconcile(opts \\ []) do
    records = records(opts)
    alive? = alive_fun(opts)

    {kept, dropped} = Enum.split_with(records, fn {_name, record} -> alive?.(record.pid) end)

    if dropped != [] do
      _ = write(Map.new(kept), file(opts))
    end

    %{kept: names(kept), dropped: names(dropped)}
  rescue
    _error -> %{kept: [], dropped: []}
  end

  defp names(pairs), do: pairs |> Enum.map(&elem(&1, 0)) |> Enum.sort()

  # ── port allocation ──────────────────────────────────────────────────────────

  @doc """
  Which port the hub gives a project. Pure apart from the `held?` check it is handed.

  The project's own `server.port` wins when it declares one and nothing holds it; otherwise the
  first port from #{@port_start} up to #{@port_end} that is neither in `taken` (the ports the hub
  already holds -- its own and every record's) nor held by anything else. `{:error, :no_free_port}`
  when the whole range is gone, which is a refusal a person can act on rather than a port that would
  make the instance die at startup.
  """
  @spec allocate(keyword()) :: {:ok, pos_integer()} | {:error, :no_free_port}
  def allocate(opts \\ []) do
    declared = Keyword.get(opts, :declared)
    taken = Keyword.get(opts, :taken, [])
    held? = Keyword.get(opts, :held?) || (&held?/1)

    if declared_port?(declared) and declared not in taken and not held?.(declared) do
      {:ok, declared}
    else
      first_free(taken, held?)
    end
  end

  defp first_free(taken, held?) do
    @port_start..@port_end
    |> Enum.find(fn port -> port not in taken and not held?.(port) end)
    |> case do
      nil -> {:error, :no_free_port}
      port -> {:ok, port}
    end
  end

  defp declared_port?(port), do: is_integer(port) and port > 0 and port <= 65_535

  @doc """
  Whether something already holds `port` on loopback.

  Binding it is the only honest test: `:eaddrinuse` is the answer, and closing immediately leaves a
  window of microseconds. It is the test `Projects.free?/1` makes, inverted -- anything holding the
  port (another service, a stale instance, a container) reads as held.
  """
  @spec held?(term()) :: boolean()
  def held?(port) when is_integer(port) and port > 0 do
    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true, active: false]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        false

      {:error, _reason} ->
        true
    end
  end

  def held?(_port), do: true

  # ── liveness ─────────────────────────────────────────────────────────────────

  @doc """
  Whether `pid` is a process on this machine.

  Windows answers with `tasklist` (CSV, so a localized machine's wording is not parsed); elsewhere
  `/proc` answers. Both are asked a real question -- "does this pid exist" -- rather than inferred
  from the fact that some port answers.
  """
  @spec alive?(term()) :: boolean()
  def alive?(pid) when is_integer(pid) and pid > 0 do
    if Shell.windows?(), do: alive_windows?(pid), else: File.dir?("/proc/#{pid}")
  end

  def alive?(_pid), do: false

  defp alive_windows?(pid) do
    args = ["/FI", "PID eq #{pid}", "/FO", "CSV", "/NH"]

    case System.cmd("tasklist", args, stderr_to_stdout: true) do
      {output, 0} -> String.contains?(output, "\"#{pid}\"")
      _other -> false
    end
  rescue
    _error -> false
  end

  # ── start ────────────────────────────────────────────────────────────────────

  @doc """
  Starts the instance for a registry project and records it.

  Refuses, with a reason a person can read, when the project is not in the registry, when its
  workflow does not validate, when it listens outside loopback, when it is already running under the
  hub's control, or when no port can be found.

  The record is written **after** the process is up; a process that could not be recorded is stopped
  again rather than left as something no one can turn off.
  """
  @spec start_instance(String.t(), keyword()) :: {:ok, instance()} | {:error, String.t()}
  def start_instance(name, opts \\ []) when is_binary(name) do
    records = records(opts)

    with {:ok, project} <- registered(name, opts),
         :ok <- loopback_only(project),
         {:ok, records} <- claimable(name, records, opts),
         :ok <- valid_workflow(project.path),
         {:ok, port} <- pick_port(project, records, opts),
         spec = launch_spec(project, name, port, opts),
         {:ok, pid} <- run_launcher(spec, opts) do
      record_or_stop(records, new_record(name, project.path, spec, pid), opts)
    end
  rescue
    error -> {:error, "starting #{name} failed: #{Exception.message(error)}"}
  catch
    kind, reason -> {:error, "starting #{name} exited: #{kind} #{inspect(reason)}"}
  end

  # The registry is the only source of a workflow path. The name comes from the caller (a browser
  # event on a button), so it is looked up rather than trusted.
  defp registered(name, opts) do
    rows = Keyword.get(opts, :projects) || Projects.list(probe: false)

    case Enum.find(rows, &(&1.name == name)) do
      nil ->
        {:error,
         "no project named #{name} in the registry (#{Projects.registry_dir()}) -- the hub starts only " <>
           "workflow files the registry lists, never a path handed to it"}

      project ->
        {:ok, project}
    end
  end

  defp loopback_only(project) do
    host = project[:host]

    if is_nil(host) or (is_binary(host) and String.downcase(host) in @loopback_hosts) do
      :ok
    else
      {:error,
       "#{project.name} declares server.host #{inspect(host)}: the hub starts only instances that " <>
         "listen on loopback (#{Enum.join(@loopback_hosts, ", ")})"}
    end
  end

  # Two answers in one place because they are one question: is this project already up under the
  # hub's control? A record whose pid is alive says yes -- starting a second instance would put two
  # orchestrators on one queue and two janitors on one ticket repository. A record whose pid is gone
  # is stale: it is dropped here, and starting is allowed again.
  defp claimable(name, records, opts) do
    case Map.get(records, name) do
      nil ->
        {:ok, records}

      record ->
        if alive_fun(opts).(record.pid) do
          {:error,
           "#{name} is already running under this hub's control (pid #{record.pid}, port #{record.port}); " <>
             "stop it first"}
        else
          pruned = Map.delete(records, name)
          _ = write(pruned, file(opts))
          {:ok, pruned}
        end
    end
  end

  # The application's own validator, not a second one: `Workflow.load/1` + `Schema.parse/1` are the
  # pair `Projects.load/1` uses and the pair an instance runs at startup, and the two prompt rules
  # are the two `mix workflow.check` adds on top. It cannot render the *candidate's* template --
  # `PromptBuilder` renders this instance's -- so a leftover `{{` is caught as the shape of an
  # unresolved variable instead, which is the same failure one step earlier.
  defp valid_workflow(path) do
    with {:ok, loaded} <- Workflow.load(path),
         {:ok, _settings} <- Schema.parse(loaded.config),
         :ok <- prompt_body(loaded.prompt) do
      :ok
    else
      {:error, reason} -> {:error, "#{Path.basename(path)} does not validate: #{describe(reason)}"}
    end
  end

  defp prompt_body(prompt) when is_binary(prompt) do
    cond do
      String.trim(prompt) == "" -> {:error, "the prompt body is empty; runs would start with no brief"}
      String.contains?(prompt, "{{") -> {:error, "the prompt body has unrendered `{{ ... }}` variables"}
      true -> :ok
    end
  end

  defp prompt_body(_prompt), do: {:error, "the workflow has no prompt body"}

  defp pick_port(project, records, opts) do
    own = own_port(opts)
    taken = [own | Enum.map(Map.values(records), & &1.port)] |> Enum.reject(&is_nil/1)

    case allocate(declared: project.port, taken: taken, held?: held_fun(opts)) do
      {:ok, port} ->
        {:ok, port}

      {:error, :no_free_port} ->
        {:error,
         "no free port in #{@port_start}-#{@port_end} for #{project.name} (its own #{inspect(project.port)} " <>
           "is taken or held): stop something, or declare a free server.port in the workflow"}
    end
  end

  defp launch_spec(project, name, port, opts) do
    %{project: name, workflow: project.path, port: port, logs_root: logs_root(name, opts)}
  end

  defp new_record(name, path, spec, pid) do
    %{
      project: name,
      workflow: path,
      port: spec.port,
      pid: pid,
      logs_root: spec.logs_root,
      started_at: timestamp()
    }
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp run_launcher(spec, opts) do
    case launcher_fun(opts).(spec) do
      {:ok, pid} when is_integer(pid) and pid > 0 -> {:ok, pid}
      {:error, reason} -> {:error, "could not start #{spec.project}: #{describe(reason)}"}
      other -> {:error, "the launcher answered #{inspect(other)} instead of a pid"}
    end
  rescue
    error -> {:error, "the launcher raised: #{Exception.message(error)}"}
  end

  defp record_or_stop(records, record, opts) do
    case write(Map.put(records, record.project, record), file(opts)) do
      :ok ->
        {:ok, record}

      {:error, reason} ->
        # The process is up and unrecorded: the hub could never find it again, so it is stopped now
        # rather than left as an orphan no button can reach.
        _ = kill_fun(opts).(record.pid)

        {:error, "pid #{record.pid} started but could not be recorded (#{describe(reason)}); it has been stopped again"}
    end
  end

  # ── stop ─────────────────────────────────────────────────────────────────────

  @doc """
  Whether the hub may stop this record: `:ok`, or the reason it will not.

  The first two refusals are the hard rule, and they are checked by **both** facts the hub has about
  itself: the port it serves on ("that is the page you are reading") and its own operating-system
  pid ("that is this process"). The third is the other half of the same rule: a record is the only
  thing that makes a pid the hub's to kill, so a project with no record has no pid the hub started
  and there is nothing here to stop.
  """
  @spec stoppable?(instance() | nil, keyword()) :: :ok | {:error, String.t()}
  def stoppable?(record, opts \\ []) do
    this_pid = Keyword.get(opts, :own_pid) || own_pid()

    # One list of reasons, each clause a whole reason: a `cond` here read as one long condition and
    # lost the thing that matters -- which of the four refusals this was.
    case refusal(record, this_pid, own_port(opts)) do
      nil -> :ok
      reason -> {:error, reason}
    end
  end

  defp refusal(nil, _this_pid, _serving) do
    "the hub has no record of starting this project, so it has no pid to stop"
  end

  # A map handed in by someone else -- a state file edited by hand, a future caller -- has no pid to
  # stop and no port to compare against, and saying so beats a `KeyError` from a guess.
  defp refusal(record, _this_pid, _serving) when not (is_map_key(record, :pid) and is_map_key(record, :port)) do
    "the record for #{record[:project]} is missing its pid or its port: #{inspect(record)}"
  end

  defp refusal(record, _this_pid, _serving) when not (is_integer(record.pid) and record.pid > 0) do
    "the record for #{record[:project]} carries no pid (#{inspect(record.pid)})"
  end

  defp refusal(record, this_pid, _serving) when not is_nil(this_pid) and record.pid == this_pid do
    "refused: pid #{record.pid} is this hub's own process"
  end

  defp refusal(record, _this_pid, serving) when not is_nil(serving) and record.port == serving do
    "refused: port #{record.port} is the instance serving this page -- " <>
      "the hub never stops the instance it is running in"
  end

  defp refusal(_record, _this_pid, _serving), do: nil

  @doc """
  Stops the instance the hub started for this project, and drops its record.

  The pid is taken **from the record**, never from the caller: there is no argument that names a
  process here. A pid that is already gone drops the stale record and says so instead of killing
  anything, and a kill that fails keeps the record -- the process may still be there, and a hub that
  forgets a live process has lost the only handle it had on it.
  """
  @spec stop_instance(String.t(), keyword()) :: :ok | {:error, String.t()}
  def stop_instance(name, opts \\ []) when is_binary(name) do
    records = records(opts)
    record = Map.get(records, name)

    with :ok <- stoppable?(record, opts) do
      stop_record(name, record, records, opts)
    end
  rescue
    error -> {:error, "stopping #{name} failed: #{Exception.message(error)}"}
  catch
    kind, reason -> {:error, "stopping #{name} exited: #{kind} #{inspect(reason)}"}
  end

  defp stop_record(name, record, records, opts) do
    if alive_fun(opts).(record.pid) do
      case kill_fun(opts).(record.pid) do
        :ok ->
          drop(name, records, opts)

        {:error, reason} ->
          {:error, "stopping #{name} (pid #{record.pid}) failed: #{describe(reason)}"}
      end
    else
      _ = drop(name, records, opts)
      {:error, "#{name}: pid #{record.pid} is not running any more; the stale record was dropped"}
    end
  end

  defp drop(name, records, opts) do
    case write(Map.delete(records, name), file(opts)) do
      :ok -> :ok
      {:error, reason} -> {:error, "the process was stopped but its record could not be dropped: #{describe(reason)}"}
    end
  end

  # ── what the page asks ───────────────────────────────────────────────────────

  @doc """
  Which action a row offers.

    * `:own` -- this is the instance serving the page. It gets no stop action, ever;
    * `:stop` -- the hub recorded starting it **and** its own `GET /api/v1/state` answered on the
      recorded port, so it is up and it is the hub's;
    * `:observe` -- something is answering on the port and the hub has no record of starting it: it
      is not the hub's to stop;
    * `:start` -- nothing answered. A stale record (a pid that died after boot) lands here on
      purpose: starting replaces it, and the refusal tells the truth if it turns out to be up.
  """
  @spec action(map()) :: :own | :stop | :observe | :start
  def action(row) do
    cond do
      row[:own?] -> :own
      controlled?(row) -> :stop
      not is_nil(row[:hub]) -> :start
      answering?(row) -> :observe
      true -> :start
    end
  end

  defp controlled?(row), do: not is_nil(row[:hub]) and state(row) == :up

  # `:unreachable` is a port with something on it that would not talk. That is not "down", and it is
  # not the hub's either -- so it is not a start button.
  defp answering?(row), do: state(row) in [:up, :unreachable]

  defp state(row) do
    case row[:status] do
      %{state: state} -> state
      _none -> nil
    end
  end

  @doc """
  The registry rows with the hub's own records overlaid.

  A recorded project is probed on the port the hub **assigned**, which is not always the one the file
  declares -- a project whose declared port was held is started on another one, and probing the
  declared port would show it `down` while it answered happily elsewhere. The declared port is kept
  as `:declared_port`, and `:hub` carries the record's pid, port and logs root so a row can say what
  it is about to kill.
  """
  @spec overlay([map()], map()) :: [map()]
  def overlay(rows, records) when is_list(rows) and is_map(records) do
    Enum.map(rows, fn row ->
      row = Map.put(row, :declared_port, row[:port])

      case Map.get(records, row[:name]) do
        nil -> Map.put(row, :hub, nil)
        record -> row |> Map.put(:hub, public(record)) |> assign_port(record)
      end
    end)
  end

  defp assign_port(row, record) do
    row
    |> Map.put(:port, record.port)
    |> Map.put(:url, "http://127.0.0.1:#{record.port}")
  end

  defp public(record) do
    %{
      pid: record.pid,
      port: record.port,
      logs_root: record.logs_root,
      started_at: record.started_at
    }
  end

  # ── where an instance's own files go ─────────────────────────────────────────

  @doc """
  An instance's own logs root: `<logs root>/<project>`.

  `config :symphony_elixir, :instance_logs_root` moves the root. One directory per project, because
  the two things written there -- the OTP log the CLI is pointed at with `--logs-root`, and the
  launcher's console capture -- belong to that instance and to nothing else.
  """
  @spec logs_root(String.t(), keyword()) :: Path.t()
  def logs_root(name, opts \\ []) do
    root =
      Keyword.get(opts, :logs_root) ||
        Application.get_env(:symphony_elixir, :instance_logs_root) ||
        @default_logs_dir

    Path.expand(Path.join(root, name))
  end

  # ── this hub's own identity ──────────────────────────────────────────────────

  @doc """
  The port this instance serves on, or `nil` when its own configuration cannot be read.

  `Config.server_port/0` is the same answer the HTTP server bound to, override included, so "the
  instance I am running in" is a fact rather than a guess.
  """
  @spec own_port(keyword()) :: non_neg_integer() | nil
  def own_port(opts \\ []) do
    Keyword.get(opts, :own_port) || Config.server_port()
  rescue
    _error -> nil
  end

  @doc "This hub's own operating-system pid, as an integer, or `nil` if it cannot be read."
  @spec own_pid() :: pos_integer() | nil
  def own_pid do
    System.pid() |> String.to_integer()
  rescue
    _error -> nil
  end

  # ── the launcher ─────────────────────────────────────────────────────────────

  @doc """
  The exact command a start runs, as `{executable, args}`.

    * `executable` -- `escript` (`config :symphony_elixir, :escript_executable` to pin a path);
    * first argument -- the running instance's own script, from `:escript.script_name/0`, so a hub
      starts siblings **of the same build** (`config :symphony_elixir, :instance_script` moves it);
    * then the registry's workflow file, the guardrails acknowledgement, the instance's own logs
      root, and the port the hub assigned.

  Nothing else is passed: no host (the CLI has no such switch, so the workflow's own `server.host`
  decides -- which is why `loopback_only/1` refuses a file that says otherwise), and no path that
  did not come out of the registry.
  """
  @spec command(launch_spec(), keyword()) :: {String.t(), [String.t()]}
  def command(spec, opts \\ []) do
    {executable(opts),
     [
       script(opts),
       spec.workflow,
       CLI.acknowledgement_switch(),
       "--logs-root",
       spec.logs_root,
       "--port",
       Integer.to_string(spec.port)
     ]}
  end

  @doc "The escript file a start runs: this instance's own when this instance *is* the Symphony escript."
  @spec script(keyword()) :: Path.t()
  def script(opts \\ []) do
    Keyword.get(opts, :script) ||
      Application.get_env(:symphony_elixir, :instance_script) ||
      own_script()
  end

  defp own_script do
    case :escript.script_name() do
      name when is_list(name) ->
        path = List.to_string(name)

        if Path.basename(path) in ["symphony", "symphony.exe"] do
          path
        else
          Path.expand(Path.join("bin", "symphony"), File.cwd!())
        end

      _other ->
        Path.expand(Path.join("bin", "symphony"), File.cwd!())
    end
  end

  defp executable(opts) do
    Keyword.get(opts, :escript) ||
      Application.get_env(:symphony_elixir, :escript_executable) ||
      System.find_executable("escript") ||
      "escript"
  end

  @doc """
  The default launcher: writes the command into a script under the instance's own logs root and runs
  it **detached**.

  Three measured facts decide this shape:

    * **a port is not a leash.** On Windows the process a `Port.open/2` spawns keeps running after
      the port is closed (measured, 2026-05-01), so closing it immediately is what lets an instance
      outlive the request that started it -- and the hub itself, which is what makes a later boot
      adopt it instead of losing it;
    * **the output cannot be left on a pipe nobody reads.** The instance writes to stdout
      continuously (its own status dashboard), so a pipe would fill and freeze it. The script
      redirects everything into `<logs root>/instance.log`, which also means the hub never has to
      drain anything;
    * **the pid it answers with is the shell's**, and the shell waits for the instance -- so it is
      the root of the tree `Shell.kill_tree/1` kills, which is why a stop reaches the escript *and*
      the agents under it.

  A shell that exits within #{@settle_ms} ms means the instance never started (`cmd` lives exactly as
  long as its child), and the last line of the log is returned as the reason.
  """
  @spec launch(launch_spec()) :: {:ok, pos_integer()} | {:error, term()}
  def launch(spec) do
    with :ok <- File.mkdir_p(spec.logs_root),
         {:ok, path} <- write_script(spec),
         {:ok, port} <- open(path) do
      # The port is closed on every path out of here -- including the failure paths -- because a
      # port left open would hold this process to a shell that is waiting for an instance.
      result = os_pid_before_exit(port, spec)
      close(port)
      result
    end
  rescue
    error -> {:error, {:launch_raised, Exception.message(error)}}
  end

  defp os_pid_before_exit(port, spec) do
    with {:ok, pid} <- os_pid(port),
         :ok <- settle(port, spec) do
      {:ok, pid}
    end
  end

  defp write_script(spec) do
    {executable, args} = command(spec)
    log = Path.join(spec.logs_root, "instance.log")

    File.write(Path.join(spec.logs_root, script_name()), body(executable, args, log))
  end

  defp script_name, do: if(Shell.windows?(), do: "start.cmd", else: "start.sh")

  defp body(executable, args, log) do
    line = Enum.map_join([executable | args], " ", &quote_arg/1)

    if Shell.windows?() do
      "@echo off\r\ncd /d #{quote_arg(File.cwd!())}\r\n#{line} > #{quote_arg(log)} 2>&1\r\n"
    else
      "#!/bin/sh\ncd #{quote_arg(File.cwd!())}\n#{line} > #{quote_arg(log)} 2>&1\n"
    end
  end

  defp quote_arg(arg), do: "\"" <> arg <> "\""

  defp open(path) do
    if Shell.windows?() do
      shell = System.get_env("COMSPEC") || System.find_executable("cmd") || "cmd.exe"
      {:ok, Port.open({:spawn_executable, String.to_charlist(shell)}, port_opts(["/c", path]))}
    else
      shell = System.find_executable("sh") || "sh"
      {:ok, Port.open({:spawn_executable, String.to_charlist(shell)}, port_opts([path]))}
    end
  rescue
    error -> {:error, {:shell_raised, Exception.message(error)}}
  end

  # `:hide` for the reason `Shell.open_port/3` gives: without it a `cmd` shim's grandchild has its
  # stdout dropped and the caller sees silence.
  defp port_opts(args), do: [:binary, :hide, :exit_status, args: args]

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> {:ok, pid}
      other -> {:error, {:no_os_pid, other}}
    end
  end

  defp settle(port, spec) do
    settle_until(port, spec, System.monotonic_time(:millisecond) + @settle_ms)
  end

  # Anything else the port sends (a byte of output that was not redirected, say) is dropped rather
  # than left in the caller's mailbox, and it does not shorten the window: the question is still
  # only "did the shell die before the instance could start".
  defp settle_until(port, spec, deadline) do
    receive do
      {^port, {:exit_status, status}} ->
        {:error, {:exited_immediately, status, Path.join(spec.logs_root, "instance.log"), tail(spec)}}

      {^port, _other} ->
        settle_until(port, spec, deadline)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> :ok
    end
  end

  defp tail(spec) do
    case File.read(Path.join(spec.logs_root, "instance.log")) do
      {:ok, body} -> body |> String.split("\n") |> Enum.reject(&(String.trim(&1) == "")) |> List.last()
      _error -> nil
    end
  end

  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  # ── the rest ─────────────────────────────────────────────────────────────────

  defp launcher_fun(opts), do: Keyword.get(opts, :launcher) || (&launch/1)
  defp held_fun(opts), do: Keyword.get(opts, :held?) || (&held?/1)
  defp alive_fun(opts), do: Keyword.get(opts, :alive?) || (&alive?/1)
  defp kill_fun(opts), do: Keyword.get(opts, :kill) || (&Shell.kill_tree/1)

  # One clause, not one per shape: `Workflow.load/1` hands back an exception, `Schema.parse/1` a
  # tuple, and the launcher whatever it likes. The compiler can only see one of them at a time.
  defp describe({:invalid_workflow_config, message}) when is_binary(message), do: message
  defp describe({:exited_immediately, status, log, nil}), do: "the shell exited immediately (exit #{status}); log: #{log}"

  defp describe({:exited_immediately, status, log, line}),
    do: "the shell exited immediately (exit #{status}): #{line} (log: #{log})"

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason) when is_exception(reason), do: Exception.message(reason)
  defp describe(reason), do: inspect(reason, limit: 5, printable_limit: 500)
end
