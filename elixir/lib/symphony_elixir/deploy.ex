defmodule SymphonyElixir.Deploy do
  @moduledoc """
  The deploy a project declares in its own workflow, run **on the host** when somebody asks for it.

  The loop could develop, verify and integrate a ticket and then stop: `Land` publishes the work, and
  nothing put it anywhere. This module is that last step, and it is deliberately the smallest one it
  can be -- it runs the command the project declared, in the directory the project declared, and
  reports how it ended. It decides nothing else: no environment, no schedule, no rollback, and no
  automatic deploy after a ticket lands.

  ## The command is declared, never supplied

  `deploy.command` in the project's own workflow file is the only command, and
  `deploy.working_directory` is the only directory. `run/2` takes a **project name** and nothing else:
  there is no argument that names a command, an argument, a shell operator, a script or a directory. A
  name the registry does not list is refused, so a crafted event cannot point this at another file
  either. That is the whole rule the tests pin, and it is the rule that keeps this from being a remote
  shell: the host side of this module is **not sandboxed** -- it runs with this process's own
  permissions -- so a deploy that ran what it was handed would run it as the operator.

  ## Where it runs, and for how long

  In the declared `working_directory`, or -- when the workflow declares none -- in the directory the
  orchestrator itself was started in. `deploy.timeout_ms` is a **total** deadline handed to
  `Shell.run/3`, whose expiry path reads the port's `:os_pid` and calls `Shell.kill_tree/1`, so a
  deploy that hangs takes its children with it instead of leaving a survivor holding the stdout pipe.
  The answer is bounded twice over: the last lines, and then a byte cap through
  `Workspace.sanitize_hook_output_for_log/2`, which trims back to a character boundary because a cut
  inside a multi-byte character leaves bytes that are no longer text.

  ## Nothing happens without a click

  `run/2` is called from one `handle_event/3` clause on `/control`, once per press. It is not on a
  timer, it is not retried, and rendering the page never starts one. Every failure -- a project that
  declares nothing, a workflow that does not load, a shell that will not start, a non-zero exit, a
  timeout -- comes back as a value the row can show, so a failed deploy cannot take the page down.
  """

  require Logger

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{Projects, Shell, Workflow, Workspace}

  # The same two bounds the gate tool answers under, for the same two reasons: `@tail_lines` is what
  # makes the answer a *tail* (a build log is thousands of lines), `@max_output_bytes` is the hard one,
  # for the single enormous line no line count bounds.
  @tail_lines 40
  @max_output_bytes 8_192

  @typedoc "The declaration as the schema sees it: what runs, where, and how long it may take."
  @type declaration :: %{
          command: String.t(),
          working_directory: String.t() | nil,
          timeout_ms: pos_integer()
        }

  @typedoc """
  How a deploy ended, in the shape a row renders: the status, the bounded tail, and the line that says
  what happened.

  `exit_code` is `nil` when nothing ran, `output` is empty when nothing was read (a timeout discards
  what the command had printed, because it went with the port), and `message` is always a sentence.
  """
  @type result :: %{
          project: String.t(),
          command: String.t() | nil,
          working_directory: String.t() | nil,
          timeout_ms: pos_integer(),
          exit_code: non_neg_integer() | nil,
          timed_out: boolean(),
          truncated: boolean(),
          output: String.t(),
          message: String.t()
        }

  @doc """
  The deploy `name` declares, or the reason there is none to run.

  Three answers, and the difference between the last two matters to a reader:

    * `{:ok, declaration}` -- the project's own workflow declares `deploy.command`;
    * `{:error, message}` naming the registry -- the name is not a project this machine lists, so there
      is no workflow file to read a command out of (the same refusal `InstanceRegistry` makes for a
      start, for the same reason: the name comes from a browser event and is looked up, never trusted);
    * `{:error, message}` naming the file -- the project is listed and its workflow does not load, or
      loads and declares no (or a blank) command. Declaring no deploy is a legitimate state, not an
      error in the file; it just means there is no action to offer.

  `opts[:projects]` replaces the registry listing (for a caller that already read it, and for tests),
  and `opts[:settings]` replaces the parse of the file -- the same seam the gate tool takes, so a test
  never has to write a workflow.
  """
  @spec declared(String.t(), keyword()) :: {:ok, declaration()} | {:error, String.t()}
  def declared(name, opts \\ []) when is_binary(name) do
    with {:ok, path} <- workflow_path(name, opts),
         {:ok, settings} <- settings(path, opts) do
      deploy_of(settings, name)
    end
  end

  @doc """
  Runs the deploy `name` declares and answers how it ended.

  `opts` carries the injections, not the request: `:runner` replaces `Shell.run/3`, `:projects` and
  `:settings` go to `declared/2`. Nothing here reads a command, a directory or a deadline out of
  `opts`, which is what a crafted `phx-value-` cannot reach -- the only thing a request contributes is
  the *name*, and that name is looked up in the registry before anything runs.
  """
  @spec run(String.t(), keyword()) :: {:ok, result()} | {:error, result()}
  def run(name, opts \\ []) when is_binary(name) do
    case declared(name, opts) do
      {:ok, declaration} -> execute(name, declaration, opts)
      {:error, reason} -> {:error, refused(name, reason)}
    end
  rescue
    # A tool call and a page both have to fail as a value: a runner that raises, or a working
    # directory that does not exist (`Port.open/2` answers `:enoent`), must not take the page with it.
    error -> {:error, crashed(name, error)}
  end

  @doc """
  A failed result carrying `message`, for a caller that has to render a reason `run/2` did not produce
  -- the control plane's own guard around a runner that raised or exited.
  """
  @spec failure(String.t(), String.t()) :: result()
  def failure(name, message) when is_binary(name) and is_binary(message) do
    payload(project: name, message: message)
  end

  # --- the declaration -----------------------------------------------------------

  # The registry is the only source of a workflow path. The name arrives from a browser event, so it is
  # looked up in the listing rather than joined onto the registry directory -- a crafted name cannot
  # name a file outside the registry, and a name that is not in the listing is refused by name.
  defp workflow_path(name, opts) do
    rows = Keyword.get(opts, :projects) || Projects.list(probe: false)

    case Enum.find(rows, &(&1.name == name)) do
      nil -> {:error, unknown_project_message(name)}
      row -> {:ok, row.path}
    end
  end

  defp unknown_project_message(name) do
    "no project named #{name} in the registry (#{Projects.registry_dir()}) -- only a listed project has " <>
      "a workflow to read a deploy out of, and nothing was run"
  end

  defp settings(path, opts) do
    case Keyword.get(opts, :settings) do
      nil -> settings_from(path)
      settings -> {:ok, settings}
    end
  end

  # `Workflow.load/1` + `Schema.parse/1`, the pair `Projects` itself uses: the declaration the button
  # reads is the declaration an instance would load, with no second parser and no second copy of it.
  #
  # Both failures become a **sentence** here, never the parser's own tuple: the message ends up in a
  # row, and a row that interpolates a tuple raises -- which is the one thing a failing deploy must
  # not do to the page.
  defp settings_from(path) do
    with {:ok, loaded} <- Workflow.load(path),
         {:ok, settings} <- Schema.parse(loaded.config) do
      {:ok, settings}
    else
      {:error, reason} -> {:error, unreadable_message(reason)}
    end
  end

  defp deploy_of(%{deploy: %{command: command} = deploy}, name) when is_binary(command) do
    case String.trim(command) do
      "" -> {:error, no_deploy_message(name)}
      _declared -> {:ok, declaration(deploy)}
    end
  end

  defp deploy_of(_settings, name), do: {:error, no_deploy_message(name)}

  defp declaration(deploy) do
    %{
      command: deploy.command,
      working_directory: presence(deploy.working_directory),
      timeout_ms: timeout_ms(deploy)
    }
  end

  defp no_deploy_message(name) do
    "#{name} declares no deploy: add `deploy.command` to its workflow. Nothing was run."
  end

  defp unreadable_message(reason) do
    "the workflow does not load, so there is no deploy to run: #{describe(reason)}"
  end

  defp timeout_ms(%{timeout_ms: timeout}) when is_integer(timeout) and timeout > 0, do: timeout
  defp timeout_ms(_deploy), do: Schema.Deploy.default_timeout_ms()

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  # --- running it ----------------------------------------------------------------

  # The declared command, through the declared shell, in the declared directory -- and through
  # `Shell.run/3`, never `System.cmd/3`. That runner owns a **total** deadline (a command that keeps
  # printing cannot reset it), and on expiry it reads the port's `:os_pid` and calls its own
  # `kill_tree/1`, so a deploy that outlives the deadline takes its children with it instead of leaving
  # a survivor holding the stdout pipe. Building a second process runner here -- to kill the tree
  # again -- is the one thing this module must not do.
  defp execute(name, declaration, opts) do
    log_start(name, declaration)

    case runner(opts).(shell(), ["-lc", declaration.command], run_opts(declaration)) do
      {:ok, output, 0} -> {:ok, finished(name, declaration, output, 0)}
      {:ok, output, status} -> {:error, finished(name, declaration, output, status)}
      {:error, :timeout} -> {:error, timed_out(name, declaration)}
      {:error, {:not_found, tool}} -> {:error, not_started(name, declaration, tool)}
      {:error, reason} -> {:error, not_started(name, declaration, reason)}
    end
  end

  # The deadline and the directory, both from the declaration and from nowhere else. `:cd` is set only
  # when one was declared, so the unset case is `Shell.run/3`'s own default (the directory this
  # process runs in) rather than a directory invented here.
  defp run_opts(declaration) do
    opts = [timeout: declaration.timeout_ms]

    case declaration.working_directory do
      directory when is_binary(directory) -> Keyword.put(opts, :cd, directory)
      _none -> opts
    end
  end

  # Injected in the tests, the same seam the gate tool and the tracker clients take, so no test starts
  # a real deploy -- or a shell.
  defp runner(opts), do: Keyword.get(opts, :runner) || (&Shell.run/3)

  # The same shell the workspace hooks and the gate use, for the same reason: a command that says
  # `cd elixir && mix release` is a shell script, and a bare `sh` is not on the Windows PATH.
  defp shell, do: Shell.find_sh() || "sh"

  # --- every ending, as a value --------------------------------------------------

  defp finished(name, declaration, raw_output, exit_code) do
    {output, truncated?} = bounded_output(raw_output)
    log_ending(name, "exited #{exit_code}")

    payload(
      project: name,
      command: declaration.command,
      working_directory: declaration.working_directory,
      timeout_ms: declaration.timeout_ms,
      exit_code: exit_code,
      truncated: truncated?,
      output: output,
      message: exit_message(exit_code, truncated?)
    )
  end

  defp exit_message(0, true), do: "exit 0; the output below is truncated"
  defp exit_message(0, false), do: "exit 0"
  defp exit_message(status, true), do: "the deploy exited #{status}; the tail below is truncated"
  defp exit_message(status, false), do: "the deploy exited #{status}; the tail of its output is below"

  defp timed_out(name, declaration) do
    log_ending(name, "timed out after #{declaration.timeout_ms} ms")

    payload(
      project: name,
      command: declaration.command,
      working_directory: declaration.working_directory,
      timeout_ms: declaration.timeout_ms,
      timed_out: true,
      message:
        "the deploy did not finish within #{declaration.timeout_ms} ms; the host killed the process tree " <>
          "(what it had printed went with the port)"
    )
  end

  defp not_started(name, declaration, reason) do
    log_ending(name, "could not start: #{inspect(reason)}")

    payload(
      project: name,
      command: declaration.command,
      working_directory: declaration.working_directory,
      timeout_ms: declaration.timeout_ms,
      message: "the deploy could not start: #{inspect(reason)} -- a deploy command needs a shell to run in"
    )
  end

  defp refused(name, reason) do
    log_ending(name, reason)
    payload(project: name, message: reason)
  end

  defp crashed(name, error) do
    message = "the deploy raised: #{Exception.message(error)}"
    log_ending(name, message)
    payload(project: name, message: message)
  end

  # One shape for every ending, so a row never has to ask which one it got: the fields a caller reads
  # are always there, and the ones nothing filled in say so by being `nil` or empty.
  defp payload(fields) do
    Map.merge(
      %{
        project: nil,
        command: nil,
        working_directory: nil,
        timeout_ms: Schema.Deploy.default_timeout_ms(),
        exit_code: nil,
        timed_out: false,
        truncated: false,
        output: "",
        message: ""
      },
      Map.new(fields)
    )
  end

  # --- bounding the answer -------------------------------------------------------

  # Last N lines first, then the byte cap through `Workspace.sanitize_hook_output_for_log/2` -- the
  # function that already exists for exactly this class of mistake. It trims back to a character
  # boundary, so a cut inside a multi-byte character cannot leave a tail that is no longer text.
  defp bounded_output(output) do
    raw = IO.iodata_to_binary(output)
    {tail, lines_dropped?} = tail_lines(raw)
    {bounded, bytes_dropped?} = cap_bytes(tail)
    {bounded, lines_dropped? or bytes_dropped?}
  end

  defp tail_lines(output) do
    lines = String.split(output, ~r/\r?\n/)

    case Enum.take(lines, -@tail_lines) do
      ^lines -> {output, false}
      tail -> {Enum.join(tail, "\n"), true}
    end
  end

  defp cap_bytes(text) do
    case Workspace.sanitize_hook_output_for_log(text, @max_output_bytes) do
      ^text -> {text, false}
      capped -> {capped, true}
    end
  end

  # --- the log -------------------------------------------------------------------

  # What ran and where, before it runs: the command is the workflow's, and this line is the record of
  # which one the button used. `inspect/1` rather than interpolation, so a command carrying a newline
  # cannot forge a second log line.
  defp log_start(name, declaration) do
    Logger.info(
      "deploy: #{name} runs #{inspect(declaration.command)} in #{directory_line(declaration.working_directory)} " <>
        "with a #{declaration.timeout_ms} ms deadline"
    )
  end

  defp log_ending(name, line), do: Logger.info("deploy: #{name} #{line}")

  defp directory_line(nil), do: "the orchestrator's own directory"
  defp directory_line(directory), do: inspect(directory)

  # One clause, not one per shape: `Workflow.load/1` hands back an exception struct, `Schema.parse/1` a
  # tuple, and the compiler can only see one of them at a time.
  defp describe({:invalid_workflow_config, message}) when is_binary(message), do: message
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason) when is_exception(reason), do: Exception.message(reason)
  defp describe(reason), do: inspect(reason, limit: 5, printable_limit: 500)
end
