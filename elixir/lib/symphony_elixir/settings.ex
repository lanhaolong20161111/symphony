defmodule SymphonyElixir.Settings do
  @moduledoc """
  What this instance is *actually* running: the effective configuration, where its credentials
  come from, and which of them this process can see.

  ## Effective, not "as written"

  The workflow file is not the answer to "what is in effect". Missing keys are filled from schema
  defaults (`agent.backend` is `codex` when nothing says otherwise), `$VAR` references are resolved
  from the environment, and -- the case that matters most -- when the file currently fails to parse,
  `WorkflowStore` keeps serving the last known good configuration. So the file and the running
  configuration can disagree, and this module reports the running one.

  ## Credentials: presence, never value

  Two facts are reported per credential, and the difference between them is the useful signal:

    * `user_scope?` -- set in the Windows **User** environment (read from the registry);
    * `process?` -- visible to *this* process.

  A credential that is `user_scope?` but not `process?` means this service was started from a shell
  whose environment predates the variable, so it inherits an empty value and the agent will fail to
  authenticate while every status display says the key is set. Values are never read out to the page
  -- not even masked, since a mask is still a value to attack.

  ## Writing is validated before it lands

  Every edit is applied to the text, then the result is parsed and schema-checked **before** the
  real file is touched. `WorkflowStore` would reject a bad file and keep running the old config, but
  then the only feedback would be a log line -- and the next restart would read the broken file.
  """

  require Logger

  alias SymphonyElixir.{Config, Shell, Workflow, WorkflowEditor}
  alias SymphonyElixir.Config.Schema

  @typedoc "One credential this system may need, and what to do about it."
  @type credential :: %{
          name: String.t(),
          used_by: String.t(),
          process?: boolean(),
          user_scope?: boolean() | :unknown,
          length: non_neg_integer() | nil
        }

  # Keys the settings page may write, and nothing else. Deliberately a curated list rather than
  # "any key in the file": each entry here has been checked to be a scalar whose change cannot
  # restructure the document, and the page shows exactly these.
  @editable [
    %{path: ["tracker", "provider", "path"], label: "票据队列目录（编排器读它）", type: :string,
      hint: "★ 编排器从哪找活。与下面的 janitor.tickets_path 是**同一个目录**，改动会同时写两处"},
    %{path: ["janitor", "tickets_path"], label: "票据目录（janitor 镜像用）", type: :string,
      hint: "★ 与 tracker.provider.path 成对，改动会同时写两处"},
    %{path: ["workspace", "root"], label: "工作区根目录", type: :string,
      hint: "★ 每个工单一个子目录。与 janitor.workspace_root 成对，改动会同时写两处"},
    %{path: ["janitor", "workspace_root"], label: "工作区根目录（janitor 用）", type: :string,
      hint: "★ 与 workspace.root 成对，改动会同时写两处"},
    %{path: ["janitor", "issues_repo"], label: "issues 仓库（owner/name）", type: :string,
      hint: "任务页建出来的 GitHub issue 进这个仓库"},
    %{path: ["janitor", "tickets_repo"], label: "票据仓库（owner/name）", type: :string,
      hint: "票据文件所在的仓库，issue 正文会链回它"},
    %{path: ["janitor", "interval_ms"], label: "janitor 间隔（毫秒）", type: :integer},
    %{path: ["janitor", "enabled"], label: "启用 janitor", type: :boolean},
    %{path: ["agent", "max_concurrent_agents"], label: "并发 agent 数", type: :integer},
    %{path: ["agent", "max_turns"], label: "每单最大回合", type: :integer},
    %{path: ["acp", "adapter"], label: "ACP adapter", type: :string, hint: "dsh 或 workbuddy"},
    %{path: ["acp", "model"], label: "ACP model", type: :string, hint: "留空即用 agent 自报的默认"}
  ]

  # Keys that must always carry the same value, because they are the same thing declared twice.
  #
  # Measured, the hard way: an instance whose `janitor.tickets_path` pointed at a scratch directory
  # but whose `tracker.provider.path` still pointed at the real one **polled the real directory and
  # never saw the new ticket** -- with no error anywhere, because from each key's point of view
  # nothing was wrong. Saving either half of a pair writes both.
  @linked [
    {["tracker", "provider", "path"], ["janitor", "tickets_path"]},
    {["workspace", "root"], ["janitor", "workspace_root"]}
  ]

  @doc """
  The site this instance serves: which GitHub repositories its work touches, and where the agent's
  local copy of the code comes from.

  ## The code source is read out of the hook, not derived

  `hooks.after_create` is what actually clones the code (`git clone … <workspace>`), so that string
  is the only place the code repository is declared. It is **not** derived from
  `janitor.issues_repo`, and on this machine both point at `beekeeper` today purely because someone
  wrote the same name twice. Change one and the other silently keeps cloning the old repository --
  which is why `matches_issues_repo?` is reported instead of assumed.
  """
  @spec site() :: map()
  def site do
    settings = Config.settings!()
    issues = settings.janitor.issues_repo
    tickets = settings.janitor.tickets_repo
    code = code_source(settings)

    %{
      issues_repo: issues,
      issues_url: github_url(issues),
      tickets_repo: tickets,
      tickets_url: github_url(tickets),
      tickets_path: settings.janitor.tickets_path,
      workspace_root: settings.workspace.root,
      code: code
    }
  rescue
    error -> %{error: Exception.message(error)}
  end

  defp code_source(settings) do
    hook = settings.hooks.after_create || ""
    url = clone_url(hook)
    repo = url && repo_from_url(url)
    issues = settings.janitor.issues_repo

    %{
      repo: repo,
      url: url,
      declared_in: "hooks.after_create",
      path: Path.join(settings.workspace.root || "…", "<工单号>"),
      matches_issues_repo?: is_binary(repo) and is_binary(issues) and repo == issues
    }
  end

  defp clone_url(text) do
    case Regex.run(~r{git clone[^\n]*?(https://github\.com/[\w.\-]+/[\w.\-]+)}, text) do
      [_, url] -> url
      _ -> nil
    end
  end

  defp repo_from_url(url) do
    case Regex.run(~r{https://github\.com/([\w.\-]+/[\w.\-]+)}, url) do
      [_, repo] -> String.replace_suffix(repo, ".git", "")
      _ -> nil
    end
  end

  defp github_url(repo) when is_binary(repo) and repo != "", do: "https://github.com/#{repo}"
  defp github_url(_repo), do: nil

  @doc """
  The repositories this machine's `gh` can see, for the settings form's picker.

  Best effort and read-only: the form stays a plain text input (a `datalist` of these), so a repo
  that is not listed -- a brand new one, or one `gh` is not authenticated for -- can still be typed.
  A picker that could only offer what `gh` returned would be a new way to be stuck.
  """
  @spec github_repos() :: {:ok, [String.t()]} | {:error, term()}
  def github_repos do
    args = ["repo", "list", "--limit", "100", "--json", "nameWithOwner"]

    case Shell.run("gh", args, timeout: 15_000) do
      {:ok, output, 0} ->
        case JSON.decode(output) do
          {:ok, list} when is_list(list) ->
            repos =
              list
              |> Enum.map(& &1["nameWithOwner"])
              |> Enum.reject(&(is_nil(&1) or &1 == ""))
              |> Enum.sort()

            {:ok, repos}

          _ ->
            {:error, :unexpected_gh_payload}
        end

      {:ok, output, status} ->
        {:error, {:gh_exit, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  @doc """
  The effective configuration, as the running system resolved it.

  Returns `{:ok, sections}` where `sections` is a list of `%{title, rows}`, so the page can render
  it without knowing the schema's shape.
  """
  @spec effective() :: {:ok, [map()]} | {:error, term()}
  def effective do
    settings = Config.settings!()

    {:ok,
     [
       %{
         title: "GitHub",
         rows: [
           {"issues 仓库", settings.janitor.issues_repo},
           {"票据仓库", settings.janitor.tickets_repo}
         ]
       },
       %{
         title: "tracker",
         rows: [
           {"kind", settings.tracker.kind},
           {"active states", inspect(settings.tracker.active_states)},
           {"terminal states", inspect(settings.tracker.terminal_states)},
           {"provider path", provider_value(settings.tracker.provider, "path")}
         ]
       },
       %{
         title: "janitor",
         rows: [
           {"enabled", settings.janitor.enabled},
           {"interval_ms", settings.janitor.interval_ms},
           {"tickets_path", settings.janitor.tickets_path},
           {"workspace_root", settings.janitor.workspace_root},
           {"state_file", settings.janitor.state_file}
         ]
       },
       %{
         title: "agent",
         rows: [
           {"backend", settings.agent.backend},
           {"max_concurrent_agents", settings.agent.max_concurrent_agents},
           {"max_turns", settings.agent.max_turns},
           {"max_retry_backoff_ms", settings.agent.max_retry_backoff_ms}
         ]
       },
       %{
         title: "acp / codex",
         rows: [
           {"acp.adapter", settings.acp.adapter},
           {"acp.model", settings.acp.model},
           {"acp.cli_path", settings.acp.cli_path},
           {"acp.authenticate", settings.acp.authenticate},
           {"acp.turn_timeout_ms", settings.acp.turn_timeout_ms},
           {"codex.command", settings.codex.command}
         ]
       },
       %{
         title: "workspace / server / polling",
         rows: [
           {"workspace.root", settings.workspace.root},
           {"server", "#{settings.server.host}:#{settings.server.port}"},
           {"polling.interval_ms", settings.polling.interval_ms},
           {"server.tracker_tools", settings.server.tracker_tools}
         ]
       }
     ]}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp provider_value(provider, key) when is_map(provider), do: Map.get(provider, key)
  defp provider_value(_provider, _key), do: nil

  @doc """
  The credentials this system may need, with **presence only** -- never a value.

  `user_scope?` is `:unknown` where the registry cannot be read (not Windows, or `reg` is absent),
  which is reported rather than guessed.
  """
  @spec credentials() :: [credential()]
  def credentials do
    user_scope = user_scope_environment()

    [
      %{name: "CMD_API_KEY", used_by: "dsh（ACP 后端）", note: "dsh 那条无人值守线的凭据"},
      %{name: "CODEBUDDY_AUTH_TOKEN", used_by: "workbuddy（ACP 后端）", note: "一次性铸造，约 55 天到期"},
      %{name: "CODEBUDDY_API_KEY", used_by: "workbuddy（走 API 计费那条）", note: "与订阅额度是两笔账"},
      %{name: "GITHUB_TOKEN", used_by: "github tracker / janitor / gh", note: "建 issue、镜像状态都用它"},
      %{name: "LINEAR_API_KEY", used_by: "linear tracker", note: ""},
      %{name: "JIRA_API_TOKEN", used_by: "jira tracker", note: ""},
      %{name: "ASANA_PAT", used_by: "asana tracker", note: ""},
      %{name: "GITLAB_PAT", used_by: "gitlab tracker", note: ""},
      %{name: "DEEPSEEK_API_KEY", used_by: "DeepSeek 官方 key", note: "与 CommandCode 网关是两笔账"}
    ]
    |> Enum.map(fn credential ->
      process_value = System.get_env(credential.name)

      scope_value =
        case user_scope do
          :unknown -> :unknown
          map -> Map.get(map, credential.name)
        end

      credential
      |> Map.put(:process?, process_value != nil)
      |> Map.put(:user_scope?, scope_value == :unknown or scope_value != nil)
      |> Map.put(:length, presence_length(process_value || scope_value))
    end)
  end

  defp presence_length(nil), do: nil
  defp presence_length(value) when is_binary(value), do: String.length(value)

  @doc """
  True when a peer address is loopback.

  Public so the rule can be tested directly instead of only through a socket: it is the whole
  guard on the write path (see the settings LiveView), and a guard nobody can exercise is a guard
  nobody knows still works.
  """
  @spec loopback_peer?(term()) :: boolean()
  def loopback_peer?(%{address: {127, _b, _c, _d}}), do: true
  def loopback_peer?(%{address: {0, 0, 0, 0, 0, 0, 0, 1}}), do: true
  def loopback_peer?(_peer), do: false

  # `reg query` rather than a .NET call: this is the User environment as Windows itself stores it,
  # and it is one subprocess for every variable instead of one per name. Non-Windows, or a machine
  # where `reg` is missing, degrades to `:unknown` -- which the page states instead of implying
  # "not set".
  defp user_scope_environment do
    case Shell.run("reg", ["query", "HKCU\\Environment"], timeout: 5_000) do
      {:ok, output, 0} -> parse_reg_query(output)
      _ -> :unknown
    end
  rescue
    _error -> :unknown
  end

  defp parse_reg_query(output) do
    output
    |> String.split(~r/\R/)
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\s{4}(\S+)\s+REG_\w+\s*(.*)$/, line) do
        [_, name, value] -> [{name, String.trim(value)}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  @doc "The keys the settings page is allowed to write, with their current effective values."
  @spec editable() :: [map()]
  def editable do
    settings = Config.settings!()

    Enum.map(@editable, fn entry ->
      Map.put(entry, :value, read_path(settings, entry.path))
    end)
  rescue
    _error -> @editable
  end

  defp read_path(settings, [section, key]) do
    settings |> Map.get(String.to_existing_atom(section)) |> Map.get(String.to_existing_atom(key))
  end

  @doc """
  Writes one curated key into the workflow file, **after** proving the result still parses.

  A key that belongs to a linked pair writes **both** halves: they are one thing declared twice, and
  updating one leaves the instance reading the other (measured: a ticket queue that the orchestrator
  never polled, silently).

  Returns `{:ok, workflow_path, written_paths}` or `{:error, reason}`. The original file is copied
  beside itself before the write, so a wrong value is one rename away from being undone -- and the
  validation step means a wrong value should never get that far.
  """
  @spec update([String.t()], String.t()) :: {:ok, String.t(), [[String.t()]]} | {:error, term()}
  def update(path, raw_value) do
    with {:ok, entry} <- find_editable(path),
         {:ok, value} <- coerce(entry, raw_value),
         workflow_path = Workflow.workflow_file_path(),
         {:ok, text} <- File.read(workflow_path),
         written = linked_paths(path),
         {:ok, updated} <- write_all(text, written, value),
         :ok <- validate(updated) do
      backup_path = workflow_path <> ".bak"
      File.write!(backup_path, text)
      File.write!(workflow_path, updated)

      Logger.info(
        "settings: #{Enum.map_join(written, " + ", &Enum.join(&1, "."))} -> #{inspect(value)}"
      )

      {:ok, workflow_path, written}
    end
  end

  @doc """
  Every path that must carry the same value as `path`, including `path` itself.

  Public so the page can say which keys a save will touch, instead of leaving a person to discover
  it in the file.
  """
  @spec linked_paths([String.t()]) :: [[String.t()]]
  def linked_paths(path) do
    case Enum.find(@linked, fn {a, b} -> a == path or b == path end) do
      nil -> [path]
      {a, b} -> [a, b]
    end
  end

  # Both halves or neither: a half-applied pair is the failure this exists to prevent, so a failure
  # on the second key returns the error rather than the partially written text.
  defp write_all(text, paths, value) do
    Enum.reduce_while(paths, {:ok, text}, fn path, {:ok, acc} ->
      case WorkflowEditor.put_scalar(acc, path, value) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, {:linked_write_failed, path, reason}}}
      end
    end)
  end

  defp find_editable(path) do
    case Enum.find(@editable, &(&1.path == path)) do
      nil -> {:error, {:not_editable, path}}
      entry -> {:ok, entry}
    end
  end

  defp coerce(%{type: :integer}, raw) do
    case Integer.parse(String.trim(to_string(raw))) do
      {value, ""} -> {:ok, value}
      _ -> {:error, {:not_an_integer, raw}}
    end
  end

  defp coerce(%{type: :boolean}, raw) do
    case String.trim(to_string(raw)) |> String.downcase() do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      other -> {:error, {:not_a_boolean, other}}
    end
  end

  defp coerce(%{type: :string}, raw) when is_binary(raw), do: {:ok, String.trim(raw)}
  defp coerce(%{type: :string}, raw), do: {:ok, to_string(raw)}

  # The safety net. `WorkflowStore` would refuse a bad file and keep the old config, but it would
  # only say so in the log -- and the broken file would still be there for the next restart.
  defp validate(text) do
    path = Path.join(System.tmp_dir!(), "settings-check-#{System.unique_integer([:positive])}.md")
    File.write!(path, text)

    try do
      with {:ok, loaded} <- Workflow.load(path),
           {:ok, settings} <- Schema.parse(loaded.config) do
        Config.validate_settings(settings)
      end
    after
      File.rm(path)
    end
  end
end
