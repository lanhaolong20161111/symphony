defmodule SymphonyElixir.RecorderClientTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.RecorderClient

  @sessions [
    %{"agent" => "workbuddy", "tokensUsed" => 141_010, "contextWindows" => [300_000]},
    %{"agent" => "workbuddy", "tokensUsed" => 1_000, "contextWindows" => [300_000, 128_000]},
    %{"agent" => "codex", "tokensUsed" => 1_177_388, "contextWindows" => [950_000]},
    %{"agent" => "codex", "tokensUsed" => nil, "contextWindows" => []},
    %{"tokensUsed" => 5}
  ]

  describe "usage_from/1" do
    test "groups by agent and sums the tokens" do
      rows = RecorderClient.usage_from(@sessions)

      by_agent = Map.new(rows, &{&1.agent, &1})

      assert by_agent["workbuddy"].sessions == 2
      assert by_agent["workbuddy"].tokens == 142_010
      assert by_agent["codex"].tokens == 1_177_388
    end

    test "the largest context window per agent, for explaining handoffs" do
      rows = RecorderClient.usage_from(@sessions) |> Map.new(&{&1.agent, &1})

      assert rows["workbuddy"].context == 300_000
      assert rows["codex"].context == 950_000
    end

    test "a session with no agent counts under unknown, and its tokens still count" do
      rows = RecorderClient.usage_from(@sessions) |> Map.new(&{&1.agent, &1})

      assert rows["unknown"].sessions == 1
      # The fixture's unknown-agent session really does carry 5 tokens; the point is that a missing
      # `agent` does not make the number disappear.
      assert rows["unknown"].tokens == 5
      assert rows["unknown"].context == 0
    end

    test "sorted by tokens, biggest first -- the question is what cost the most" do
      tokens = RecorderClient.usage_from(@sessions) |> Enum.map(& &1.tokens)

      assert tokens == Enum.sort(tokens, :desc)
      assert hd(tokens) == 1_177_388
    end

    test "an empty list is an empty table, not an error" do
      assert RecorderClient.usage_from([]) == []
    end
  end

  describe "when the recorder is not there" do
    setup do
      previous = Application.get_env(:symphony_elixir, :recorder_upstream)
      Application.put_env(:symphony_elixir, :recorder_upstream, "http://127.0.0.1:1")

      on_exit(fn ->
        if previous,
          do: Application.put_env(:symphony_elixir, :recorder_upstream, previous),
          else: Application.delete_env(:symphony_elixir, :recorder_upstream)
      end)

      :ok
    end

    test "usage/0 reports it rather than returning zero rows that look like real data" do
      assert {:error, {:recorder_unreachable, _reason}} = RecorderClient.usage()
    end

    test "sessions/0 reports it too" do
      assert {:error, {:recorder_unreachable, _reason}} = RecorderClient.sessions()
    end
  end

  describe "base_url/0" do
    test "defaults to the standalone recorder and is configurable" do
      previous = Application.get_env(:symphony_elixir, :recorder_upstream)
      Application.delete_env(:symphony_elixir, :recorder_upstream)
      assert RecorderClient.base_url() == "http://127.0.0.1:4010"

      Application.put_env(:symphony_elixir, :recorder_upstream, "http://127.0.0.1:4999")
      assert RecorderClient.base_url() == "http://127.0.0.1:4999"

      if previous,
        do: Application.put_env(:symphony_elixir, :recorder_upstream, previous),
        else: Application.delete_env(:symphony_elixir, :recorder_upstream)
    end
  end
end
