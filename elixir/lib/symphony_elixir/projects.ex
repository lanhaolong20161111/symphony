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
  """
  @spec list() :: [project()]
  def list do
    registry_dir()
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) == "README.md"))
    |> Enum.sort()
    |> Enum.map(&load/1)
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

  defp load(path) do
    name = Path.basename(path, ".md")

    with {:ok, loaded} <- Workflow.load(path),
         {:ok, settings} <- Schema.parse(loaded.config) do
      from_settings(blank(name, path), settings)
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
      repos: [],
      reachable?: false,
      queue_present?: false,
      error: nil
    }
  end

  defp from_settings(base, settings) do
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
          repos: Settings.clone_urls(settings.hooks.after_create || ""),
          reachable?: url != nil and reachable?(url),
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

  defp reachable?(url) do
    case Req.get(url <> "/api/v1/state", receive_timeout: @probe_timeout_ms) do
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

  @doc "Whether the registry directory exists at all."
  @spec present?() :: boolean()
  def present?, do: File.dir?(registry_dir())

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
      repos: Settings.clone_urls(settings.hooks.after_create || ""),
      reachable?: true,
      queue_present?: queue_present?(settings.tracker.provider),
      error: nil
    }
  end
end
