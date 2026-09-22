defmodule SymphonyElixir.ACP.AppServer do
  @moduledoc """
  ACP backend for Symphony — drives *other* coding agents (DSH, WorkBuddy) through the
  Agent Client Protocol instead of the Codex app-server JSON-RPC stream.

  This module is **shape-compatible** with `SymphonyElixir.Codex.AppServer`: same public
  surface (`run/4`, `start_session/2`, `run_turn/4`, `stop_session/1`), same message
  contract (`:session_started`, `:turn_ended_with_error`, `:startup_failed`, plus the
  metadata/details merge described in `emit_message/4`). That is deliberate — the
  orchestrator and `AgentRunner` must not care which backend is selected.

  The actual protocol work lives in the `AcpSdk` dependency (`AcpSdk.Client` /
  `AcpSdk.Runner` / `AcpSdk.Adapters.*`). This module only:

  - resolves the configured adapter and command,
  - reuses Symphony's own workspace safety check (`PathSafety` + `Config.local_workspace_root/0`)
    so an ACP turn cwd can never be the source repo,
  - translates ACP stream events into Symphony's `on_message` event shape,
  - reports `{:error, {:unsupported_worker_host, host}}` for remote hosts.

  ## Scope of this iteration

  Local only. `worker_host` must be `nil`; the Codex SSH path is untouched and this module
  never opens an SSH connection. MCP/tracker tool parity (Linear/Jira/GitHub tools for the
  ACP agent) is intentionally **not** implemented yet.

  ## Machine-verified adapter details (do not "simplify" these away)

  These were established by running the real CLIs; they are commented here because each one
  is a bug waiting to be reintroduced.

  - **DSH `session/new` only accepts `cwd` + `mcpServers`.** Extra keys (e.g. `model`) are
    rejected with `-32602 invalid params`. The SDK adapter already builds exactly that map.
  - **After the handshake you must switch models with
    `session/set_config_option("model", value)`** and the value must be one of the values DSH
    advertised in `session/new`'s `configOptions[].options[].value` (a **JSON string** such as
    `~s(["doubao-ark","glm-5-3-flash-260828"])`). A value that is not in the advertised list
    is rejected with `-32602`. `AcpSdk.start_client/1` applies `:config_options` during the
    handshake, which is why `acp.model` is passed there rather than sent per turn.
  - **Windows npm `.cmd` shims now work** because `AcpSdk.Subprocess` passes the `:hide` port
    option (without it the grandchild `node` process loses stdout and `initialize` hangs).
    Even so, calling the real node entry point directly is ~10x faster and more predictable:
      `DSH.default_command(bin_js: "C:/.../@deepseek-ai/dsh/lib/bin.js")`
  - **Cancellation:** `session/cancel` (used by the SDK runner on timeout) is reliable.
    The protocol-level `$/cancel_request` needs an in-flight request id and does **not** take
    effect on every turn, so it is not used here.
  - **WorkBuddy needs the CLI to have run `/login` first**, otherwise the turn finishes with
    `stopReason: "refusal"` (and `_meta["codebuddy.ai/errorMessage"]` = `-32000 Authentication
    required`). That is an environment condition, not a protocol error, so it is surfaced as a
    normal turn result rather than a crash.
  """

  require Logger

  alias AcpSdk.Adapters.{DSH, WorkBuddy}
  alias SymphonyElixir.{Config, PathSafety}

  @default_turn_timeout_ms 3_600_000
  @default_init_timeout_ms 60_000

  # ACP agents spell token counts differently (DSH uses snake_case; some use camelCase),
  # so accept every spelling we have seen before giving up.
  @input_token_keys ["input_tokens", "inputTokens", "prompt_tokens", "promptTokens", :input_tokens]
  @output_token_keys ["output_tokens", "outputTokens", "completion_tokens", "completionTokens", :output_tokens]
  @total_token_keys ["total_tokens", "totalTokens", :total_tokens]

  @typedoc "A live ACP session; `start_session/2` returns one of these."
  @type session :: %{
          client: pid(),
          workspace: Path.t(),
          metadata: map(),
          opts: keyword(),
          turn: pos_integer()
        }

  @doc """
  Run a single turn with a fresh session (start → turn → stop).

  Mirrors `SymphonyElixir.Codex.AppServer.run/4`.
  """
  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @doc """
  Start an ACP client, complete the ACP handshake, and return a session.

  `opts`:

  - `:worker_host` — must be `nil` (local only). Anything else returns
    `{:error, {:unsupported_worker_host, host}}`.
  - `:transport` — optional injected `AcpSdk.Transport` (used by tests to run against an
    in-process fake agent instead of a real subprocess).

  `session/new`'s `cwd` is the same path `SymphonyElixir.Codex.AppServer` would accept: the
  workspace expanded and canonicalized under `Config.local_workspace_root/0`.
  """
  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    case validate_workspace_cwd(workspace, worker_host) do
      {:ok, expanded_workspace} ->
        with {:ok, adapter} <- adapter_module(),
             {:ok, command} <- adapter_command(adapter),
             {:ok, client} <-
               start_client(adapter, command, expanded_workspace, Config.settings!().acp, opts) do
          session_id = acp_session_id(client)

          Logger.info("ACP session started adapter=#{inspect(adapter)} session_id=#{inspect(session_id)} workspace=#{expanded_workspace}")

          {:ok,
           %{
             client: client,
             workspace: expanded_workspace,
             metadata: %{adapter: adapter, acp_session_id: session_id, workspace: expanded_workspace},
             opts: opts,
             turn: 1
           }}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Run one prompt on an existing session and emit Symphony-shaped `on_message` events.

  Emitted events (all via `opts[:on_message]`):

  - `:session_started` with `session_id: "<acp-session-id>-<local-turn-id>"` — **required** by the
    orchestrator (`integrate_codex_update/2` + `turn_count_for_update/3`). The suffix is a fresh
    unique integer per call, see `turn_session_id/2`.
  - `:agent_message_chunk` / `:agent_thought_chunk` — streaming assistant text and reasoning.
  - `:tool_call` / `:plan` — ACP `tool_call`, `tool_call_update`, `plan` updates.
  - `:acp_event` / `:acp_raw_event` — tool calls, usage, rate limits and anything else the ACP
    agent sends that has no Symphony counterpart (the orchestrator silently ignores unknown
    events).
  - `:turn_ended_with_error` with `%{session_id: ..., reason: ...}` on turn failure.
  - `:startup_failed` with `%{reason: ...}` when the session cannot be started.
  """
  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(%{turn: turn, metadata: metadata} = session, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    turn_timeout_ms = turn_timeout_ms()
    session_id = turn_session_id(metadata, turn)

    Logger.info("ACP session started for #{issue_context(issue)} session_id=#{session_id}")

    emit_message(on_message, :session_started, %{session_id: session_id, turn: turn}, metadata)

    # Only `on_event` is used: `AcpSdk.Runner` fires it for **every** stream update before
    # aggregating, and `acp_event/2` already covers `agent_message_chunk` /
    # `agent_thought_chunk`. The SDK's `on_stream` callback is deliberately NOT wired up —
    # it hands over the *accumulated* text so far, which would give `:agent_message_chunk`
    # two different meanings (per-chunk here, running total there).
    run_opts = [
      timeout: turn_timeout_ms,
      on_event: fn event -> emit_acp_event(on_message, event, metadata) end
    ]

    case AcpSdk.run(session.client, prompt, run_opts) do
      {:ok, result} ->
        Logger.info("ACP session completed for #{issue_context(issue)} session_id=#{session_id}")

        emit_usage(on_message, result, metadata)

        {:ok,
         %{
           session_id: session_id,
           result: result,
           acp_session_id: Map.get(metadata, :acp_session_id),
           stop_reason: Map.get(result, :stop_reason)
         }}

      {:error, reason} ->
        Logger.warning("ACP session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

        emit_message(on_message, :turn_ended_with_error, %{session_id: session_id, reason: reason}, metadata)
        {:error, reason}
    end
  end

  @doc """
  Stop the ACP client and close the agent subprocess (best effort, idempotent).
  """
  @spec stop_session(session()) :: :ok
  def stop_session(%{client: client}) do
    case AcpSdk.stop_client(client) do
      :ok ->
        :ok

      other ->
        # Already-stopped / already-crashed clients are a cleanup path, not a failure:
        # the SDK treats "peer is gone" as a successful close, and this must stay `:ok`
        # so `AgentRunner`'s `after` block cannot turn teardown into a crash.
        Logger.debug("ACP session stop returned #{inspect(other)}")
        :ok
    end
  catch
    :exit, reason ->
      Logger.debug("ACP session stop exited: #{inspect(reason)}")
      :ok
  end

  # ───────────────── 事件映射（纯函数，便于单测） ─────────────────

  @doc """
  Map one raw ACP stream event onto a Symphony `on_message` event.

  Text/reasoning chunks, tool calls, plans and usage come straight from `session/update`
  notifications; anything else is reported as `:acp_event` / `:acp_raw_event`, which the
  orchestrator silently ignores.
  """
  @spec acp_event(map(), map()) :: {atom(), map()}
  def acp_event(%{"method" => "session/update", "params" => %{"update" => update}}, metadata)
      when is_map(update) do
    session_id = Map.get(metadata, :acp_session_id)

    case Map.get(update, "sessionUpdate") do
      "agent_message_chunk" ->
        {:agent_message_chunk, %{session_id: session_id, text: content_text(update["content"])}}

      "agent_thought_chunk" ->
        {:agent_thought_chunk, %{session_id: session_id, text: content_text(update["content"])}}

      "tool_call" ->
        {:tool_call,
         %{
           session_id: session_id,
           tool_call: update,
           tool_call_id: update["toolCallId"],
           title: update["title"],
           status: update["status"]
         }}

      "plan" ->
        {:plan, %{session_id: session_id, entries: Map.get(update, "entries", [])}}

      "usage_update" ->
        {:acp_usage_update, %{session_id: session_id, used: update["used"], size: update["size"]}}

      other ->
        {:acp_event, %{session_id: session_id, session_update: other, update: update}}
    end
  end

  def acp_event(event, metadata) do
    {:acp_raw_event, %{session_id: Map.get(metadata, :acp_session_id), event: event}}
  end

  # The orchestrator only accepts token maps whose values are integers (`integer_token_map?/1`)
  # and reads `input_tokens` / `output_tokens` / `total_tokens`. ACP's `usage_update` only
  # carries a context-window `used`/`size` pair, so it is reported under a distinct shape and
  # never claimed to be a token total.
  @doc """
  Normalize an ACP usage map into the shape the orchestrator can read.

  Returns `nil` when the payload carries nothing the orchestrator understands, so no
  `:token_usage` event is emitted at all.
  """
  @spec token_usage(map()) :: map() | nil
  def token_usage(%{} = usage) do
    input = int_value(usage, @input_token_keys)
    output = int_value(usage, @output_token_keys)
    total = int_value(usage, @total_token_keys)

    if present_token_count?(input, output, total) do
      %{
        "input_tokens" => input || 0,
        "output_tokens" => output || 0,
        "total_tokens" => total || (input || 0) + (output || 0)
      }
    end
  end

  def token_usage(_usage), do: nil

  defp present_token_count?(input, output, total),
    do: is_integer(input) or is_integer(output) or is_integer(total)

  # ───────────────── 配置解析 ─────────────────

  defp adapter_module do
    adapter_module(Config.settings!().acp.adapter)
  end

  defp adapter_module(adapter) when adapter in ["dsh", :dsh], do: {:ok, DSH}
  defp adapter_module(adapter) when adapter in ["workbuddy", :workbuddy], do: {:ok, WorkBuddy}

  defp adapter_module(adapter),
    do: {:error, {:unsupported_acp_adapter, adapter}}

  defp adapter_command(adapter) do
    acp = Config.settings!().acp
    command = configured_command(acp.command)
    per_adapter_command(adapter, command, acp.cli_path)
  end

  defp per_adapter_command(DSH, command, cli_path) do
    case {command, cli_path} do
      {[_ | _] = command, _} -> {:ok, command}
      {_, cli} when is_binary(cli) and cli != "" -> {:ok, DSH.default_command(bin_js: cli)}
      _ -> {:ok, DSH.default_command()}
    end
  end

  defp per_adapter_command(WorkBuddy, command, cli_path) do
    case {command, cli_path} do
      {[_ | _] = command, _} ->
        {:ok, command}

      {_, cli} when is_binary(cli) and cli != "" ->
        {:ok, WorkBuddy.default_command(cli_path: cli)}

      _ ->
        {:error, {:missing_acp_cli_path, :workbuddy}}
    end
  end

  defp configured_command(command) when is_list(command) do
    command
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  defp configured_command(_command), do: []

  # The agent gets Symphony's tracker tools as an MCP server. Measured: DSH launches the MCP server
  # itself (`%{"command" => ...}`) rather than connecting back through the ACP tunnel, so the
  # declaration is a command line. Off unless `acp.tracker_tools: true`: it widens what an agent may
  # do to the tracker, so it is not a default.
  defp acp_mcp_servers(%{tracker_tools: true}), do: [tracker_tools_server()]
  defp acp_mcp_servers(_acp), do: []

  # The MCP server is a separate process and inherits nothing, so the declaration has to name what it
  # needs. Without the token the workflow fails to validate and the server advertises **zero tools**,
  # which reads on the agent side as "no such server" -- measured, and the failure mode that cost a
  # session. PATH is needed for the escript itself on Windows.
  defp tracker_tools_env do
    secret_names = tracker_secret_env_names()

    ["PATH", "SystemRoot" | secret_names]
    |> Enum.uniq()
    |> Enum.flat_map(fn name ->
      case System.get_env(name) do
        nil -> []
        value -> [%{"name" => name, "value" => value}]
      end
    end)
  end

  defp tracker_secret_env_names do
    Map.get(SymphonyElixir.Tracker.bind_agent_tools(), :secret_environment_names, [])
  rescue
    _error -> []
  end

  defp tracker_tools_server do
    escript = Path.expand("bin/symphony")

    unless File.regular?(escript) do
      Logger.warning(
        "acp.tracker_tools is on but #{escript} does not exist; build it with `mix escript.build` " <>
          "or the agent will not see any tracker tools"
      )
    end

    %{
      "command" => escript,
      "args" => ["--mcp", Path.expand(SymphonyElixir.Workflow.workflow_file_path())],
      "env" => tracker_tools_env()
    }
  end

  # ───────────────── 启动 ─────────────────

  defp start_client(adapter, command, workspace, acp, opts) do
    client_opts =
      [
        adapter: adapter,
        command: command,
        cwd: workspace,
        init_timeout: init_timeout_ms(acp),
        config_options: acp_config_options(acp),
        mcp_servers: acp_mcp_servers(acp)
      ]
      |> put_transport(Keyword.get(opts, :transport))

    case AcpSdk.start_client(client_opts) do
      {:ok, client} -> {:ok, client}
      {:error, reason} -> {:error, {:acp_start_failed, reason}}
    end
  end

  defp put_transport(client_opts, nil), do: client_opts
  defp put_transport(client_opts, transport), do: Keyword.put(client_opts, :transport, transport)

  defp acp_config_options(%{model: model}) when is_binary(model) and model != "",
    do: [{"model", model}]

  defp acp_config_options(_acp), do: []

  # ACP has **no per-turn id on the wire**: `sessionId` is fixed for the whole session (DSH /
  # WorkBuddy both behave this way), and the only thing that differs between turns is the
  # JSON-RPC id of the `session/prompt` request — which is minted inside `AcpSdk.run/3` and is
  # therefore not available before `:session_started` must be emitted.
  #
  # But `AgentRunner.do_run_codex_turns/7` reuses one `app_session` for up to `agent.max_turns`
  # turns, and the orchestrator's `turn_count_for_update/3` only increments when a
  # `:session_started` arrives with a session_id **different from the one it already recorded**.
  # Codex satisfies that because every `turn/start` yields a new `turn_id`. So this backend must
  # mint its own per-turn unique suffix; using the session's monotonic `turn` field would pin the
  # orchestrator's `turn_count` at 1 for the whole run.
  defp turn_session_id(metadata, turn) do
    acp_session_id = Map.get(metadata, :acp_session_id) || "acp-session"
    "#{acp_session_id}-#{System.unique_integer([:positive])}-#{turn}"
  end

  defp acp_session_id(client) do
    case AcpSdk.session_meta(client) do
      %{session_id: session_id} when is_binary(session_id) -> session_id
      other -> other
    end
  end

  defp init_timeout_ms(%{init_timeout_ms: timeout}) when is_integer(timeout) and timeout > 0, do: timeout
  defp init_timeout_ms(_acp), do: @default_init_timeout_ms

  defp turn_timeout_ms do
    case Config.settings!().acp.turn_timeout_ms do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> @default_turn_timeout_ms
    end
  end

  # ───────────────── workspace 安全（与 Codex 同一套规则） ─────────────────

  # Symphony's only write path for an agent turn cwd is `Codex.AppServer.validate_workspace_cwd/2`,
  # and that function is private (it may not be refactored). Rather than invent a second policy,
  # the same rules are applied here in the same order. The invariants under test are:
  # `.` and `..` resolve before the prefix check, a symlinked child that escapes the root is
  # reported as `:symlink_escape`, and the workspace root itself is never a valid turn cwd.
  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Config.local_workspace_root()
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(_workspace, worker_host) when is_binary(worker_host) do
    {:error, {:unsupported_worker_host, worker_host}}
  end

  defp validate_workspace_cwd(workspace, _worker_host),
    do: {:error, {:invalid_workspace_cwd, :invalid_workspace, workspace}}

  # ───────────────── 事件映射 ─────────────────

  defp emit_usage(on_message, %{usage: %{} = usage}, metadata) do
    case token_usage(usage) do
      nil -> :ok
      token_usage -> emit_message(on_message, :token_usage, %{usage: token_usage}, metadata)
    end
  end

  defp emit_usage(_on_message, _result, _metadata), do: :ok

  defp int_value(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_integer(value) -> value
        _ -> nil
      end
    end)
  end

  defp content_text(%{"text" => text}) when is_binary(text), do: text
  defp content_text(_content), do: ""

  defp emit_acp_event(on_message, event, metadata) do
    {name, details} = acp_event(event, metadata)
    emit_message(on_message, name, details, metadata)
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp default_on_message(_message), do: :ok

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp issue_context(_issue), do: "issue_id=unknown issue_identifier=unknown"
end
