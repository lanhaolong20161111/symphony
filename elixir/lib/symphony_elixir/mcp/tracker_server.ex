defmodule SymphonyElixir.MCP.TrackerServer do
  @moduledoc """
  A stdio MCP server that serves Symphony's tracker tools to an agent.

  Why this exists: a Codex app-server turn can be handed tools directly (`dynamicTools`), but an ACP
  session cannot. ACP's tool channel is MCP, and DSH expects to *launch* the MCP server itself
  rather than tunnel back to the client -- measured, see `examples/mcp_declaration_probe.exs` in the
  ACP SDK. Declaring this process (`bin/symphony mcp`) in an ACP session's `mcpServers` therefore
  gives an ACP agent the same tracker tools a Codex turn gets.

  The credentials stay on this side: the tools execute through
  `Tracker.execute_bound_agent_tool/4` with Symphony's own configuration, and the agent only sends a
  tool name and its arguments. Nothing about the tracker token reaches the agent's environment.

  Wire format: JSON-RPC 2.0, one message per line, replies on **stdout**. Anything logged must go to
  stderr; a stray line on stdout is a protocol error to the client.
  """

  alias SymphonyElixir.Tracker

  @protocol_version "2024-11-05"
  @server_name "symphony-tracker"

  # JSON-RPC 2.0 codes
  @parse_error -32_700
  @invalid_request -32_600
  @method_not_found -32_601

  @doc """
  Serves the loop on stdio until stdin closes.
  """
  @spec run() :: :ok
  def run do
    IO.puts(:stderr, "symphony mcp: serving tracker tools on stdio (#{@server_name})")
    serve(IO.stream(:stdio, :line))
  end

  @doc """
  Serves an enumerable of lines; split out from `run/0` so a test can drive it.
  """
  @spec serve(Enumerable.t()) :: :ok
  def serve(lines) do
    Enum.each(lines, fn line ->
      case handle_line(line) do
        :no_reply -> :ok
        response -> IO.puts(Jason.encode!(response))
      end
    end)
  end

  @doc """
  Answers one protocol line. Always returns something unless the message was a notification.
  """
  @spec handle_line(String.t()) :: map() | :no_reply
  def handle_line(line) do
    case Jason.decode(String.trim(line)) do
      # `method` has to be a string: JSON-RPC calls that a non-string method an invalid request
      # (-32600), not a missing method (-32601). `is_binary/1` is guard-safe; `=~` and
      # String.contains?/2 are not, which is why this is a guard here and a cond elsewhere.
      {:ok, %{"method" => method} = message} when is_binary(method) -> dispatch(method, message)
      {:ok, _not_a_request} -> error(nil, @invalid_request, "invalid request")
      {:error, _reason} -> error(nil, @parse_error, "parse error")
    end
  end

  defp dispatch("initialize", message) do
    reply(message, %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => @server_name, "version" => version()}
    })
  end

  # Notifications carry no id and must not be answered.
  defp dispatch("notifications/initialized", _message), do: :no_reply

  defp dispatch("ping", message), do: reply(message, %{})

  defp dispatch("tools/list", message), do: reply(message, %{"tools" => tool_specs()})

  defp dispatch("tools/call", message) do
    params = Map.get(message, "params") || %{}
    name = Map.get(params, "name")
    arguments = Map.get(params, "arguments") || %{}

    if is_binary(name) do
      reply(message, call_tool(name, arguments))
    else
      # A tool-level failure is a result with `isError`, per MCP; only protocol mistakes are errors.
      reply(message, tool_error("tools/call needs a tool name"))
    end
  end

  defp dispatch(_method, message), do: error(Map.get(message, "id"), @method_not_found, "method not found")

  defp call_tool(name, arguments) do
    case agent_tool_binding() do
      {:ok, binding} ->
        binding
        |> Tracker.execute_bound_agent_tool(name, arguments, [])
        |> then(&%{"content" => [text(Jason.encode!(&1))], "isError" => false})

      {:error, reason} ->
        tool_error("the configured tracker exposes no agent tools (#{inspect(reason)})")
    end
  rescue
    error -> tool_error("tool #{name} failed: #{Exception.message(error)}")
  end

  defp agent_tool_binding do
    case Tracker.bind_agent_tools() do
      %{tool_specs: []} -> {:error, :no_agent_tools}
      %{} = binding -> {:ok, binding}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp tool_specs do
    case agent_tool_binding() do
      {:ok, binding} -> binding.tool_specs
      {:error, _reason} -> []
    end
  end

  defp tool_error(message), do: %{"content" => [text(message)], "isError" => true}
  defp text(message), do: %{"type" => "text", "text" => message}

  defp reply(message, result) do
    base(message, %{"result" => result})
  end

  defp error(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  defp base(message, extra) do
    Map.merge(%{"jsonrpc" => "2.0", "id" => Map.get(message, "id")}, extra)
  end

  defp version do
    case Application.spec(:symphony_elixir, :vsn) do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end
end
