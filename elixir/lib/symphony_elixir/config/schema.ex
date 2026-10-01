defmodule SymphonyElixir.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.PathSafety

  @primary_key false
  @linear_endpoint "https://api.linear.app/graphql"
  @linear_active_states ["Todo", "In Progress"]
  @linear_terminal_states ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]

  @type t :: %__MODULE__{}

  defmodule StringOrMap do
    @moduledoc false
    @behaviour Ecto.Type

    @spec type() :: :map
    def type, do: :map

    @spec embed_as(term()) :: :self
    def embed_as(_format), do: :self

    @spec equal?(term(), term()) :: boolean()
    def equal?(left, right), do: left == right

    @spec cast(term()) :: {:ok, String.t() | map()} | :error
    def cast(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def cast(_value), do: :error

    @spec load(term()) :: {:ok, String.t() | map()} | :error
    def load(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def load(_value), do: :error

    @spec dump(term()) :: {:ok, String.t() | map()} | :error
    def dump(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  # `tracker.secret_environment_names` names the variables that must be *unset* in an agent's child
  # process, so a tracker credential never reaches a run with no business holding it (SPEC.md calls
  # the setting a MUST). The only shape that can mean anything is a list of names, so anything else is
  # refused rather than emptied: a bare string reads like one name but is not a list, a blank entry
  # names no variable at all, and a value silently coerced to `[]` is precisely the failure this
  # setting exists to prevent -- the credential stays in the child's environment and nothing says so.
  #
  # Messages carry no field name of their own: `format_errors/1` prefixes the setting they were raised
  # on, so a workflow author reads `tracker.secret_environment_names must contain only ...`.
  defmodule SecretEnvironmentNames do
    @moduledoc false
    @behaviour Ecto.Type

    @type t :: [String.t()]

    @not_a_list "must be a list of environment variable names"
    @bad_name "must contain only non-empty environment variable names"

    @spec type() :: {:array, :string}
    def type, do: {:array, :string}

    @spec embed_as(term()) :: :self
    def embed_as(_format), do: :self

    @spec equal?(term(), term()) :: boolean()
    def equal?(left, right), do: left == right

    @spec cast(term()) :: {:ok, t()} | {:error, keyword()}
    def cast(names) when is_list(names) do
      if Enum.all?(names, &valid_name?/1) do
        {:ok, names}
      else
        {:error, [message: @bad_name]}
      end
    end

    def cast(_value), do: {:error, [message: @not_a_list]}

    @spec load(term()) :: {:ok, t()} | :error
    def load(names) when is_list(names), do: {:ok, names}
    def load(_value), do: :error

    @spec dump(term()) :: {:ok, t()} | :error
    def dump(names) when is_list(names), do: {:ok, names}
    def dump(_value), do: :error

    defp valid_name?(name), do: is_binary(name) and String.trim(name) != ""
  end

  defmodule Tracker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:kind, :string)
      field(:endpoint, :string)
      field(:api_key, :string)
      field(:project_slug, :string)
      field(:assignee, :string)
      field(:provider, :map, default: %{})
      field(:secret_environment_names, SecretEnvironmentNames, default: [])
      field(:required_labels, {:array, :string}, default: [])
      field(:active_states, {:array, :string})
      field(:terminal_states, {:array, :string})
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :kind,
          :endpoint,
          :api_key,
          :project_slug,
          :assignee,
          :provider,
          :secret_environment_names,
          :required_labels,
          :active_states,
          :terminal_states
        ],
        empty_values: []
      )
      |> update_change(:required_labels, fn labels ->
        labels
        |> Enum.map(&(String.trim(&1) |> String.downcase()))
        |> Enum.uniq()
      end)
    end
  end

  defmodule Polling do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:interval_ms, :integer, default: 30_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:interval_ms], empty_values: [])
      |> validate_number(:interval_ms, greater_than: 0)
    end
  end

  defmodule Workspace do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:root, :string, default: Path.join(System.tmp_dir!(), "symphony_workspaces"))
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:root], empty_values: [])
    end
  end

  # How a project's tickets are *worked* and how their work is *published*. Two settings rather than
  # one menu, because the four combinations are not a sequence: "one clone per ticket" and "the host
  # opens a pull request" are independent choices, and the shapes this machine runs are
  # per_ticket+pull_request (one clone and one `symphony/<ticket>` branch per ticket) and
  # per_ticket+direct (still one clone per ticket, but the work is pushed to the project's own
  # branch). shared+direct -- one tree for the whole project, where a ticket branch would be
  # meaningless -- is not one of them: `shared` is declared and refused, see `Project.changeset/2`.
  defmodule Project do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @isolations ["per_ticket", "shared"]
    @publishes ["pull_request", "direct"]

    # The values `@isolations` names but this build does not honour. `isolations/0` still lists them --
    # the setting is real, the implementation behind it is not -- and `changeset/2` refuses them out
    # loud instead of accepting one and quietly doing something else.
    @unimplemented_isolations ["shared"]

    @primary_key false
    embedded_schema do
      # `per_ticket` is the default because it is what every project on this machine already does and
      # what makes two tickets in one repository safe: each gets its own clone under
      # `workspace.root`, so neither can overwrite the other's files.
      #
      # `shared` -- one tree for the whole project -- is declared for a future implementation and is
      # refused today by `validate_isolation_is_implemented/1` below: nothing in the tree honours it,
      # so a workflow that asks for `shared` would silently be given one clone per ticket instead.
      field(:isolation, :string, default: "per_ticket")

      # `pull_request` is the default because it is the safer half: the work waits on a branch until
      # somebody looks at it, and nothing lands on the project's own branch without review. `direct`
      # writes to that branch, so it stays something a project opts into.
      field(:publish, :string, default: "pull_request")
    end

    @doc false
    @spec isolations() :: [String.t()]
    def isolations, do: @isolations

    @doc false
    @spec publishes() :: [String.t()]
    def publishes, do: @publishes

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:isolation, :publish], empty_values: [])
      |> validate_inclusion(:isolation, @isolations)
      |> validate_isolation_is_implemented()
      |> validate_inclusion(:publish, @publishes)
    end

    # `shared` casts and includes cleanly and then does nothing, and that is the failure this refuses:
    # a file that says "one tree for the whole project", silently given one clone per ticket.
    #
    # A rule about the field itself rather than the cross-field `validate_shared_isolation/1` at the
    # bottom of this file: that one is about a *combination* (`shared` beside parallel agents) and can
    # only speak once an `agent` section is present, while "not implemented" has to be said whatever
    # else the file contains.
    #
    # `validate_change/3` fires only for a value a file actually wrote, so an omitted key and an
    # explicit `per_ticket` both pass through exactly as before.
    defp validate_isolation_is_implemented(changeset) do
      validate_change(changeset, :isolation, fn :isolation, isolation ->
        if isolation in @unimplemented_isolations do
          [
            isolation: "#{isolation} is not implemented yet -- per_ticket is the only isolation mode available"
          ]
        else
          []
        end
      end)
    end
  end

  defmodule Worker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:ssh_hosts, {:array, :string}, default: [])
      field(:max_concurrent_agents_per_host, :integer)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:ssh_hosts, :max_concurrent_agents_per_host], empty_values: [])
      |> validate_number(:max_concurrent_agents_per_host, greater_than: 0)
    end
  end

  defmodule Agent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @backends ["codex", "acp", "commandcode"]

    @primary_key false
    embedded_schema do
      field(:backend, :string, default: "codex")
      field(:max_concurrent_agents, :integer, default: 10)
      field(:max_turns, :integer, default: 20)
      field(:max_retry_backoff_ms, :integer, default: 300_000)
      field(:max_concurrent_agents_by_state, :map, default: %{})
    end

    @doc false
    @spec backends() :: [String.t()]
    def backends, do: @backends

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:backend, :max_concurrent_agents, :max_turns, :max_retry_backoff_ms, :max_concurrent_agents_by_state],
        empty_values: []
      )
      |> validate_inclusion(:backend, @backends)
      |> validate_number(:max_concurrent_agents, greater_than: 0)
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:max_retry_backoff_ms, greater_than: 0)
      |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
      |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
    end
  end

  defmodule Codex do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    # Exactly the keys `GitHubAppToken.installation_token/1` takes, so the setting and the mint agree
    # on what an App is described by. `account` is here because that module takes it: an App installed
    # on several accounts needs it -- or `installation_id` -- to say which installation this project
    # means.
    @app_token_keys ["app_id", "private_key_path", "installation_id", "account"]
    @app_token_required_keys ["app_id", "private_key_path"]

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "codex app-server")

      # codex 0.154.0 renamed this tagged variant: the old `reject` tag is gone and the
      # app-server answers `-32600 unknown variant \`reject\`, expected one of
      # untrusted | on-request | granular | never`. The inner shape and its meaning ("reject
      # these approval categories outright") are unchanged, so `granular` is the
      # semantics-preserving rename — verified against a real `codex app-server` on 2026-09-21
      # (both `granular` and the string `never` are accepted).
      #
      # Do **not** "simplify" this to `"never"`: that means *never ask for approval*, i.e. let the
      # agent proceed — the opposite of this fail-closed default.
      field(:approval_policy, StringOrMap,
        default: %{
          "granular" => %{
            "sandbox_approval" => true,
            "rules" => true,
            "mcp_elicitations" => true
          }
        }
      )

      field(:thread_sandbox, :string, default: "workspace-write")
      field(:turn_sandbox_policy, :map)

      # Codex makes a checkout's git metadata read-only under `workspace-write`, which stops an agent
      # from committing or branching even though it can edit every source file. Turning this on adds
      # the workspace's resolved git dir and common dir to `writableRoots`, so the agent can do the git
      # work the workflow's skills describe. Off by default: nothing changes until a workflow asks.
      field(:git_metadata_writable, :boolean, default: false)

      # Names of environment variables to pass through to the agent's child process; values are read
      # from Symphony's own environment when the child is launched. Names only, so a credential never
      # has to be written into a project file. Empty by default, and a name that is also a declared
      # tracker secret is refused rather than honoured -- the two intents contradict each other.
      field(:child_env, {:array, :string}, default: [])

      # A GitHub App to mint the agent's push credential from, instead of a long-lived personal
      # access token handed over through `child_env` above. `app_id` and `private_key_path` are the
      # App's identity; the key is read from its file at every mint and never enters this process's
      # environment, and `installation_id` (or `account`) says which installation this project means
      # when the App is installed more than once.
      #
      # Absent -- `nil` -- by default, because it is a different *kind* of credential: a deployment
      # that is happy with the token it already passes through `child_env` must keep working
      # unchanged, and minting reaches the network, so nothing may do it until a workflow asks for
      # an App by name. See `Codex.AppServer.child_env/3` for where the token is minted and handed to
      # the child.
      field(:app_token, :map)
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:read_timeout_ms, :integer, default: 5_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :approval_policy,
          :thread_sandbox,
          :turn_sandbox_policy,
          :git_metadata_writable,
          :child_env,
          :app_token,
          :turn_timeout_ms,
          :read_timeout_ms,
          :stall_timeout_ms
        ],
        empty_values: []
      )
      |> validate_required([:command])
      |> validate_change(:command, fn :command, command ->
        if command != "" and String.trim(command) == "" do
          [command: "can't be blank"]
        else
          []
        end
      end)
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
      |> validate_change(:app_token, fn :app_token, app_token -> app_token_errors(app_token) end)
    end

    # Refused as a whole -- unknown key, missing half, wrong type -- rather than accepted and left to
    # fail at push time: this block describes a credential, and a `appid:` typo would otherwise mint
    # nothing and surface hours later as a git error that never mentions the setting.
    #
    # `validate_change/3` fires only for a value a file actually wrote, so an omitted `app_token` is
    # never looked at, and every workflow that does not name an App passes through exactly as before.
    defp app_token_errors(app_token) when is_map(app_token) do
      unknown_app_token_key_errors(app_token) ++
        Enum.flat_map(@app_token_keys, &app_token_key_errors(app_token, &1))
    end

    defp app_token_errors(app_token) do
      [app_token_error("must be a mapping, got " <> inspect(app_token))]
    end

    defp unknown_app_token_key_errors(app_token) do
      app_token
      |> Map.keys()
      |> Enum.reject(&(to_string(&1) in @app_token_keys))
      |> Enum.map(&app_token_error("unknown key " <> inspect(&1)))
    end

    defp app_token_key_errors(app_token, key) do
      value = Map.get(app_token, key)

      cond do
        is_nil(value) and key not in @app_token_required_keys -> []
        key in ["app_id", "installation_id"] and positive_id?(value) -> []
        key in ["private_key_path", "account"] and non_blank_string?(value) -> []
        true -> [app_token_error(app_token_key_message(key))]
      end
    end

    defp app_token_key_message("app_id"), do: "app_id must be a positive integer"
    defp app_token_key_message("installation_id"), do: "installation_id must be a positive integer"
    defp app_token_key_message("account"), do: "account must be a non-empty login"

    defp app_token_key_message("private_key_path") do
      "private_key_path must be a non-empty path to the App's PEM file"
    end

    defp app_token_error(message), do: {:app_token, message}

    defp positive_id?(value) when is_integer(value), do: value > 0

    defp positive_id?(value) when is_binary(value) do
      case Integer.parse(String.trim(value)) do
        {id, ""} -> id > 0
        _other -> false
      end
    end

    defp positive_id?(_value), do: false

    defp non_blank_string?(value) when is_binary(value), do: String.trim(value) != ""
    defp non_blank_string?(_value), do: false
  end

  defmodule Acp do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @adapters ["dsh", "workbuddy"]

    @primary_key false
    embedded_schema do
      field(:adapter, :string, default: "dsh")
      field(:command, {:array, :string}, default: [])
      field(:cli_path, :string)
      field(:model, :string)
      # Which auth method to present during the handshake, by the id the agent advertised
      # (`session/new` may be refused until the client authenticates; WorkBuddy does that when its
      # session has expired). `nil` -- the default -- keeps the previous behaviour exactly: offer
      # nothing, and let `session/new` complain if it cares.
      field(:authenticate, :string)
      # Interactive: the agent opens a browser and waits for a person. Measured at 8.5 minutes for
      # one WeChat login, so the SDK's 5-minute default is not enough.
      field(:authenticate_timeout_ms, :integer, default: 900_000)
      field(:init_timeout_ms, :integer, default: 60_000)
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      # Off by default: with this on the agent is handed Symphony's tracker tools (as an MCP server it
      # may call), which widens what it can do to the tracker. See `MCP.TrackerServer`.
      field(:tracker_tools, :boolean, default: false)
    end

    @doc false
    @spec adapters() :: [String.t()]
    def adapters, do: @adapters

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :adapter,
          :command,
          :cli_path,
          :model,
          :authenticate,
          :authenticate_timeout_ms,
          :init_timeout_ms,
          :turn_timeout_ms,
          :tracker_tools
        ],
        empty_values: []
      )
      |> validate_inclusion(:adapter, @adapters)
      |> validate_number(:authenticate_timeout_ms, greater_than: 0)
      |> validate_number(:init_timeout_ms, greater_than: 0)
      |> validate_number(:turn_timeout_ms, greater_than: 0)
    end
  end

  defmodule CommandCode do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      # Explicit argv. When empty, the backend builds `["command-code", ...]` (or
      # `["node", cli_path, ...]` when `cli_path` is set).
      field(:command, {:array, :string}, default: [])
      # The `command-code/dist/index.mjs` entry point — skips the npm shim layer.
      field(:cli_path, :string)
      field(:model, :string)
      field(:effort, :string)
      # Escape hatch appended verbatim before `-p <prompt>` (e.g. `["--max-turns", "50"]`).
      field(:extra_args, {:array, :string}, default: [])
      field(:turn_timeout_ms, :integer, default: 3_600_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:command, :cli_path, :model, :effort, :extra_args, :turn_timeout_ms], empty_values: [])
      |> validate_number(:turn_timeout_ms, greater_than: 0)
    end
  end

  defmodule Hooks do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:after_create, :string)
      field(:before_run, :string)
      field(:after_run, :string)
      field(:before_remove, :string)
      field(:timeout_ms, :integer, default: 60_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:after_create, :before_run, :after_run, :before_remove, :timeout_ms], empty_values: [])
      |> validate_number(:timeout_ms, greater_than: 0)
    end
  end

  # The gate a project declares for its own agent runs: one shell command and a deadline for it. It is
  # run **host-side** by `SymphonyElixir.GateTool`, because an agent's turn is sandboxed and on
  # this host `mix` cannot even start there -- `Mix.Sync.PubSub` stats the user profile directory and
  # that stat is refused for the sandbox account. A block rather than two loose fields, for the reason
  # `hooks` is one: the command and the deadline belong together.
  #
  # `command` is deliberately **not** required and not validated for blankness. "This project declares
  # no gate" has to stay a state the workflow can be in -- the tool is then simply not advertised
  # (`GateTool.tool_specs/0` answers `[]`), and an explicit call gets a failure that says so, rather
  # than a workflow that refuses to load over a setting nothing needs.
  defmodule Gate do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string)
      field(:timeout_ms, :integer, default: 900_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:command, :timeout_ms], empty_values: [])
      |> validate_number(:timeout_ms, greater_than: 0)
    end
  end

  # The deploy a project declares: one shell command, an optional working directory, and a deadline.
  # Run **host-side** by `SymphonyElixir.Deploy`, and only because a person pressed the button on
  # `/control` -- nothing schedules it, and nothing infers it.
  #
  # Shaped after `Gate` above, for the reason that block exists: the command and the deadline belong
  # together, and "this project declares no deploy" has to stay a state a workflow can be in. A project
  # that declares none simply has no deploy action; `command` is therefore neither required nor
  # validated for blankness, and a blank one means exactly what an absent one means.
  #
  # `working_directory` is the addition `gate` does not need. A gate runs in the calling ticket's
  # workspace, which the session already names; a deploy belongs to a *checkout* -- the project's own
  # directory on this host -- and the orchestrator's own directory is almost never it. It must be
  # **absolute**: a relative path would resolve against whatever directory the orchestrator happened to
  # be started in, a fact no line of the file states and no reader can see. Leaving it out is a
  # legitimate declaration and means "run where the orchestrator runs".
  defmodule Deploy do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @default_timeout_ms 1_800_000

    # Absolute on either host's shape: `/...` (POSIX), `C:\...` or `C:/...` (a drive), or `\\host\share`
    # (a Windows UNC path). Deliberately a textual rule rather than `Path.type/1`, which answers for the
    # host reading the file: a workflow written on one machine is read on the other here, and the value
    # is handed to a shell that understands both.
    @windows_absolute ~r/\A[A-Za-z]:[\\\/]/
    @unc_absolute ~r/\A[\\\/]{2}[^\\\/]/

    @primary_key false
    embedded_schema do
      field(:command, :string)
      field(:working_directory, :string)
      field(:timeout_ms, :integer, default: @default_timeout_ms)
    end

    @doc false
    @spec default_timeout_ms() :: pos_integer()
    def default_timeout_ms, do: @default_timeout_ms

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:command, :working_directory, :timeout_ms], empty_values: [])
      |> validate_number(:timeout_ms, greater_than: 0)
      |> validate_working_directory()
    end

    # `validate_change/3` fires only for a value a file actually wrote, so an omitted key and an
    # explicit `null` both pass through untouched -- which is what keeps "no directory declared" and
    # "a directory declared and wrong" different answers.
    defp validate_working_directory(changeset) do
      validate_change(changeset, :working_directory, fn :working_directory, directory ->
        directory_errors(directory)
      end)
    end

    defp directory_errors(directory) do
      cond do
        not is_binary(directory) ->
          [working_directory: "must be a path"]

        String.contains?(directory, <<0>>) ->
          [working_directory: "must not contain a NUL byte"]

        String.trim(directory) == "" ->
          [working_directory: blank_directory_message()]

        not absolute_directory?(directory) ->
          [working_directory: relative_directory_message(directory)]

        true ->
          []
      end
    end

    defp blank_directory_message do
      "must not be blank: drop the key entirely to run in the orchestrator's own directory"
    end

    defp relative_directory_message(directory) do
      "must be an absolute path, got " <>
        inspect(directory) <>
        " -- a relative one would be resolved against the orchestrator's own directory, which no line of the workflow states"
    end

    defp absolute_directory?(directory) do
      String.starts_with?(directory, "/") or
        Regex.match?(@windows_absolute, directory) or
        Regex.match?(@unc_absolute, directory)
    end
  end

  # The sweep that lands tickets unattended: the land button's own judgement, asked on a timer, and
  # only for the tickets an operator marked safe. A block rather than a few loose fields, for the
  # reason `gate` and `deploy` are: the switch, the word it looks for and the two bounds belong
  # together, and "this deployment does not sweep" has to stay a state a workflow can be in.
  #
  # Off by default, like every other addition in this fork: `SymphonyElixir.AutoLand` answers `:ignore`
  # from `init/1` unless `enabled` is true, so a workflow that says nothing about this block starts no
  # process, reads no ticket and runs no `gh`.
  #
  # `label` is the operator's per-ticket opt-in -- a ticket is landed unattended only when it carries
  # this label -- and it is a setting rather than a constant because it is a word the operator writes
  # on their own tickets. A blank one matches no ticket, which is a sweep that lands nothing.
  #
  # `timeout_ms` bounds **one attempt**: one whole `SymphonyElixir.Land.land/2` call, which is up to
  # six `gh` invocations, each of which already carries its own killable timeout and its own
  # rate-limit retries. The default is above that worst case, so this is a backstop for a `gh` that
  # never answers rather than a second timeout competing with the first.
  #
  # `max_per_pass` is how many tickets one pass may land. One by default: a merge cannot be undone,
  # and the steady state worth designing for is a queue that gains merges one at a time.
  defmodule AutoLand do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @default_label "auto-land"
    @default_interval_ms 60_000
    @default_timeout_ms 600_000
    @default_max_per_pass 1

    @primary_key false
    embedded_schema do
      field(:enabled, :boolean, default: false)
      field(:label, :string, default: @default_label)
      field(:interval_ms, :integer, default: @default_interval_ms)
      field(:timeout_ms, :integer, default: @default_timeout_ms)
      field(:max_per_pass, :integer, default: @default_max_per_pass)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:enabled, :label, :interval_ms, :timeout_ms, :max_per_pass], empty_values: [])
      |> validate_number(:interval_ms, greater_than: 0)
      |> validate_number(:timeout_ms, greater_than: 0)
      |> validate_number(:max_per_pass, greater_than: 0)
    end
  end

  defmodule Observability do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:dashboard_enabled, :boolean, default: true)
      field(:refresh_ms, :integer, default: 1_000)
      field(:render_interval_ms, :integer, default: 16)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:dashboard_enabled, :refresh_ms, :render_interval_ms], empty_values: [])
      |> validate_number(:refresh_ms, greater_than: 0)
      |> validate_number(:render_interval_ms, greater_than: 0)
    end
  end

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:port, :integer)
      field(:host, :string, default: "127.0.0.1")
      # Off by default: exposes POST /api/v1/tools/:tool, which runs the tracker's provider-native
      # tools with Symphony's credentials. See ObservabilityApiController.tool/2.
      field(:tracker_tools, :boolean, default: false)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:port, :host, :tracker_tools], empty_values: [])
      |> validate_number(:port, greater_than_or_equal_to: 0)
    end
  end

  defmodule Janitor do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      # Off by default, like every other addition in this fork: nothing starts unless a workflow
      # asks for it. See `SymphonyElixir.Janitor.Server` for what it does when it is on.
      field(:enabled, :boolean, default: false)
      field(:interval_ms, :integer, default: 30_000)
      field(:tickets_path, :string)
      field(:workspace_root, :string)
      # The repository the tickets live in, and the one the issues live in. They are different
      # repositories on purpose: tickets are data, issues are the human surface.
      field(:tickets_repo, :string)
      field(:issues_repo, :string)
      field(:state_file, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :enabled,
          :interval_ms,
          :tickets_path,
          :workspace_root,
          :tickets_repo,
          :issues_repo,
          :state_file
        ],
        empty_values: []
      )
      |> validate_number(:interval_ms, greater_than: 0)
    end
  end

  embedded_schema do
    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:project, Project, on_replace: :update, defaults_to_struct: true)
    embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
    embeds_one(:acp, Acp, on_replace: :update, defaults_to_struct: true)
    embeds_one(:commandcode, CommandCode, on_replace: :update, defaults_to_struct: true)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:gate, Gate, on_replace: :update, defaults_to_struct: true)
    embeds_one(:deploy, Deploy, on_replace: :update, defaults_to_struct: true)
    embeds_one(:auto_land, AutoLand, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
    embeds_one(:janitor, Janitor, on_replace: :update, defaults_to_struct: true)
  end

  @spec parse(map()) :: {:ok, %__MODULE__{}} | {:error, {:invalid_workflow_config, String.t()}}
  def parse(config) when is_map(config) do
    config
    |> normalize_keys()
    |> drop_nil_values()
    |> changeset()
    |> apply_action(:validate)
    |> case do
      {:ok, settings} ->
        {:ok, finalize_settings(settings)}

      {:error, changeset} ->
        {:error, {:invalid_workflow_config, format_errors(changeset)}}
    end
  end

  @spec resolve_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil) :: map()
  def resolve_turn_sandbox_policy(settings, workspace \\ nil) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        policy

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> expand_local_workspace_root()
        |> default_turn_sandbox_policy()
    end
  end

  @spec resolve_runtime_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_runtime_turn_sandbox_policy(settings, workspace \\ nil, opts \\ []) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        {:ok, policy}

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> default_runtime_turn_sandbox_policy(opts)
    end
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  @doc false
  @spec normalize_state_limits(nil | map()) :: map()
  def normalize_state_limits(nil), do: %{}

  def normalize_state_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {state_name, limit}, acc ->
      Map.put(acc, normalize_issue_state(to_string(state_name)), limit)
    end)
  end

  @doc false
  @spec validate_state_limits(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_state_limits(changeset, field) do
    validate_change(changeset, field, fn ^field, limits ->
      Enum.flat_map(limits, fn {state_name, limit} ->
        cond do
          state_name |> to_string() |> String.trim() == "" ->
            [{field, "state names must not be blank"}]

          not is_integer(limit) or limit <= 0 ->
            [{field, "limits must be positive integers"}]

          true ->
            []
        end
      end)
    end)
  end

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [])
    |> cast_embed(:tracker, with: &Tracker.changeset/2)
    |> cast_embed(:polling, with: &Polling.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:project, with: &Project.changeset/2)
    |> cast_embed(:worker, with: &Worker.changeset/2)
    |> cast_embed(:agent, with: &Agent.changeset/2)
    |> cast_embed(:codex, with: &Codex.changeset/2)
    |> cast_embed(:acp, with: &Acp.changeset/2)
    |> cast_embed(:commandcode, with: &CommandCode.changeset/2)
    |> cast_embed(:hooks, with: &Hooks.changeset/2)
    |> cast_embed(:gate, with: &Gate.changeset/2)
    |> cast_embed(:deploy, with: &Deploy.changeset/2)
    |> cast_embed(:auto_land, with: &AutoLand.changeset/2)
    |> cast_embed(:observability, with: &Observability.changeset/2)
    |> cast_embed(:server, with: &Server.changeset/2)
    |> cast_embed(:janitor, with: &Janitor.changeset/2)
    |> validate_shared_isolation()
  end

  # The one rule about *two* sections at once, so it cannot live in either section's own changeset:
  # `shared` means the project has one working tree, and `agent.max_concurrent_agents` is how many
  # runs may edit at the same time. More than one, and two agents overwrite each other's files
  # mid-edit -- a lost edit nobody sees, because both runs report success.
  #
  # Refused here rather than "documented in the workflow", because `max_concurrent_agents` defaults to
  # 10: a file that says `shared` and nothing else is exactly the dangerous case, and a workflow that
  # does not load is one a person finds out about immediately.
  #
  # Kept for whoever implements `shared`: until then nothing reaches it, because `shared` is already
  # refused as unimplemented in `Project.changeset/2`, and this rule is the one that has to hold the
  # moment it is honoured.
  defp validate_shared_isolation(changeset) do
    project = get_field(changeset, :project)
    agent = get_field(changeset, :agent)

    if project != nil and project.isolation == "shared" and agent != nil and agent.max_concurrent_agents > 1 do
      add_error(
        changeset,
        :project,
        "isolation: shared needs agent.max_concurrent_agents to be 1, got %{limit} -- " <>
          "a shared working tree is one checkout for the whole project, so two runs at once would overwrite each other's edits",
        limit: agent.max_concurrent_agents
      )
    else
      changeset
    end
  end

  defp finalize_settings(settings) do
    provider = normalize_optional_map(settings.tracker.provider) || %{}

    {api_key, assignee, provider, derived_environment_names} =
      case settings.tracker.kind do
        "linear" ->
          linear_provider =
            provider
            |> Map.put_new("endpoint", settings.tracker.endpoint || @linear_endpoint)
            |> Map.put_new("api_key", settings.tracker.api_key)
            |> Map.put_new("project_slug", settings.tracker.project_slug)
            |> Map.put_new("assignee", settings.tracker.assignee)

          resolved_api_key =
            resolve_secret_setting(linear_provider["api_key"], System.get_env("LINEAR_API_KEY"))

          resolved_assignee =
            resolve_secret_setting(linear_provider["assignee"], System.get_env("LINEAR_ASSIGNEE"))

          {
            resolved_api_key,
            resolved_assignee,
            linear_provider,
            ["LINEAR_API_KEY" | env_reference_names([linear_provider["api_key"]])]
          }

        _ ->
          {settings.tracker.api_key, settings.tracker.assignee, provider, []}
      end

    {active_states, terminal_states} =
      case settings.tracker.kind do
        kind when kind in ["linear", "memory"] ->
          {
            settings.tracker.active_states || @linear_active_states,
            settings.tracker.terminal_states || @linear_terminal_states
          }

        _ ->
          {settings.tracker.active_states, settings.tracker.terminal_states}
      end

    # Bound here rather than inline in the struct update: the merged list is the one expression in this
    # map too long for the line it belongs to, and a helper call keeps that line readable.
    secret_environment_names =
      merge_secret_environment_names(derived_environment_names, settings.tracker.secret_environment_names)

    tracker = %{
      settings.tracker
      | endpoint: Map.get(provider, "endpoint", settings.tracker.endpoint),
        api_key: api_key,
        project_slug: Map.get(provider, "project_slug", settings.tracker.project_slug),
        assignee: assignee,
        provider: provider,
        secret_environment_names: secret_environment_names,
        active_states: active_states,
        terminal_states: terminal_states
    }

    workspace = %{
      settings.workspace
      | root: resolve_path_value(settings.workspace.root, Path.join(System.tmp_dir!(), "symphony_workspaces"))
    }

    codex = %{
      settings.codex
      | approval_policy: normalize_keys(settings.codex.approval_policy),
        turn_sandbox_policy: normalize_optional_map(settings.codex.turn_sandbox_policy),
        app_token: normalize_optional_map(settings.codex.app_token)
    }

    %{settings | tracker: tracker, workspace: workspace, codex: codex}
  end

  # Two parties have something to say about which variables must be unset in an agent's child process:
  # the selected tracker adapter derives the names the credential it needs would arrive under
  # (`LINEAR_API_KEY` for a linear tracker), and the workflow may name further variables of its own.
  # The derived names are a safety property -- this tracker's credential must not reach a run with no
  # business holding it -- and the configured names are an addition to it, never a replacement, so the
  # field is their union. De-duplicated, because a name both parties mention is one variable, and
  # blank-free, because a blank entry is not a variable and would otherwise be handed to the child as
  # one. The unconfigured path is untouched: with nothing configured the union is the derived list.
  defp merge_secret_environment_names(derived, configured) do
    (derived ++ List.wrap(configured))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_optional_map(nil), do: nil
  defp normalize_optional_map(value) when is_map(value), do: normalize_keys(value)

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      case drop_nil_values(nested) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp resolve_secret_setting(nil, fallback), do: normalize_secret_value(fallback)

  defp resolve_secret_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  defp resolve_secret_setting(value, _fallback), do: value

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      "" ->
        default

      path ->
        path
    end
  end

  defp resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp normalize_path_token(value) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> value
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp env_reference_names(values) when is_list(values) do
    Enum.flat_map(values, fn value ->
      case env_reference_name(value) do
        {:ok, env_name} -> [env_name]
        :error -> []
      end
    end)
  end

  defp resolve_env_token(env_name) do
    case System.get_env(env_name) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_secret_value(_value), do: nil

  defp default_turn_sandbox_policy(workspace) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => [workspace],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, opts) when is_binary(workspace_root) do
    if Keyword.get(opts, :remote, false) do
      {:ok, default_turn_sandbox_policy(workspace_root)}
    else
      with expanded_workspace_root <- expand_local_workspace_root(workspace_root),
           {:ok, canonical_workspace_root} <- PathSafety.canonicalize(expanded_workspace_root) do
        {:ok, default_turn_sandbox_policy(canonical_workspace_root)}
      end
    end
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, _opts) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root}}}
  end

  defp default_workspace_root(workspace, _fallback) when is_binary(workspace) and workspace != "",
    do: workspace

  defp default_workspace_root(nil, fallback), do: fallback
  defp default_workspace_root("", fallback), do: fallback
  defp default_workspace_root(workspace, _fallback), do: workspace

  defp expand_local_workspace_root(workspace_root)
       when is_binary(workspace_root) and workspace_root != "" do
    Path.expand(workspace_root)
  end

  defp expand_local_workspace_root(_workspace_root) do
    Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))
  end

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix =
        case prefix do
          nil -> to_string(key)
          current -> current <> "." <> to_string(key)
        end

      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.map(errors, &(prefix <> " " <> &1))
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  defp error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp error_value_to_string(value), do: inspect(value)
end
