defmodule SymphonyElixir.MCP.TrackerServerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.MCP.TrackerServer

  defp line(map), do: Jason.encode!(map)

  defp request(id, method, params \\ nil) do
    base = %{"jsonrpc" => "2.0", "id" => id, "method" => method}
    TrackerServer.handle_line(line(if params, do: Map.put(base, "params", params), else: base))
  end

  test "initialize advertises the tools capability and names the server" do
    assert %{
             "jsonrpc" => "2.0",
             "id" => 1,
             "result" => %{
               "protocolVersion" => _,
               "capabilities" => %{"tools" => %{}},
               "serverInfo" => %{"name" => name, "version" => _}
             }
           } = request(1, "initialize")

    assert name == "symphony-tracker"
  end

  test "notifications are not answered" do
    assert TrackerServer.handle_line(line(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})) == :no_reply
  end

  test "ping is answered" do
    assert %{"result" => %{}} = request(2, "ping")
  end

  # The test tracker is the memory adapter, which exposes no agent tools -- so this asserts the
  # shape the client depends on, not that a particular tool is present.
  test "tools/list always answers with a list" do
    assert %{"result" => %{"tools" => tools}} = request(3, "tools/list")
    assert is_list(tools)
  end

  test "calling a tool without a tracker that has any is a tool-level error, not a protocol error" do
    assert %{"result" => %{"isError" => true, "content" => [%{"type" => "text", "text" => text}]}} =
             request(4, "tools/call", %{"name" => "github_api", "arguments" => %{}})

    assert text =~ "no agent tools"
  end

  test "tools/call without a name is a tool-level error" do
    assert %{"result" => %{"isError" => true}} = request(5, "tools/call", %{"arguments" => %{}})
  end

  test "an unknown method is a protocol error" do
    assert %{"error" => %{"code" => -32_601}} = request(6, "resources/list")
  end

  test "malformed and non-request input is answered rather than crashing" do
    assert %{"error" => %{"code" => -32_700}} = TrackerServer.handle_line("not json at all")
    assert %{"error" => %{"code" => -32_700}} = TrackerServer.handle_line("")
    assert %{"error" => %{"code" => -32_700}} = TrackerServer.handle_line("   ")
    assert %{"error" => %{"code" => -32_600}} = TrackerServer.handle_line(line(%{"jsonrpc" => "2.0", "id" => 7}))
    assert %{"error" => %{"code" => -32_600}} = TrackerServer.handle_line(line(%{"id" => 8, "method" => 42}))
  end

  test "serve/1 writes one line per request and nothing for notifications" do
    input = [
      line(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"}),
      line(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}),
      line(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})
    ]

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = TrackerServer.serve(input)
      end)

    replies = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert length(replies) == 2
    assert Enum.map(replies, & &1["id"]) == [1, 2]
  end
end
