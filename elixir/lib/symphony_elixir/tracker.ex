defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and provider-native agent tools.

  The orchestrator only depends on the read callbacks. Agent-side mutations stay
  behind optional provider-native tools so tracker-specific capabilities do not
  leak into scheduler policy.

  ## The composed agent tool list

  This boundary composes the list a run is offered: whatever the configured adapter advertises,
  **then** the host's own tools. Every transport advertises through the one door,
  `bind_agent_tools/0` -- the Codex app-server as `dynamicTools`, the ACP path's stdio MCP server on
  `tools/list`, and the HTTP tool endpoint -- so a host tool is offered for **every** tracker kind,
  and an adapter can neither add nor remove it.

  Running the project's gate is a property of the project, not of where its tickets come from:
  composing it in the file tracker's adapter is what left a service-backed project with no tools at
  all, and its agent running the workflow's `gate.command` itself, inside its sandbox, where the
  project's own gate cannot even start.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Janitor.GateTool
  alias SymphonyElixir.Tracker.Issue

  @adapters %{
    "asana" => SymphonyElixir.Asana.Adapter,
    "file" => SymphonyElixir.Tracker.File,
    "github" => SymphonyElixir.GitHub.Adapter,
    "gitlab" => SymphonyElixir.GitLab.Adapter,
    "jira" => SymphonyElixir.Jira.Adapter,
    "linear" => SymphonyElixir.Linear.Adapter,
    "memory" => SymphonyElixir.Tracker.Memory,
    "ticket_service" => SymphonyElixir.Tracker.TicketService
  }

  @callback fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  @callback fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  @callback agent_tool_specs() :: [map()]
  @callback execute_agent_tool(String.t(), term(), keyword()) :: map()
  @callback secret_environment_names(map()) :: [String.t()]
  @callback validate_config(map()) :: :ok | {:error, term()}

  @optional_callbacks agent_tool_specs: 0,
                      execute_agent_tool: 3,
                      validate_config: 1

  # The host's own agent-facing tools, advertised beside whatever the adapter offers. Each answers
  # `tool_specs/0` (its spec, or `[]` when the project declares nothing to run), `handles?/1`
  # (whether a call names it) and is executed by its own `execute/3`. They live here rather than in
  # an adapter because not one of them is a tracker capability: the gate is run because the
  # **project** declares one.
  @host_tool_modules [GateTool]

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) do
    adapter().fetch_issues_by_ids(issue_ids)
  end

  @doc """
  Captures the selected adapter, its **composed** tool list and the effective tracker settings for
  one app-server session, so tool advertisement and execution cannot drift across a workflow reload.

  `tool_specs` is the list every transport advertises (`codex/dynamic_tool.ex`,
  `mcp/tracker_server.ex`, the HTTP tool endpoint): the adapter's own tools followed by the host's.
  """
  @spec bind_agent_tools() :: map()
  def bind_agent_tools do
    tracker_settings = Config.settings!().tracker
    adapter = adapter_for_settings!(tracker_settings)

    %{
      adapter: adapter,
      tracker_settings: tracker_settings,
      tool_specs: compose_agent_tool_specs(adapter),
      secret_environment_names: adapter_secret_environment_names(adapter, tracker_settings)
    }
  end

  @doc """
  The composed tool list for `adapter`: the adapter's own tools, then the host's.

  The adapter's list keeps its order and comes first, so composition only ever appends and every
  adapter's own list reads the same through this door as it does at the adapter. A host tool is
  advertised **beside** whatever the adapter offers, for every kind -- and `GateTool.tool_specs/0`
  answers `[]` for a project that declares no gate, so such a project is advertised exactly what its
  adapter offers and nothing extra.
  """
  @spec compose_agent_tool_specs(module()) :: [map()]
  def compose_agent_tool_specs(adapter) do
    adapter_agent_tool_specs(adapter) ++ host_agent_tool_specs()
  end

  @doc """
  Runs one bound call: a host tool here, everything else at the adapter.

  The routing rule is the one the advertisement rule already uses -- a tool is a host tool when its
  module says `handles?/1` -- and it is applied **before** the adapter is consulted, so no adapter's
  `execute_agent_tool/3` contract changes: an adapter still only ever sees the tools it advertises.

  A host tool is reached whether or not the project declared it, because the answer for a call that
  arrives anyway has to be the sentence saying nothing was declared, not "unsupported tool".
  """
  @spec execute_bound_agent_tool(map(), String.t(), term(), keyword()) :: map()
  def execute_bound_agent_tool(
        %{adapter: adapter, tracker_settings: tracker_settings},
        tool,
        arguments,
        opts \\ []
      ) do
    case host_tool_module(tool) do
      nil ->
        execute_agent_tool_with_adapter(
          adapter,
          tool,
          arguments,
          Keyword.put(opts, :tracker_settings, tracker_settings)
        )

      module ->
        module.execute(tool, arguments, opts)
    end
  end

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(%{kind: kind} = tracker_settings) do
    with {:ok, adapter} <- adapter_for_kind(kind) do
      if Code.ensure_loaded?(adapter) and function_exported?(adapter, :validate_config, 1) do
        adapter.validate_config(tracker_settings)
      else
        :ok
      end
    end
  end

  @spec adapter() :: module()
  def adapter do
    Config.settings!().tracker
    |> adapter_for_settings!()
  end

  @spec adapter_for_kind(String.t()) :: {:ok, module()} | {:error, term()}
  def adapter_for_kind(kind) do
    case Map.fetch(@adapters, kind) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> {:error, {:unsupported_tracker_kind, kind}}
    end
  end

  defp adapter_for_settings!(%{kind: kind}) do
    {:ok, adapter} = adapter_for_kind(kind)
    adapter
  end

  defp adapter_agent_tool_specs(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :agent_tool_specs, 0) do
      adapter.agent_tool_specs()
    else
      []
    end
  end

  defp host_agent_tool_specs do
    Enum.flat_map(@host_tool_modules, &host_agent_tool_specs_for/1)
  end

  defp host_agent_tool_specs_for(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :tool_specs, 0) do
      module.tool_specs()
    else
      []
    end
  end

  defp host_tool_module(tool) do
    Enum.find(@host_tool_modules, &host_tool?(&1, tool))
  end

  defp host_tool?(module, tool) do
    Code.ensure_loaded?(module) and function_exported?(module, :handles?, 1) and
      module.handles?(tool)
  end

  defp execute_agent_tool_with_adapter(adapter, tool, arguments, opts) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :execute_agent_tool, 3) do
      adapter.execute_agent_tool(tool, arguments, opts)
    else
      unsupported_agent_tool_response(tool)
    end
  end

  defp adapter_secret_environment_names(adapter, tracker_settings) do
    adapter.secret_environment_names(tracker_settings)
  end

  defp unsupported_agent_tool_response(tool) do
    output =
      Jason.encode!(%{
        "error" => %{
          "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
          "supportedTools" => []
        }
      })

    %{
      "success" => false,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end
end
