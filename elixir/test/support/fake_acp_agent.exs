defmodule SymphonyElixir.TestSupport.ACP.FakeAgent do
  @moduledoc """
  A **minimal** in-process fake ACP agent for exercising `SymphonyElixir.ACP.AppServer`.

  It speaks just enough ACP v1 to drive a full handshake + one turn over
  `AcpSdk.Transport.Memory.pair/0`:

  - `initialize` → protocolVersion + empty capabilities
  - `session/new` → a session id and (optionally) `configOptions`
  - `session/set_config_option` → `{}`, recording what the host asked for
  - `session/prompt` → streams a few `session/update` notifications, then replies with
    `%{"stopReason" => ...}`

  > This is deliberately **not** a copy of `AcpSdk.TestAgent`. The SDK's own test support
  > module is part of its `test` environment and is not available to a dependent project.
  """

  use GenServer

  alias AcpSdk.Transport

  @session_id "fake-acp-session"

  @type scenario :: :end_turn | :stream_error | :turn_error | :session_error | :init_error

  @doc """
  Start a fake agent behind one end of a memory transport pair.

  `opts`:

  - `:scenario` — `:end_turn` (default) | `:stream_error` | `:turn_error` |
    `:session_error` | `:init_error`
  - `:session_id` — override the session id reported by `session/new`
  - `:config_options` — the `configOptions` list reported by `session/new`
  - `:notify` — pid that receives `{:fake_acp, event, payload}` for every request handled,
    so tests can assert on `session/new` params and `set_config_option` calls
  """
  @spec start_link(term(), keyword()) :: GenServer.on_start()
  def start_link(transport, opts \\ []) do
    GenServer.start_link(__MODULE__, {transport, opts})
  end

  @doc "Session id this fake agent reports."
  @spec session_id() :: String.t()
  def session_id, do: @session_id

  @impl true
  def init({transport, opts}) do
    :ok = Transport.handoff(transport, self())

    {:ok,
     %{
       transport: transport,
       scenario: Keyword.get(opts, :scenario, :end_turn),
       session_id: Keyword.get(opts, :session_id, @session_id),
       config_options: Keyword.get(opts, :config_options),
       notify: Keyword.get(opts, :notify)
     }}
  end

  @impl true
  def handle_info({:acp_message, transport, msg}, %{transport: transport} = state) do
    {:noreply, handle_message(state, msg)}
  end

  def handle_info({:acp_closed, transport, _reason}, %{transport: transport} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp handle_message(state, %{"id" => id, "method" => method} = msg) do
    handle_request(state, id, method, Map.get(msg, "params") || %{})
  end

  # Notification: only session/cancel matters here.
  defp handle_message(state, %{"method" => "session/cancel"}), do: state
  defp handle_message(state, _msg), do: state

  defp handle_request(state, id, "initialize", _params) do
    if state.scenario == :init_error do
      reply_error(state, id, -32_603, "initialize refused")
    else
      reply(state, id, %{"protocolVersion" => 1, "agentCapabilities" => %{}, "authMethods" => []})
    end
  end

  defp handle_request(state, id, "session/new", params) do
    notify(state, :session_new, params)

    if state.scenario == :session_error do
      reply_error(state, id, -32_602, "session/new refused")
    else
      base = %{"sessionId" => state.session_id}

      result =
        case state.config_options do
          nil -> base
          options -> Map.put(base, "configOptions", options)
        end

      reply(state, id, result)
    end
  end

  defp handle_request(state, id, "session/set_config_option", params) do
    notify(state, :set_config_option, params)
    reply(state, id, %{})
  end

  defp handle_request(state, id, "session/prompt", params) do
    prompt = prompt_text(params) |> String.trim()
    notify(state, :prompt, params)

    case state.scenario do
      :stream_error ->
        state
        |> update(%{"sessionUpdate" => "agent_message_chunk", "content" => %{"type" => "text", "text" => "partial"}})
        |> reply_error(id, -32_603, "stream broke")

      :turn_error ->
        reply_error(state, id, -32_603, "turn refused")

      _ ->
        state
        |> update(%{
          "sessionUpdate" => "agent_thought_chunk",
          "content" => %{"type" => "text", "text" => "thinking about #{prompt}"}
        })
        |> update(%{"sessionUpdate" => "tool_call", "toolCallId" => "call-1", "title" => "shell", "status" => "pending"})
        |> update(%{"sessionUpdate" => "plan", "entries" => [%{"content" => "step one"}]})
        |> update(%{"sessionUpdate" => "usage_update", "used" => 7, "size" => 100})
        |> update(%{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "hello from "}
        })
        |> update(%{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "the fake agent"}
        })
        |> reply(id, %{"stopReason" => "end_turn"})
    end
  end

  defp handle_request(state, id, method, params) do
    notify(state, {:unhandled, method}, params)
    reply(state, id, %{})
  end

  defp reply(state, id, result) do
    Transport.send(state.transport, AcpSdk.Protocol.response(id, result))
    state
  end

  defp reply_error(state, id, code, message) do
    Transport.send(state.transport, AcpSdk.Protocol.error(id, code, message))
    state
  end

  defp update(state, update_obj) do
    Transport.send(
      state.transport,
      AcpSdk.Protocol.notification("session/update", %{
        "sessionId" => state.session_id,
        "update" => update_obj
      })
    )

    state
  end

  defp notify(%{notify: pid}, event, payload) when is_pid(pid) do
    send(pid, {:fake_acp, event, payload})
    :ok
  end

  defp notify(_state, _event, _payload), do: :ok

  defp prompt_text(%{"prompt" => blocks}) when is_list(blocks) do
    Enum.map_join(blocks, "", fn
      %{"text" => text} when is_binary(text) -> text
      _block -> ""
    end)
  end

  defp prompt_text(_params), do: ""
end
