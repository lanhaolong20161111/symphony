defmodule SymphonyElixir.Projects do
  @moduledoc """
  The project registry: `~/code/symphony-projects/*.md`, **one file per project**.

  The directory *is* the registry. There is no service, no list to keep in step and no discovery
  step: the file name is the project name, `server.port` is where it runs, and the file itself is
  the workflow the instance is started with -- so what the registry says and what runs cannot drift,
  because they are the same bytes.

  ## Every file is parsed by the real parser

  `Workflow.load/1` + `Schema.parse/1`, the same pair an instance uses. A file that does not parse
  is reported as broken (`error`) rather than shown with half its fields: a registry that quietly
  displays partial projects is worse than one that names the file that is wrong.

  ## What it reads, and the judgement it makes

  * the **queue** is `tracker.provider.path` -- what the orchestrator actually polls, which is not
    always what `janitor.tickets_path` says (they are the same directory declared twice, and both
    are reported so a disagreement is visible rather than assumed away);
  * the **repositories** come out of the `git clone` lines in `hooks.after_create`, because that
    string is the only place they are written;
  * **reachability** is an HTTP probe of the project's own `server.port`, so "declared but not
    running" is a state the registry can state instead of leaving a task to sit in a queue nobody
    reads.

  ## The trap this exists to catch

  **A queue may belong to only one instance.** Two projects pointing at the same
  `tracker.provider.path` means two orchestrators racing for the same tickets and two janitors
  mirroring one ticket repository -- measured, during the WorkBuddy smoke test, where the instance
  polled the real directory while the scratch one it was told to use sat empty. `queue_conflicts/1`
  reports it.
  """

  alias SymphonyElixir.{Config, Settings, Shell, Workflow}
  alias SymphonyElixir.Config.Schema

  @default_dir "~/code/symphony-projects"
  @probe_timeout_ms 1_500

  # Where project instances live. Kept away from 1-1023 (privileged) and from the ports a developer
  # machine usually already has something on, so the suggestion is not a port that is taken.
  @port_range 4001..4099

  @common_ports [
    3000,
    3001,
    3306,
    4000,
    4200,
    5000,
    5173,
    5432,
    5672,
    6379,
    7474,
    8000,
    8001,
    8080,
    8081,
    8443,
    8888,
    9000,
    9090,
    9200,
    11_211,
    27_017
  ]

  @typedoc "One project as the registry sees it. `error` is set when its file does not parse."
  @type project :: %{
          name: String.t(),
          path: String.t(),
          host: String.t() | nil,
          port: integer() | nil,
          url: String.t() | nil,
          queue: String.t() | nil,
          mirror_path: String.t() | nil,
          issues_repo: String.t() | nil,
          tickets_repo: String.t() | nil,
          workspace_root: String.t() | nil,
          backend: String.t() | nil,
          adapter: String.t() | nil,
          model: String.t() | nil,
          cli_path: String.t() | nil,
          repos: [String.t()],
          reachable?: boolean(),
          queue_present?: boolean(),
          error: String.t() | nil
        }

  @doc "Where the registry lives. `config :symphony_elixir, :projects_dir` to move it."
  @spec registry_dir() :: String.t()
  def registry_dir do
    :symphony_elixir
    |> Application.get_env(:projects_dir, @default_dir)
    |> Path.expand()
  end

  @doc """
  Every declared project, sorted by name, each probed for reachability.

  A missing directory is `[]`, not an error: a machine with no registry simply has no other
  projects, which is the state this system was in until now.

  ## `probe: false` -- parsing without asking

  The reachability probe is one HTTP request per project, **one after another**, which is the right
  shape for a page that only wants a boolean. A page that wants the *counts* has to ask each
  instance anyway, and asking twice is asking the same instance twice -- so `ProjectStatus` turns the
  probe off here and asks every instance at once instead. The file is still parsed by this module:
  `Workflow.load/1` + `Schema.parse/1`, the same pair an instance uses, and never a second parser.
  """
  @spec list() :: [project()]
  @spec list(keyword()) :: [project()]
  def list(opts \\ []) do
    probe? = Keyword.get(opts, :probe, true)

    registry_dir()
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) == "README.md"))
    |> Enum.sort()
    |> Enum.map(&load(&1, probe?))
  end

  @doc "One project by name (the file's basename without `.md`)."
  @spec find(String.t()) :: {:ok, project()} | :error
  def find(name) when is_binary(name) do
    case Enum.find(list(), &(&1.name == name)) do
      nil -> :error
      project -> {:ok, project}
    end
  end

  @doc """
  Queues claimed by more than one project, as `%{queue => [project names]}`.

  Takes the list so it can be asserted without a filesystem. An empty map is the healthy answer;
  anything else means those projects must not run at the same time.
  """
  @spec queue_conflicts([project()]) :: %{optional(String.t()) => [String.t()]}
  def queue_conflicts(projects) do
    projects
    |> Enum.reject(&(is_nil(&1.queue) or &1.error != nil))
    |> Enum.group_by(& &1.queue, & &1.name)
    |> Enum.filter(fn {_queue, names} -> length(names) > 1 end)
    |> Map.new()
  end

  defp load(path, probe?) do
    name = Path.basename(path, ".md")

    with {:ok, loaded} <- Workflow.load(path),
         {:ok, settings} <- Schema.parse(loaded.config) do
      from_settings(blank(name, path), settings, probe?)
    else
      {:error, reason} -> blank(name, path) |> Map.put(:error, describe_load_error(reason))
    end
  end

  # The full shape with nothing filled in, so the error path and the success path return the same
  # keys and a caller never has to ask which one it got.
  defp blank(name, path) do
    %{
      name: name,
      path: path,
      host: nil,
      port: nil,
      url: nil,
      queue: nil,
      mirror_path: nil,
      issues_repo: nil,
      tickets_repo: nil,
      workspace_root: nil,
      backend: nil,
      adapter: nil,
      model: nil,
      cli_path: nil,
      repos: [],
      reachable?: false,
      queue_present?: false,
      error: nil
    }
  end

  defp from_settings(base, settings, probe?) do
    host = settings.server.host
    port = settings.server.port
    url = if(is_binary(host) and is_integer(port), do: "http://#{probe_host(host)}:#{port}", else: nil)
    identity = backend_identity(settings)

    base
    |> Map.merge(%{
      host: host,
      port: port,
      url: url,
      # The orchestrator polls `tracker.provider.path`; the janitor mirrors `janitor.tickets_path`.
      # Both are reported, because a disagreement between them is silent otherwise.
          queue: settings.tracker.provider["path"] || settings.tracker.provider[:path],
          mirror_path: settings.janitor.tickets_path,
          issues_repo: settings.janitor.issues_repo,
          tickets_repo: settings.janitor.tickets_repo,
          workspace_root: settings.workspace.root,
          backend: identity.backend,
          adapter: identity.adapter,
          model: identity.model,
          # Kept so a project that uses workbuddy can answer "where is that CLI" for another instance
          # that does not -- the model list lives in that CLI's own --help.
          cli_path: acp_cli_path(settings),
          repos: Settings.clone_urls(settings.hooks.after_create || ""),
          # `probe?` is false for a caller that is going to ask every instance at once, and skipping
          # the request means `reachable?` is not a fact that caller may use.
          reachable?: probe? and url != nil and reachable?(url),
          queue_present?: queue_present?(settings.tracker.provider)
        })
  end

  # A queue path that does not exist is worth knowing *before* a task is created: the GitHub issue
  # would be opened first and the ticket write would then fail, leaving an issue with no ticket.
  defp queue_present?(provider) do
    case provider["path"] || provider[:path] do
      path when is_binary(path) -> File.dir?(path)
      _ -> false
    end
  end

  # `0.0.0.0` is a bind address, not somewhere to connect to.
  defp probe_host("0.0.0.0"), do: "127.0.0.1"
  defp probe_host("::"), do: "127.0.0.1"
  defp probe_host(host), do: host

  defp backend_identity(settings) do
    case settings.agent.backend do
      "acp" -> %{backend: "acp", adapter: settings.acp.adapter, model: settings.acp.model}
      other -> %{backend: other, adapter: nil, model: nil}
    end
  end

  # Where this project's ACP adapter CLI is: a path, or the first word of a command list.
  defp acp_cli_path(%{agent: %{backend: "acp"}} = settings) do
    present(settings.acp.cli_path) || present(List.first(List.wrap(settings.acp.command)))
  end

  defp acp_cli_path(_settings), do: nil

  # `retry: false` for the same reason `RecorderClient` sets it: Req retries transport errors with
  # backoff, so probing a project that is **not running** cost three connection attempts per probe --
  # measured at ~10 s for one unreachable project, on a page whose whole point is to show which
  # projects are up.
  defp reachable?(url) do
    case Req.get(url <> "/api/v1/state", receive_timeout: @probe_timeout_ms, retry: false) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  rescue
    _error -> false
  end

  # One clause, not one per shape: `Workflow.load/1` hands back an exception struct for a parse
  # failure and a tuple for a schema failure, and the compiler can only see one of them at a time.
  defp describe_load_error(reason) do
    if is_exception(reason), do: Exception.message(reason), else: inspect(reason)
  end

  @doc """
  This instance's own project, matched by the workflow file it was started with.

  A registry path and a workflow path are the same path, so this is a comparison rather than a
  lookup table -- which is what makes "which project am I" answerable without configuration.
  """
  @spec current() :: {:ok, project()} | :error
  def current do
    current_path = Workflow.workflow_file_path() |> Path.expand()
    Enum.find_value(list(), :error, fn project ->
      if Path.expand(project.path) == current_path, do: {:ok, project}
    end)
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  # Same three-line guard `TaskComposer` and `Settings` each carry: nil and "" mean "not set", and
  # a util module for it would be more machinery than the duplication costs.
  defp present(value), do: blank_to_nil(value)

  @doc "Whether the registry directory exists at all."
  @spec present?() :: boolean()
  def present?, do: File.dir?(registry_dir())

  @doc """
  The first port in the project range that is neither claimed by a project nor in use.

  "In use" is decided by trying to listen on it, not by reading a table: a port can be held by
  anything (another service, a stale process, a container) and the registry only knows about
  Symphony's own projects. A suggestion that turns out to be taken is worse than no suggestion,
  because it fails at startup rather than in the form.

  Common developer ports are skipped outright, and `nil` means the range is full.
  """
  @spec next_free_port([integer()]) :: integer() | nil
  def next_free_port(claimed) when is_list(claimed) do
    Enum.find(@port_range, fn port ->
      port not in claimed and port not in @common_ports and free?(port)
    end)
  end

  # Binding is the only honest test: `:eaddrinuse` is the answer, and closing immediately means the
  # window is microseconds. If it cannot bind at all (no loopback, weird sandbox), it is not free.
  defp free?(port) do
    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true, active: false]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  @doc """
  The GitHub owner this machine's projects live under, taken from what this instance already
  declares -- so a new project's repositories can be offered with the right prefix instead of
  asking for it again.
  """
  @spec github_owner() :: String.t() | nil
  def github_owner do
    candidates =
      [Config.settings!().janitor.issues_repo, Config.settings!().janitor.tickets_repo] ++
        Enum.flat_map(list(), &[&1.issues_repo, &1.tickets_repo])

    Enum.find_value(candidates, fn
      repo when is_binary(repo) ->
        case String.split(repo, "/", parts: 2) do
          [owner, _name] when owner != "" -> owner
          _ -> nil
        end

      _ ->
        nil
    end)
  rescue
    _error -> nil
  end

  @doc """
  Model names worth offering for `adapter`, best effort.

  Two sources, and neither is a catalogue:

    * **what this machine already uses** -- the value in this instance's workflow and in every
      registered project. That is the list that is actually known to work here.
    * **the adapter's own `--help`** where it documents them. WorkBuddy does: its `--model` line ends
      with `Currently supported: (auto, glm-5.1, ...)`. DSH does not and cannot -- its model must
      match an entry `session/new` returns in `configOptions`, which only exists inside a session, so
      for DSH this returns what is known plus whatever was typed before.

  Always a suggestion list, never a closed set: the form keeps a free-text input, because a picker
  that can only offer what it could discover is a new way to be stuck.
  """
  @spec known_models(String.t() | nil) :: [String.t()]
  def known_models(adapter) do
    (from_workflows() ++ from_adapter_help(adapter))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp from_workflows do
    declared =
      Enum.flat_map(list(), fn project ->
        case project.backend do
          "acp" -> [project.model]
          "commandcode" -> [project.model]
          _ -> []
        end
      end)

    own =
      case Config.settings!() do
        %{agent: %{backend: "acp"}} = settings -> [settings.acp.model]
        %{agent: %{backend: "commandcode"}} = settings -> [settings.commandcode.model]
        _ -> []
      end

    (declared ++ own) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  rescue
    _error -> []
  end

  # WorkBuddy's CLI prints its supported models in `--help`. Parsed rather than hardcoded: the list
  # belongs to the CLI that validates it, and a copy here would go stale silently.
  #
  # The CLI path is looked up in this instance's own ACP configuration **and** in every registered
  # project, so a project that uses workbuddy makes the list available even when the instance asking
  # is running something else -- which is the common case, since this form is usually filled in from
  # whichever instance happens to be up.
  defp from_adapter_help("workbuddy") do
    with path when is_binary(path) <- workbuddy_cli(),
         # WorkBuddy's CLI is a `.js` file -- its own adapter launches it as
         # `node <path> --acp --acp-transport stdio` -- so running it directly is `:eacces`, measured.
         {:ok, output, _status} <- Shell.run("node", [path, "--help"], timeout: 20_000),
         [_, list] <- Regex.run(~r/Currently supported:\s*\(([^)]*)\)/, output) do
      list
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
    else
      _ -> []
    end
  end

  defp from_adapter_help(_adapter), do: []

  # The rescue is on its own function on purpose: with it wrapped around the whole lookup, a failure
  # to read *this* instance's settings also skipped the registry scan -- so a machine whose running
  # project is not ACP found no models at all, however many ACP projects it had registered.
  defp workbuddy_cli do
    own_workbuddy_cli() ||
      Enum.find_value(list(), fn project ->
        if project.adapter == "workbuddy", do: present(project.cli_path)
      end)
  end

  defp own_workbuddy_cli do
    case Config.settings!() do
      %{agent: %{backend: "acp"}} = settings ->
        present(settings.acp.cli_path) || present(List.first(List.wrap(settings.acp.command)))

      _ ->
        nil
    end
  rescue
    _error -> nil
  end

  @doc "`gh` on PATH -- the registry probes and ticket creation both need it."
  @spec gh_available?() :: boolean()
  def gh_available?, do: Shell.available?("gh")

  @doc "The instance's own configuration as a project-shaped map, for a machine with no registry."
  @spec from_local_config() :: project()
  def from_local_config do
    settings = Config.settings!()

    %{
      name: "本实例",
      path: Workflow.workflow_file_path(),
      host: settings.server.host,
      port: settings.server.port,
      url: nil,
      queue: settings.tracker.provider["path"] || settings.tracker.provider[:path],
      mirror_path: settings.janitor.tickets_path,
      issues_repo: settings.janitor.issues_repo,
      tickets_repo: settings.janitor.tickets_repo,
      workspace_root: settings.workspace.root,
      backend: settings.agent.backend,
      adapter: if(settings.agent.backend == "acp", do: settings.acp.adapter),
      model: if(settings.agent.backend == "acp", do: settings.acp.model),
      cli_path: acp_cli_path(settings),
      repos: Settings.clone_urls(settings.hooks.after_create || ""),
      reachable?: true,
      queue_present?: queue_present?(settings.tracker.provider),
      error: nil
    }
  end

  # ── Creating a project ───────────────────────────────────────────────────────

  @doc """
  The prompt skeleton a new project starts from.

  Generic on purpose: it says how to *behave* (resume rather than restart, do not end a turn while
  the ticket is still active, write down what you verified) and leaves what the project *is* to the
  person. Those three are the parts that are hard to get right and the same in every project.
  """
  @spec default_prompt() :: String.t()
  def default_prompt do
    """
    你正在做 `{{ issue.identifier }}`：{{ issue.title }}

    {% if attempt %}
    这是第 {{ attempt }} 次尝试（可能是正常续跑，也可能是失败后重试）：
    - 从**当前工作区的状态**继续，不要从头再来。
    - 已经查过、验过的东西不要重复，除非这次改动需要。
    - 除非被必需权限卡住，**不要**在工单还是进行中时结束回合。
    {% endif %}

    {% if issue.description %}
    ## 要做什么

    {{ issue.description }}
    {% endif %}

    ## 这个项目是什么

    <写 2-3 句：这个仓库是干什么的，代码在哪几个子目录里>

    ## 规矩

    - <这个项目特有的约定：怎么跑测试、什么不许动、提交信息怎么写 …>

    ## 怎么算做完了

    做完**自己验一遍**，然后在票里写下你验了什么、结论是什么。
    票的 `state` 改成 `in-review`（等人验收）；没做完或做不了就改成 `paused`，并**写清卡在哪**。
    """
  end

  @doc """
  Renders a project's workflow from a form's answers.

  Pure, so the page can render the exact bytes it is about to write -- and a test can prove that what
  it writes is a workflow the real parser accepts, rather than a shape that merely looks right.

  ## The front matter is ASCII, on purpose

  Measured 2026-09-28: `YamlElixir` reports `invalid_unicode` for some non-ASCII characters in the
  front matter -- the message pointed at `←` (U+2190) while other characters in the same document
  were fine, so which code points survive is not something this module is willing to guess. The
  workflow this machine actually runs has a handful of non-ASCII lines in its front matter and
  parses, which is exactly why guessing is the wrong move.

  So generated comments are English, generated values are ASCII, and everything meant for a person
  goes in the **body** -- which is not YAML and takes any language at all. `ascii_problems/1` refuses
  a form whose values would break this.
  """
  @spec render(map()) :: String.t()
  def render(attrs) do
    front_matter =
      [
        "---",
        # Comments stay English and values stay ASCII (see the moduledoc). The reasoning for each
        # key is in the body below, which is not YAML.
        "server:\n  host: 127.0.0.1\n  port: #{attrs[:port]}",
        tracker_block(attrs[:queue]),
        janitor_block(attrs),
        "workspace:\n  root: #{attrs[:workspace_root]}",
        "polling:\n  interval_ms: 5000",
        agent_block(attrs),
        # Its own block, joined at the top level: interpolating it into an indented heredoc put it
        # under `agent:` and the parser dropped it entirely -- which is how `adapter` silently fell
        # back to its default.
        backend_block(attrs),
        project_block(attrs),
        hooks_block(attrs)
      ]
      |> Enum.join("\n\n")

    front_matter <> "\n---\n\n" <> (attrs[:prompt] || default_prompt())
  end

  defp tracker_block(queue) do
    """
    tracker:
      kind: file
      provider:
        # NOTE: this key and janitor.tickets_path below are THE SAME DIRECTORY declared twice.
        # This one is what the orchestrator polls (where work is found); the other is what the
        # janitor mirrors. Change one and the instance keeps polling the other -- silently.
        path: #{queue}
      required_labels: []
      active_states: [open, ready]
      terminal_states: [done, cancelled]\
    """
  end

  defp janitor_block(attrs) do
    """
    janitor:
      enabled: true
      interval_ms: 30000
      issues_repo: #{attrs[:issues_repo]}
      tickets_repo: #{attrs[:tickets_repo]}
      tickets_path: #{attrs[:queue]}\
    """
  end

  defp agent_block(attrs) do
    """
    agent:
      backend: #{attrs[:backend] || "codex"}
      max_concurrent_agents: #{attrs[:max_concurrent_agents] || 2}
      max_turns: #{attrs[:max_turns] || 5}\
    """
  end

  # Every comment here is English because the front matter is ASCII-only; the reasoning is written up
  # in the body the person can read.
  defp backend_block(%{backend: "acp"} = attrs) do
    """
    acp:
      adapter: #{attrs[:adapter] || "dsh"}
      model: #{attrs[:model] || "auto"}
      # <- path to the adapter's CLI
      cli_path: #{attrs[:cli_path] || "<path-to-adapter-cli>"}
      init_timeout_ms: 150000\
    """
  end

  defp backend_block(%{backend: "commandcode"} = attrs) do
    """
    commandcode:
      model: #{attrs[:model] || "<model-name>"}\
    """
  end

  defp backend_block(attrs) do
    """
    codex:
      # WARNING: codex has no model field -- the model lives inside this shell string. A ticket
      # asking for a different model therefore cannot be honoured on codex, and says so.
      command: codex --config 'model="#{attrs[:model] || "<model-name>"}"' app-server\
    """
  end

  # `project.publish` is the one project-level choice this form makes: how finished work lands.
  # Only `publish` is written -- the sibling `project.isolation` is not offered by this page and is
  # not written here, so a file created by this form carries the schema's own default for it.
  #
  # The comment is English because the front matter is ASCII-only (see `render/1`).
  defp project_block(attrs) do
    """
    project:
      # pull_request pushes a branch and opens a pull request; direct commits and pushes the
      # project's own main branch, with no pull request.
      publish: #{publish_mode(attrs[:publish])}\
    """
  end

  # The modes are read from the schema rather than listed here, and anything else -- a form that
  # forgot the field, or a crafted POST -- falls back to the safe half instead of writing a file the
  # schema then refuses: "nothing lands on the project's own branch without review" is the default
  # this system is built on.
  defp publish_mode(value) do
    if value in Schema.Project.publishes(), do: value, else: "pull_request"
  end

  # A block scalar's indentation is set by its first line, so every line inside `after_create: |`
  # has to carry the same prefix -- mixing two widths ends the block early and the parser then sees a
  # scalar where a key should be.
  @hook_indent "        "

  defp hooks_block(attrs) do
    """
    hooks:
      timeout_ms: 600000
      after_create: |
    #{@hook_indent}# Ask git, not the filesystem: inside a worktree `.git` is a FILE, so
    #{@hook_indent}# `[ ! -d .git ]` is true and this would clone over an existing checkout.
    #{@hook_indent}if ! git -C . rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    #{clone_lines(attrs[:repos] || [])}
    #{@hook_indent}fi#{env_prep_block(attrs)}\
    """
  end

  defp clone_lines([]), do: "#{@hook_indent}  echo 'no repositories declared' >&2"

  defp clone_lines(repos) do
    repos
    |> Enum.map_join("\n", fn repo ->
      # Several repositories means one subdirectory each -- several code bases in one directory, which
      # the prompt has to say something about.
      target = if length(repos) > 1, do: " " <> Path.basename(repo), else: " ."

      "#{@hook_indent}  git clone --depth 1 #{repo_url(repo)}#{target}"
    end)
  end

  defp env_prep_block(%{env_prep: prep}) when is_binary(prep) and prep != "" do
    prep
    |> String.split("\n")
    |> Enum.map_join("\n", &(@hook_indent <> &1))
    |> then(&("\n" <> &1))
  end

  defp env_prep_block(_attrs), do: ""

  defp repo_url(repo) do
    if String.contains?(repo, "/") and not String.starts_with?(repo, ["http", "git@"]),
      do: "https://github.com/#{repo}",
      else: repo
  end

  @doc """
  Everything that must be true before a project file is written.

  Each message is something a person can act on, because each of these is a way a project can be
  created and then not run:

    * a **queue another project already claims** -- two instances racing for the same tickets and two
      janitors mirroring one ticket repository (measured, during the WorkBuddy smoke test);
    * a **queue directory that does not exist** -- the create path opens the GitHub issue first and
      writes the ticket second, so this leaves an issue with no ticket;
    * a **port another project already listens on**;
    * a **name**, repo or workspace that is missing or malformed.

  `existing` is passed in rather than read, so the rule can be tested without a registry.
  """
  @spec validate(map(), [project()], keyword()) :: :ok | {:error, [String.t()]}
  def validate(attrs, existing, opts \\ []) do
    repo_exists? = Keyword.get(opts, :repo_exists?, &repo_exists?/1)

    problems =
      name_problems(attrs, existing) ++
        queue_problems(attrs, existing, repo_exists?) ++
        port_problems(attrs, existing) ++
        repo_problems(attrs, repo_exists?) ++
        workspace_problems(attrs) ++
        ascii_problems(attrs)

    case problems do
      [] -> :ok
      problems -> {:error, problems}
    end
  end

  # Measured 2026-09-28: this parser reports `invalid_unicode` for a non-ASCII **value** in the front
  # matter -- quoting does not help, and it happens whether or not the value also contains `<`/`>`.
  # Chinese in a **comment** or in the **body** is fine, which is why the workflows on this machine
  # never hit it: their values are paths and URLs, and their Chinese lives in comments and prompts.
  #
  # So the rule for a front-matter value is ASCII, and the fields that carry free text a person might
  # write Chinese into -- environment prep above all -- are checked for it here rather than producing
  # a workflow that will not load.
  defp ascii_problems(attrs) do
    [
      {"队列目录", attrs[:queue]},
      {"issues 仓库", attrs[:issues_repo]},
      {"tickets 仓库", attrs[:tickets_repo]},
      {"工作区根目录", attrs[:workspace_root]},
      {"模型", attrs[:model]},
      {"adapter", attrs[:adapter]},
      {"环境准备", attrs[:env_prep]}
    ]
    |> Enum.flat_map(&ascii_problem/1)
    |> Kernel.++(Enum.flat_map(attrs[:repos] || [], &ascii_problem({"代码仓库", &1})))
  end

  defp ascii_problem({_label, value}) when value in [nil, ""], do: []

  defp ascii_problem({label, value}) do
    if String.printable?(value) and String.match?(value, ~r/^[\x20-\x7E\r\n\t]*$/) do
      []
    else
      [
        "#{label}里有非 ASCII 字符（中文等）⇒ 这份 workflow **解析不了** ✗\n" <>
          "　实测：front matter 的【值】里放非 ASCII，解析器报 invalid_unicode（加引号也没用）；\n" <>
          "　注释和正文里放中文没问题 ✓ ⇒ 说明写进 `#` 注释，别写进值里"
      ]
    end
  end

  defp name_problems(attrs, existing) do
    name = attrs[:name] || ""

    cond do
      String.trim(name) == "" ->
        ["项目名不能为空（它就是文件名）"]

      not Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/, name) ->
        ["项目名只能用字母数字和 . _ -，且不能以符号开头：#{name}"]

      String.downcase(name) == "readme" ->
        ["`README` 是注册表的说明，不能当项目名"]

      Enum.any?(existing, &(&1.name == name)) ->
        ["已经有一个叫 #{name} 的项目（#{Path.basename(registry_dir())}/#{name}.md）"]

      true ->
        []
    end
  end

  defp queue_problems(attrs, existing, repo_exists?) do
    queue = attrs[:queue] || ""

    cond do
      String.trim(queue) == "" ->
        ["队列目录不能为空"]

      not File.dir?(queue) ->
        ["队列目录不存在：#{queue}\n　先建好目录再来 —— 否则会【先建 issue、后写票失败】，\n　留下一个没有票据的 issue"]

      owner = Enum.find(existing, &(&1.queue == queue)) ->
        [
          "这个队列已经被项目 #{owner.name} 占了\n" <>
            "　**一个队列只能属于一个实例**：两个编排器会抢同一批票，两个 janitor 会镜像同一个票据仓库"
        ]

      # The tickets repository has to be *this directory's* remote, and it has to exist -- unless the
      # form says to create it, in which case it is created and cloned before the file is written.
      true ->
        queue_repo_problems(attrs, queue, repo_exists?)
    end
  end

  defp queue_repo_problems(attrs, queue, repo_exists?) do
    repo = attrs[:tickets_repo]

    cond do
      attrs[:create_tickets_repo] ->
        []

      not tickets_clone?(queue, repo) ->
        [
          "队列目录不是一个指向 #{repo} 的 git clone：#{queue}\n" <>
            "　janitor 是在**这个目录里** git add/commit/push 的 ⇒ 它必须就是那个票据仓库的检出 ✓\n" <>
            "　（勾上「帮我建」我会建仓库 + clone 过来；已存在的话自己 `git clone <url> .` 也行）"
        ]

      not repo_exists?.(repo) ->
        ["GitHub 上没有这个票据仓库：#{repo}（勾「帮我建」会自动创建）"]

      true ->
        []
    end
  end

  defp port_problems(attrs, existing) do
    port = attrs[:port]

    cond do
      not is_integer(port) ->
        ["端口必须是整数"]

      port < 1024 or port > 65_535 ->
        ["端口要在 1024–65535 之间：#{port}"]

      owner = Enum.find(existing, &(&1.port == port)) ->
        ["端口 #{port} 已经被项目 #{owner.name} 用了"]

      true ->
        []
    end
  end

  defp repo_problems(attrs, repo_exists?) do
    []
    |> require_repo(:issues_repo, "issues 仓库", attrs[:issues_repo], attrs[:create_issues_repo], repo_exists?)
    |> require_repo(:tickets_repo, "tickets 仓库", attrs[:tickets_repo], attrs[:create_tickets_repo], repo_exists?)
    |> add_problem(
      (attrs[:repos] || []) == [],
      "至少要有一个代码仓库（hooks.after_create 里的 git clone）—— 否则 agent 会跑在一个空目录里"
    )
  end

  # A repo that does not exist is an error unless the form says to create it, because the first
  # issue creation would fail and the project would look fine until then. A repo that *does* exist
  # while "create" is ticked is only a note: `gh repo create` would fail, and the form says it will
  # not be run.
  defp require_repo(problems, _key, label, value, create?, repo_exists?) do
    cond do
      not valid_repo?(value) ->
        problems ++ ["#{label}要写 owner/仓库 的形式，现在是：#{inspect(value)}"]

      create? and repo_exists?.(value) ->
        problems ++ ["#{label} #{value} 已经存在 ⇒ 勾了「帮我建」也不会重复建（去掉勾选即可）"]

      not create? and not repo_exists?.(value) ->
        problems ++ ["GitHub 上没有 #{label}：#{value}（勾「帮我建」会自动创建）"]

      true ->
        problems
    end
  end

  defp valid_repo?(value) when is_binary(value),
    do: Regex.match?(~r{^[\w.\-]+/[\w.\-]+$}, value)

  defp valid_repo?(_value), do: false

  @doc "Whether `owner/name` exists on GitHub, judged by `gh repo view`'s own exit status."
  @spec repo_exists?(String.t() | nil) :: boolean()
  def repo_exists?(repo) when is_binary(repo) do
    case Shell.run("gh", ["repo", "view", repo, "--json", "name"], timeout: 15_000) do
      {:ok, _output, 0} -> true
      _ -> false
    end
  end

  def repo_exists?(_repo), do: false

  @doc """
  Creates `owner/name` on GitHub, with one README commit.

  `--add-readme` is not decoration: the janitor mirrors the ticket repository with
  `pull --rebase --autostash` and `push`, and an entirely empty repository has no branch to pull.
  Private by default -- a task queue is not public reading.
  """
  @spec create_repo(String.t(), keyword()) :: :ok | {:error, term()}
  def create_repo(repo, opts \\ []) do
    visibility = if Keyword.get(opts, :public, false), do: "--public", else: "--private"

    args = ["repo", "create", repo, visibility, "--add-readme"]

    case Shell.run("gh", args, timeout: 120_000) do
      {:ok, _output, 0} -> :ok
      {:ok, output, status} -> {:error, {:gh_exit, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Makes sure `path` is a clone of `repo`.

  Already a checkout of it ⇒ `:ok`. A non-empty directory that is not ⇒ an error naming both, because
  the alternative is cloning into whatever is already there. An empty directory (or a fresh one) is
  cloned into, the same way the workspace hooks do it.
  """
  @spec ensure_clone(String.t(), String.t()) :: :ok | {:error, term()}
  def ensure_clone(repo, path) do
    cond do
      tickets_clone?(path, repo) ->
        :ok

      File.dir?(path) and File.ls!(path) != [] ->
        {:error, {:not_empty, path}}

      true ->
        File.mkdir_p!(path)
        url = if String.starts_with?(repo, ["http", "git@"]), do: repo, else: "https://github.com/#{repo}"

        case Shell.run("git", ["clone", url, "."], cd: path, timeout: 300_000) do
          {:ok, _output, 0} -> :ok
          {:ok, output, status} -> {:error, {:git_exit, status, output}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # The directory is a checkout *of that repository* -- not merely "a git directory", which is what a
  # clone of something else would also be.
  defp tickets_clone?(path, repo) when is_binary(path) and is_binary(repo) do
    case Shell.run("git", ["-C", path, "remote", "get-url", "origin"], timeout: 10_000) do
      {:ok, url, 0} -> String.contains?(url, repo)
      _ -> false
    end
  end

  defp tickets_clone?(_path, _repo), do: false

  defp workspace_problems(attrs) do
    add_problem([], String.trim(attrs[:workspace_root] || "") == "", "工作区根目录不能为空")
  end

  defp add_problem(problems, true, message), do: problems ++ [message]
  defp add_problem(problems, false, _message), do: problems

  @doc """
  Things that will still work but that a person should know before starting it.

  The credential check is a warning rather than an error on purpose: what matters is whether the
  token is visible to the **instance that will run this project**, and this page can only see its
  own environment. A project started from a shell that has the variable is fine even when this
  process cannot see it.
  """
  @spec warnings(map()) :: [String.t()]
  def warnings(attrs) do
    credential_warnings(attrs) ++ workspace_warnings(attrs) ++ multi_repo_warnings(attrs)
  end

  # Several code repositories is a shape the form accepts and the workspace hook handles (one
  # subdirectory each), but **publishing is written for one**: `publish_ticket/2` requires the
  # workspace root itself to be a work tree, and with clones in subdirectories it is not -- so the
  # ticket would sit in `in-review` and no pull request would appear.
  #
  # Saying so beats letting a project be created that quietly never finishes. The real fix is not a
  # loop: a ticket touching two repositories has **two** pull requests, so "the PR" has to become a
  # list first, and that is a change to the publish design rather than to this function.
  defp multi_repo_warnings(attrs) do
    case length(attrs[:repos] || []) do
      0 -> []
      1 -> []
      count -> ["⚠️ 这个项目声明了 #{count} 个代码仓库 ⇒ 它们会被 clone 进各自子目录 ✓，" <>
          "但**发布那步是按单仓库写的** ✗ ⇒ 这张票不会自动出 PR（会停在 in-review）"]
    end
  end

  # One warning per missing credential, rather than one expression that tries to say both.
  defp credential_warnings(attrs) do
    case {attrs[:backend] || "codex", attrs[:adapter] || "dsh"} do
      {"acp", "workbuddy"} ->
        missing_credential_warning("workbuddy", "CODEBUDDY_AUTH_TOKEN")

      {"acp", "dsh"} ->
        missing_credential_warning("dsh", "CMD_API_KEY")

      _other ->
        []
    end
  end

  defp missing_credential_warning(agent, variable) do
    if credential_visible?(variable) do
      []
    else
      [
        "⚠️ 这个项目要用 #{agent}，但 #{variable} 对**本进程**不可见 ✓" <>
          "　（对新进程来说可能是可见的 —— 从新终端启动就没问题；这一页只能看到自己的环境）"
      ]
    end
  end

  defp workspace_warnings(attrs) do
    root = attrs[:workspace_root] || ""

    if File.dir?(root) do
      []
    else
      ["工作区根目录还不存在 —— 没关系，每个工单会自己创建（#{root}）"]
    end
  end

  defp credential_visible?(name) do
    case Enum.find(Settings.credentials(), &(&1.name == name)) do
      %{} = credential -> Map.get(credential, :visible?) == true
      _ -> false
    end
  rescue
    _error -> false
  end

  @doc """
  Writes the project file, then commits it in the registry repository.

  The file is written **first** and the commit is best effort, because a project that exists but is
  not committed is recoverable by hand while a commit that failed after nothing was written is just
  a lost form. What happened to the commit is returned, not swallowed.
  """
  @spec create(map(), [project()]) :: {:ok, String.t(), [String.t()]} | {:error, term()}
  def create(attrs, existing) do
    case validate(attrs, existing) do
      :ok ->
        # Repositories first, the project file second. A file naming a repository that was never
        # created leaves a project that looks configured and fails on its first task -- so nothing is
        # written if provisioning does not finish, and the form still holds what was typed.
        with :ok <- provision(attrs) do
          path = Path.join(registry_dir(), "#{attrs[:name]}.md")
          File.mkdir_p!(registry_dir())
          File.write!(path, render(attrs))

          {:ok, path, commit_note(path)}
        end

      {:error, problems} ->
        {:error, {:invalid, problems}}
    end
  end

  defp provision(attrs) do
    with :ok <- maybe_create(attrs[:issues_repo], attrs[:create_issues_repo]),
         :ok <- maybe_create(attrs[:tickets_repo], attrs[:create_tickets_repo]),
         :ok <- ensure_clone(attrs[:tickets_repo], attrs[:queue]) do
      :ok
    else
      {:error, reason} -> {:error, {:provisioning_failed, reason}}
    end
  end

  defp maybe_create(repo, create?) when create? in [true, "true"], do: create_repo(repo, public: false)
  defp maybe_create(_repo, _create?), do: :ok

  defp commit_note(path) do
    name = Path.basename(path)

    with {:ok, _out, 0} <- Shell.run("git", ["-C", registry_dir(), "add", name], timeout: 10_000),
         {:ok, _out, 0} <-
           Shell.run(
             "git",
             ["-C", registry_dir(), "commit", "-m", "projects: add #{name}", "--", name],
             timeout: 10_000
           ) do
      ["已在注册表仓库里提交（#{name}）"]
    else
      other ->
        ["⚠️ 文件写了，但没提交到注册表仓库（#{inspect(other)}）—— 自己 `git -C #{registry_dir()} add -A && commit` 一下"]
    end
  end
end
