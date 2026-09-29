defmodule SymphonyElixir.Janitor.AgentToolTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Janitor.AgentTool

  # Nothing here reaches git or GitHub: `:publish` is injected, the same seam the tracker adapters use
  # for their clients. What is worth pinning is the shape both consumers depend on -- `success`,
  # `output`, `contentItems` for a Codex turn, and the same map wrapped as MCP content by the stdio
  # server -- plus one thing that matters more than the happy path: a failure that says *which ticket*
  # and *why*. This tool exists so a run can report what happened; "error" alone would put the run
  # back where it started.

  defp stub(result) do
    fn ticket ->
      send(self(), {:published, ticket})
      result
    end
  end

  test "advertises one tool, taking the ticket as an argument" do
    assert [%{"name" => "symphony_publish", "description" => description, "inputSchema" => schema}] =
             AgentTool.tool_specs()

    assert is_binary(description)
    assert schema["type"] == "object"
    assert Map.has_key?(schema["properties"], "ticket")
    refute schema["additionalProperties"]
  end

  test "publishes the ticket the call names, and reports branch and pull request" do
    result =
      {:ok,
       %{
         branch: "symphony/SYM-26",
         committed: true,
         pushed: true,
         pull_request: "https://github.com/me/repo/pull/30"
       }}

    response = AgentTool.execute("symphony_publish", %{"ticket" => "SYM-26"}, publish: stub(result))

    assert response["success"]
    assert_received {:published, "SYM-26"}

    payload = Jason.decode!(response["output"])
    assert payload["ticket"] == "SYM-26"
    assert payload["branch"] == "symphony/SYM-26"
    assert payload["pull_request"] =~ "/pull/30"
    assert [%{"type" => "inputText", "text" => text}] = response["contentItems"]
    assert text == response["output"]
  end

  test "falls back to the ticket this turn is running" do
    response =
      AgentTool.execute("symphony_publish", %{},
        issue: %{identifier: "SYM-31"},
        publish: stub({:ok, %{branch: "symphony/SYM-31"}})
      )

    assert response["success"]
    assert_received {:published, "SYM-31"}
  end

  test "a failed publish names the ticket and the reason" do
    response =
      AgentTool.execute("symphony_publish", %{"ticket" => "SYM-999"},
        publish: stub({:error, {:no_such_ticket, "SYM-999"}})
      )

    refute response["success"]
    payload = Jason.decode!(response["output"])
    assert payload["error"]["ticket"] == "SYM-999"
    assert payload["error"]["message"] =~ "no ticket file"
  end

  test "a call that names no ticket anywhere fails instead of guessing" do
    response = AgentTool.execute("symphony_publish", %{}, publish: stub(:never_used))

    refute response["success"]
    assert Jason.decode!(response["output"])["error"]["message"] =~ "needs a ticket identifier"
  end

  test "an unknown tool is refused, listing the one that exists" do
    response = AgentTool.execute("something_else", %{}, publish: stub(:never_used))

    refute response["success"]
    assert Jason.decode!(response["output"])["error"]["supportedTools"] == ["symphony_publish"]
  end

  test "an exception while publishing becomes a failed result, not a crashed session" do
    exploding = fn _ticket -> raise "no workspace to publish at /tmp/nope" end

    response = AgentTool.execute("symphony_publish", %{"ticket" => "SYM-1"}, publish: exploding)

    refute response["success"]
    assert Jason.decode!(response["output"])["error"]["message"] =~ "no workspace"
  end
end
