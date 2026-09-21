defmodule SymphonyElixir.CommandCode.AppServer do
  @moduledoc """
  CommandCode backend for Symphony — drives the `command-code` CLI (`cmd`) headlessly, so
  CommandCode models run on **CommandCode's own harness** instead of being routed through
  another agent's (DSH/ACP) harness.

  This module is **shape-compatible** with `SymphonyElixir.Codex.AppServer` and
  `SymphonyElixir.ACP.AppServer`: same public surface (`run/4`, `start_session/2`,
  `run_turn/4`, `stop_session/1`), same message contract (`:session_started`,
  `:turn_ended_with_error`, plus the `metadata |> Map.merge(details)` event shape used by
  `emit_message/4`). The orchestrator and `AgentRunner` must not care which backend is
  selected.

  ## Why a separate backend (cost)

  Routing CommandCode models through DSH works, but DSH re-sends its own system prompt and
  tool schemas on **every** model request — including every single tool call — and all of that
  bills against CommandCode credits. `cmd -p` runs the entire agent loop inside CommandCode's
  own harness, whose prompt is tuned per model. Measured on this machine (2026-09-21) with
  `--output-format json`:

  | run | model requests | input tokens | of which cache reads |
  |---|---|---|---|
  | one-line prompt | 1 | 16,547 | 5,248 |
  | create file + read it back | 3 | 50,085 | 40,704 |

  ## Shape: one process per turn, no long-lived child

  Unlike ACP there is nothing to handshake and no client to keep alive: `cmd -p` is a single
  process that runs the whole agent loop (tool calls included) and exits. `start_session/2`
  therefore does **no I/O** — it validates the workspace and opens a tiny state cell (an
  `Agent`) holding the CommandCode session id, which later turns resume with `--session <id>`.
  That id is not known until the first turn's `run_start` event arrives, which is why it
  cannot live in the (immutable) session map that `AgentRunner` reuses across turns.

  ## Machine-verified CLI details (do not "simplify" these away)

  Every item below was observed by running the real CLI; each one is a bug waiting to be
  reintroduced.

  - `cmd -p <prompt> --output-format json` prints **newline-delimited JSON**, one object per
    line, then exits. Two line kinds: `{"type":"event","event":{...}}` for the stream and a
    final `{"type":"result", ...}`. Output is merged with stderr, so **non-JSON lines must be
    skipped, not treated as protocol errors** — they are the CLI's own diagnostics and are
    kept (bounded) for the failure message.
  - Stream events seen on a tool-using run: `run_start`, `turn_start`, `message_start`,
    `model_request_start`, `model_trace`, `thinking_start` / `thinking_delta` / `thinking_end`,
    `text_delta`, `message_update`, `message_end`, `tool_queued` / `tool_running` /
    `tool_completed`, `model_request_end`, `turn_end`, `run_end`.
  - **`message_update` / `message_end` carry *cumulative* content, not deltas.** They are
    reported as `:commandcode_event` and never as `:agent_message_chunk`; only `text_delta`
    (and `thinking_delta`) are chunks. Emitting both would give `:agent_message_chunk` two
    different meanings — the same trap documented in the ACP backend.
  - `tool_queued` carries `{toolCallId, toolName, input}`, `tool_running` carries
    `{toolCallId, toolName, description}`, `tool_completed` carries
    `{toolCallId, toolName, result: [{"type":"text","text":...}], deferred}`. All three map to
    `:tool_call` with the **same** `tool_call_id`, so a consumer can follow one call across
    queued → running → completed.
  - Success is `stopReason: "end_turn"`; a per-request `stopReason: "tool_calls"` means the
    model asked for tools (normal, not an error). Token counts live in
    `usage.{inputTokens,outputTokens,cacheReadTokens,cacheWriteTokens}` (camelCase).
  - `--max-turns` exits **8** when the cap is hit (from `--help`).
  - `--yolo` is required for unattended runs — the analogue of codex's
    `approval_policy: never`.
  - Continuation across turns is `--session <sessionId>` using the id from `run_start`.
  """

  require Logger

  alias AcpSdk.Subprocess
  alias SymphonyElixir.{Config, PathSafety}

  @default_turn_timeout_ms 3_600_000

  # Flags that make the CLI behave like an unattended oracle: no permission prompts, no
  # background self-update (which would swap the binary mid-run), no first-run onboarding,
  # and a machine-readable stream.
  @default_cli_args ["--yolo", "--no-auto-update", "--skip-onboarding", "--output-format", "json"]

  # How much non-JSON CLI chatter to keep for a failure message.
  @diagnostic_limit 40

  # Base id used for the first turn's Symphony session id, before the CLI has told us its own.
  @session_id_base "commandcode"

  @typedoc "A live CommandCode session; `start_session/2` returns one of these."
  @type session :: %{
          workspace: Path.t(),
          holder: pid(),
          metadata: map(),
          opts: keyword(),
          turn: pos_integer()
        }

  @typedoc """
  Per-turn accumulator threaded through the line handler.

  `:session_id` is the id the CLI reported this turn; `:resume_id` is the one we asked it to
  resume. They differ on the first turn of a session.
  """
  @type turn_state :: %{
          turn: pos_integer(),
          turn_session_id: String.t(),
          resume_id: String.t() | nil,
          session_id: String.t() | nil,
          started?: boolean(),
          usage: map() | nil,
          stop_reason: String.t() | nil,
          subtype: String.t() | nil,
          result: map() | nil,
          diagnostics: [String.t()]
        }

  @typedoc "Injected by tests in place of the real subprocess (`:stream` opt)."
  @type stream_handle :: (turn_state(), String.t() -> turn_state())
  @type stream_result :: {:ok, turn_state(), integer()} | {:error, term()}

  @type stream_fun ::
          ([String.t()], Path.t(), pos_integer(), turn_state(), stream_handle() -> stream_result())

  @doc """
  Run a single turn with a fresh session (start → turn → stop).

  Mirrors `SymphonyElixir.ACP.AppServer.run/4`.
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
  Prepare a session: validate the workspace and open the state cell.

  `opts`:

  - `:worker_host` — must be `nil` (local only). Anything else returns
    `{:error, {:unsupported_worker_host, host}}`.

  No process is started here; the CLI is spawned per turn in `run_turn/4`.
  """
  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, holder} <- Agent.start_link(fn -> %{commandcode_session_id: nil} end) do
      Logger.info("CommandCode session prepared workspace=#{expanded_workspace}")

      {:ok,
       %{
         workspace: expanded_workspace,
         holder: holder,
         metadata: %{workspace: expanded_workspace},
         opts: opts,
         turn: 1
       }}
    end
  end

  @doc """
  Run one prompt and emit Symphony-shaped `on_message` events.

  Emitted events:

  - `:session_started` with `session_id: "<base>-<unique>-<turn>"` — **required** by the
    orchestrator (`turn_count_for_update/3` only counts a turn when the id differs from the one
    it already recorded, so the suffix must be unique per call). It is emitted **before** the
    CLI is spawned, exactly like the ACP backend, and the same string is returned in the result
    map so the two can never disagree.
  - `:agent_message_chunk` / `:agent_thought_chunk` — assistant text and reasoning, **true
    deltas**.
  - `:tool_call` — `tool_queued` / `tool_running` / `tool_completed`, sharing one
    `tool_call_id`.
  - `:token_usage` — normalized counters for the whole turn.
  - `:commandcode_event` — every other stream event (including the cumulative
    `message_update` / `message_end`), which the orchestrator silently ignores.
  - `:turn_ended_with_error` with `%{session_id: ..., reason: ...}` on turn failure.

  `opts`:

  - `:on_message` — 1-arity event sink.
  - `:stream` — injectable replacement for `stream_port/5` (tests only).
  """
  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(%{turn: turn, metadata: metadata, holder: holder} = session, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    cc = Config.settings!().commandcode
    resume_id = Agent.get(holder, & &1.commandcode_session_id)
    turn_session_id = turn_session_id(resume_id, turn)

    Logger.info(
      "CommandCode turn starting for #{issue_context(issue)} session_id=#{turn_session_id} " <>
        "workspace=#{session.workspace} resume=#{inspect(resume_id)}"
    )

    emit_message(on_message, :session_started, %{session_id: turn_session_id, turn: turn}, metadata)

    case build_command(prompt, resume_id, cc) do
      {:ok, command} ->
        initial = %{
          turn: turn,
          turn_session_id: turn_session_id,
          resume_id: resume_id,
          session_id: nil,
          started?: false,
          usage: nil,
          stop_reason: nil,
          subtype: nil,
          result: nil,
          diagnostics: []
        }

        stream = Keyword.get(opts, :stream, &stream_port/5)
        handle = fn state, line -> handle_line(state, line, on_message, metadata) end

        case stream.(command, session.workspace, turn_timeout_ms(), initial, handle) do
          {:ok, state, exit_code} ->
            finish_turn(session, state, exit_code, on_message, metadata, issue)

          {:error, reason} ->
            emit_turn_error(on_message, metadata, turn_session_id, reason, issue)
            {:error, reason}
        end

      {:error, reason} ->
        emit_turn_error(on_message, metadata, turn_session_id, reason, issue)
        {:error, reason}
    end
  end

  @doc """
  Release the state cell (best effort, idempotent).

  There is no child process to stop — `run_turn/4` owns the CLI process for its whole lifetime
  and kills the tree on timeout — so this only stops the holder. It must never raise:
  `AgentRunner` calls it from an `after` block, where a crash would mask the real result.
  """
  @spec stop_session(session()) :: :ok
  def stop_session(%{holder: holder}) do
    if is_pid(holder) and Process.alive?(holder), do: Agent.stop(holder)
    :ok
  catch
    :exit, reason ->
      Logger.debug("CommandCode session stop exited: #{inspect(reason)}")
      :ok
  end

  def stop_session(_session), do: :ok

  # ───────────────── 命令行 ─────────────────

  @doc """
  Build the full argv for one turn.

  Exposed (with `default_command/1`) so the argv contract is unit-testable without spawning
  anything.
  """
  @spec build_command(String.t(), String.t() | nil, map()) :: {:ok, [String.t()]} | {:error, term()}
  def build_command(prompt, resume_id, cc) when is_binary(prompt) do
    case configured_command(cc) do
      [] ->
        {:error, :missing_commandcode_command}

      base ->
        args =
          @default_cli_args ++
            optional_args(cc, :model, "-m") ++
            optional_args(cc, :effort, "--effort") ++
            resume_args(resume_id) ++
            extra_args(cc) ++
            ["-p", prompt]

        {:ok, base ++ args}
    end
  end

  @doc """
  The default argv head: the real node entry point when known, else the npm shim.

  `cli_path` is the `command-code/dist/index.mjs` entry point. Calling node directly skips the
  npm `.cmd`/`.ps1` shim layer; the shim works too now that ports pass `:hide`
  (`AcpSdk.Subprocess`), so both are supported.
  """
  @spec default_command(keyword()) :: [String.t()]
  def default_command(opts \\ []) do
    case Keyword.get(opts, :cli_path) do
      path when is_binary(path) and path != "" -> ["node", path]
      _ -> ["command-code"]
    end
  end

  defp configured_command(cc) do
    case Map.get(cc, :command) do
      [_ | _] = command -> Enum.map(command, &to_string/1)
      _ -> default_command(cli_path: Map.get(cc, :cli_path))
    end
  end

  defp optional_args(cc, key, flag) do
    case Map.get(cc, key) do
      value when is_binary(value) and value != "" -> [flag, value]
      _ -> []
    end
  end

  # Continuation is a fresh `cmd` process told to resume the transcript by id. Without it the
  # continuation turns `AgentRunner` issues would start from an empty context.
  defp resume_args(resume_id) when is_binary(resume_id) and resume_id != "",
    do: ["--session", resume_id]

  defp resume_args(_resume_id), do: []

  defp extra_args(cc) do
    case Map.get(cc, :extra_args) do
      [_ | _] = args -> Enum.map(args, &to_string/1)
      _ -> []
    end
  end

  # ───────────────── 事件映射（纯函数，便于单测） ─────────────────

  @doc """
  Map one decoded CommandCode stream event onto a Symphony `on_message` event.

  Text/thinking deltas and the three tool lifecycle events become first-class events;
  everything else — including the cumulative `message_update` / `message_end` — is reported as
  `:commandcode_event`, which the orchestrator ignores.
  """
  @spec cc_event(map(), map()) :: {atom(), map()}
  def cc_event(%{"type" => "text_delta"} = event, metadata) do
    {:agent_message_chunk, %{session_id: session_id(metadata), text: to_string(event["delta"] || "")}}
  end

  def cc_event(%{"type" => "thinking_delta"} = event, metadata) do
    {:agent_thought_chunk, %{session_id: session_id(metadata), text: to_string(event["delta"] || "")}}
  end

  def cc_event(%{"type" => "tool_queued"} = event, metadata) do
    {:tool_call,
     %{
       session_id: session_id(metadata),
       tool_call_id: event["toolCallId"],
       title: event["toolName"],
       status: "queued",
       tool_call: event,
       input: event["input"]
     }}
  end

  def cc_event(%{"type" => "tool_running"} = event, metadata) do
    {:tool_call,
     %{
       session_id: session_id(metadata),
       tool_call_id: event["toolCallId"],
       title: event["toolName"],
       status: "running",
       tool_call: event,
       description: event["description"]
     }}
  end

  def cc_event(%{"type" => "tool_completed"} = event, metadata) do
    {:tool_call,
     %{
       session_id: session_id(metadata),
       tool_call_id: event["toolCallId"],
       title: event["toolName"],
       status: "completed",
       tool_call: event,
       output: tool_result_text(event["result"])
     }}
  end

  def cc_event(event, metadata) do
    {:commandcode_event, %{session_id: session_id(metadata), commandcode_event: event}}
  end

  defp tool_result_text(result) when is_list(result) do
    result
    |> Enum.map_join("\n", fn
      %{"text" => text} when is_binary(text) -> text
      other -> inspect(other)
    end)
  end

  defp tool_result_text(_result), do: ""

  @doc """
  Normalize CommandCode's camelCase usage map into what the orchestrator reads.

  The orchestrator's `integer_token_map?/1` accepts any of a wide set of field names and
  `get_token_usage/2` reads `input_tokens` / `output_tokens` / `total_tokens`, so the canonical
  snake_case keys are emitted; the cache counters ride along because they are integers too and
  they are the whole point of choosing this backend. Returns `nil` when the payload carries no
  counters at all, so no `:token_usage` event is emitted.
  """
  @spec token_usage(map()) :: map() | nil
  def token_usage(%{} = usage) do
    input = int_value(usage, ["inputTokens", "input_tokens", "prompt_tokens"])
    output = int_value(usage, ["outputTokens", "output_tokens", "completion_tokens"])

    if is_integer(input) or is_integer(output) do
      %{
        "input_tokens" => input || 0,
        "output_tokens" => output || 0,
        "total_tokens" => (input || 0) + (output || 0),
        "cache_read_tokens" => int_value(usage, ["cacheReadTokens", "cache_read_tokens"]) || 0,
        "cache_write_tokens" => int_value(usage, ["cacheWriteTokens", "cache_write_tokens"]) || 0
      }
    end
  end

  def token_usage(_usage), do: nil

  # ───────────────── 行处理 ─────────────────

  # One line of the CLI's merged stdout/stderr. JSON lines drive the state machine; anything
  # else is CLI chatter and is kept (bounded) for diagnostics instead of failing the turn.
  defp handle_line(state, line, on_message, metadata) do
    case Jason.decode(line) do
      {:ok, %{"type" => "event", "event" => event}} when is_map(event) ->
        handle_event(state, event, on_message, metadata)

      {:ok, %{"type" => "result"} = result} ->
        %{
          state
          | subtype: result["subtype"],
            stop_reason: result["stopReason"] || state.stop_reason,
            usage: result["usage"] || state.usage,
            result: result
        }

      {:ok, _other} ->
        state

      {:error, _reason} ->
        if String.trim(line) == "" do
          state
        else
          %{state | diagnostics: bounded_diagnostics(state.diagnostics, line)}
        end
    end
  end

  # The CLI's own session id is only needed for the *next* turn's `--session`; the id Symphony
  # reports was already minted (and emitted) in `run_turn/4`.
  defp handle_event(state, %{"type" => "run_start"} = event, _on_message, _metadata) do
    %{state | session_id: event["sessionId"] || state.session_id, started?: true}
  end

  # Usage is accumulated per model request and reported once at the end as a single turn total.
  # `model_request_end` also carries the per-request stopReason, which is informational
  # (`tool_calls` is normal, not a failure).
  defp handle_event(state, %{"type" => "model_request_end"} = event, on_message, metadata) do
    emit_cc_event(on_message, event, metadata)
    %{state | usage: event["usage"] || state.usage}
  end

  defp handle_event(state, %{"type" => "run_end"} = event, on_message, metadata) do
    result = event["result"] || %{}
    emit_cc_event(on_message, event, metadata)

    %{
      state
      | usage: result["usage"] || state.usage,
        stop_reason: result["stopReason"] || state.stop_reason,
        result: result
    }
  end

  defp handle_event(state, event, on_message, metadata) do
    emit_cc_event(on_message, event, metadata)
    state
  end

  defp emit_cc_event(on_message, event, metadata) do
    {name, details} = cc_event(event, metadata)
    emit_message(on_message, name, details, metadata)
  end

  defp finish_turn(session, state, exit_code, on_message, metadata, issue) do
    persist_session_id(session.holder, state.session_id)
    emit_usage(on_message, state.usage, metadata)

    cond do
      not state.started? ->
        reason = {:commandcode_start_failed, exit_code, diagnostics_tail(state)}
        emit_turn_error(on_message, metadata, state.turn_session_id, reason, issue)
        {:error, reason}

      exit_code != 0 and is_nil(state.result) ->
        reason = {:commandcode_exit_status, exit_code, diagnostics_tail(state)}
        emit_turn_error(on_message, metadata, state.turn_session_id, reason, issue)
        {:error, reason}

      true ->
        Logger.info(
          "CommandCode turn completed for #{issue_context(issue)} session_id=#{state.turn_session_id} " <>
            "stop_reason=#{inspect(state.stop_reason)} exit=#{exit_code}"
        )

        {:ok,
         %{
           session_id: state.turn_session_id,
           commandcode_session_id: state.session_id,
           stop_reason: state.stop_reason,
           usage: token_usage(state.usage),
           exit_code: exit_code,
           result: state.result
         }}
    end
  end

  defp emit_turn_error(on_message, metadata, turn_session_id, reason, issue) do
    Logger.warning("CommandCode turn failed for #{issue_context(issue)}: #{inspect(reason)}")

    emit_message(
      on_message,
      :turn_ended_with_error,
      %{session_id: turn_session_id, reason: reason},
      metadata
    )
  end

  defp persist_session_id(holder, session_id) when is_binary(session_id) and session_id != "" do
    if is_pid(holder) and Process.alive?(holder) do
      Agent.update(holder, &%{&1 | commandcode_session_id: session_id})
    end
  catch
    :exit, _reason -> :ok
  end

  defp persist_session_id(_holder, _session_id), do: :ok

  defp emit_usage(on_message, usage, metadata) do
    case token_usage(usage) do
      nil -> :ok
      token_usage -> emit_message(on_message, :token_usage, %{usage: token_usage}, metadata)
    end
  end

  defp bounded_diagnostics(diagnostics, line) do
    trimmed = String.slice(String.trim(line), 0, 500)
    Enum.take(diagnostics ++ [trimmed], -@diagnostic_limit)
  end

  defp diagnostics_tail(state) do
    lines =
      case state.stop_reason do
        nil -> state.diagnostics
        reason -> state.diagnostics ++ ["stopReason: #{reason}"]
      end

    Enum.take(lines, -6)
  end

  # ───────────────── 子进程 ─────────────────

  @doc """
  Spawn the CLI, feed every line to `handle/2`, and return the accumulated state.

  `handle` is `(state, line -> state)`, so the caller owns the state machine and this function
  owns only process lifetime — which is also what makes the stream injectable in tests
  (mirroring the ACP backend's `:transport` injection).

  Line buffering, the Windows `:hide` flag and the child tree kill all come from
  `AcpSdk.Subprocess`; that module is the single place where those Windows lessons live, and
  its 1 MiB line limit matters here because a `tool_completed` result can be large.
  """
  @spec stream_port([String.t()], Path.t(), pos_integer(), turn_state(), (turn_state(), String.t() -> turn_state())) ::
          {:ok, turn_state(), integer()} | {:error, term()}
  def stream_port(command, cwd, timeout_ms, state, handle) do
    case Subprocess.open(command: command, cwd: cwd, line_mode: true) do
      {:ok, port} ->
        try do
          receive_lines(port, state, handle, timeout_ms, "")
        after
          close_quietly(port)
        end

      {:error, reason} ->
        {:error, {:commandcode_spawn_failed, reason}}
    end
  end

  defp receive_lines(port, state, handle, timeout_ms, partial) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        receive_lines(port, handle.(state, line), handle, timeout_ms, "")

      {^port, {:data, {:noeol, chunk}}} ->
        # A partial line at the 1 MiB limit: keep it so a split object is not silently dropped.
        receive_lines(port, state, handle, timeout_ms, partial <> chunk)

      {^port, {:exit_status, code}} ->
        state = if partial == "", do: state, else: handle.(state, partial)
        {:ok, state, code}
    after
      timeout_ms ->
        kill_tree_quietly(port)
        {:error, :turn_timeout}
    end
  end

  # The CLI spawns children of its own (node workers); on timeout the whole tree has to go or
  # the orchestrator keeps paying for a turn nobody is watching.
  defp kill_tree_quietly(port) do
    Subprocess.kill_tree(port)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp close_quietly(port) do
    Subprocess.close(port)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # ───────────────── workspace 安全（与 Codex / ACP 同一套规则） ─────────────────

  # Symphony's only write path for an agent turn cwd is `Codex.AppServer.validate_workspace_cwd/2`
  # and that function is private (it may not be refactored). Rather than invent a second policy,
  # the same rules are applied in the same order: `.`/`..` resolve before the prefix check, a
  # symlinked child that escapes the root is `:symlink_escape`, and the workspace root itself is
  # never a valid turn cwd.
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

  # ───────────────── 小工具 ─────────────────

  defp turn_timeout_ms do
    case Map.get(Config.settings!().commandcode, :turn_timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> @default_turn_timeout_ms
    end
  end

  # `System.unique_integer/1` makes each turn's id differ from the previous one, which is what
  # the orchestrator's turn counter keys on. It is minted **once** per turn so the emitted
  # `:session_started` and the returned `session_id` are the same string.
  defp turn_session_id(resume_id, turn) do
    "#{resume_id || @session_id_base}-#{System.unique_integer([:positive])}-#{turn}"
  end

  defp session_id(metadata), do: Map.get(metadata, :commandcode_session_id) || Map.get(metadata, :workspace)

  defp int_value(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_integer(value) -> value
        _ -> nil
      end
    end)
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
