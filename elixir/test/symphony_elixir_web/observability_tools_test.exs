defmodule SymphonyElixirWeb.ObservabilityToolsTest do
  # async: false -- writes a workflow file (the flag lives there) and starts the endpoint under test.
  use ExUnit.Case, async: false

  alias SymphonyElixir.Workflow

  # Before `import Phoenix.ConnTest`: its helpers resolve the endpoint from this attribute.
  @endpoint SymphonyElixirWeb.Endpoint

  import Plug.Conn
  import Phoenix.ConnTest

  setup do
    previous = Workflow.workflow_file_path()
    on_exit(fn -> Workflow.set_workflow_file_path(previous) end)

    dir = Path.join(System.tmp_dir!(), "obs-tools-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, dir: dir}
  end

  defp write_workflow!(dir, tracker_tools) do
    path = Path.join(dir, "WORKFLOW.md")

    File.write!(path, """
    ---
    tracker:
      kind: memory
      active_states: [open]
    server:
      host: 127.0.0.1
      tracker_tools: #{tracker_tools}
    ---

    Test prompt.
    """)

    Workflow.set_workflow_file_path(path)
    :ok
  end

  defp start_endpoint do
    config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp post_tool(body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/tools/github_api", body)
  end

  test "the tool route is closed unless the workflow enables it", %{dir: dir} do
    write_workflow!(dir, false)
    start_endpoint()

    assert %{"error" => %{"code" => "tracker_tools_disabled"}} =
             json_response(post_tool(%{}), 404)
  end

  # The test tracker is the memory adapter, so there are no agent tools to run: what this pins down
  # is that the enabled route says so instead of crashing.
  test "when enabled, a tracker with no agent tools answers cleanly", %{dir: dir} do
    write_workflow!(dir, true)
    start_endpoint()

    assert %{"error" => %{"code" => "no_agent_tools"}} = json_response(post_tool(%{}), 404)
  end

  # Object bodies with nonsense in them: the route answers, it does not crash.
  test "object bodies with unusable values are rejected, never a 500", %{dir: dir} do
    write_workflow!(dir, true)
    start_endpoint()

    for body <- [%{"path" => 1}, %{"method" => nil}, %{"nested" => %{"a" => [1, 2]}}] do
      response = post_tool(body)

      assert response.status in [400, 404],
             "body #{inspect(body)} produced #{response.status}"
    end
  end

  # Bodies the parser cannot turn into parameters. Before the endpoint wrapped Plug.Parsers these
  # raised inside it, so the client got an exception rather than a status -- the same gap the
  # recorder's endpoint had. Note the bodies are sent as raw binaries: a list handed to ConnTest is
  # not a request body at all and raises in the test helper, which is how this was first misread.
  test "bodies the parser rejects are answered with a status, never an exception", %{dir: dir} do
    write_workflow!(dir, true)
    start_endpoint()

    for body <- ["not json at all", "[1, 2, 3]", ~s("a bare string"), "{\"unclosed\": ", ""] do
      response = post_tool(body)

      assert response.status in [400, 404, 413, 415],
             "body #{inspect(body)} produced #{response.status}"
    end

    # And the malformed ones are specifically 400, with a code, rather than whatever the route does
    # with empty parameters.
    assert %{"error" => %{"code" => "malformed_body"}} =
             json_response(post_tool("not json at all"), 400)
  end

  test "the route is absent from the router while the endpoint is not running", %{dir: dir} do
    # Nothing starts the endpoint here, so the route is simply not served; the point is that this
    # does not blow up the test suite's own supervisor.
    write_workflow!(dir, true)
    refute Process.whereis(@endpoint)
  end
end
