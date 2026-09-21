defmodule SymphonyElixir.CommandCode.AppServerTest do
  use SymphonyElixir.TestSupport

  alias Ecto.Changeset
  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Codex.AppServer, as: CodexAppServer
  alias SymphonyElixir.CommandCode.AppServer
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Workflow

  # Verbatim lines captured from `commandcode -p <prompt> --output-format json`
  # (v1.58.1, 2026-09-21). Real fixtures on purpose: the whole point of this backend is that the
  # CLI's stream shape is what it is, not what we would have designed.
  @run_start ~s({"type":"event","event":{"type":"run_start","sessionId":"cmd-sess-1"}})
  @thinking_delta ~s({"type":"event","event":{"type":"thinking_delta","delta":"Simple"}})
  @text_delta ~s({"type":"event","event":{"type":"text_delta","delta":"ok"}})
  @message_update ~s({"type":"event","event":{"type":"message_update","content":[{"type":"text","text":"ok"}]}})
  @message_end ~s({"type":"event","event":{"type":"message_end","content":[{"type":"text","text":"ok"}]}})
  @turn_end ~s({"type":"event","event":{"type":"turn_end","turnNumber":1,"hadToolCalls":true,"usage":{"inputTokens":16567,"outputTokens":101,"cacheReadTokens":7552,"cacheWriteTokens":0}}})
  @tool_queued ~s({"type":"event","event":{"type":"tool_queued","toolCallId":"call-1","toolName":"write_file","input":{"file_path":"a.txt","content":"ok"}}})
  @tool_running ~s({"type":"event","event":{"type":"tool_running","toolCallId":"call-1","toolName":"write_file","description":null}})
  @tool_completed ~s({"type":"event","event":{"type":"tool_completed","toolCallId":"call-1","toolName":"write_file","result":[{"type":"text","text":"File created successfully"}],"deferred":false}})

  @usage ~s({"inputTokens":16547,"outputTokens":2,"cacheReadTokens":5248,"cacheWriteTokens":0})
  @model_request_end ~s({"type":"event","event":{"type":"model_request_end","model":"deepseek/deepseek-v4.1-flash","usage":) <> @usage <> ~s(,"stopReason":"stop","effort":"high"}})
  @run_end ~s({"type":"event","event":{"type":"run_end","result":{"finalText":"ok","stopReason":"end_turn","turnCount":1,"usage":) <> @usage <> ~s(}}})
  @result_line ~s({"type":"result","subtype":"success","sessionId":"cmd-sess-1","stopReason":"end_turn","usage":) <> @usage <> ~s(,"durationMs":3076,"finalText":"ok"})

  @happy_lines [@run_start, @thinking_delta, @text_delta, @message_update, @message_end, @model_request_end, @run_end, @result_line]

  describe "backend selection" do
    test "the default backend is still the Codex app-server" do
      assert AgentRunner.agent_backend() == CodexAppServer
    end

    test "agent.backend: commandcode selects this backend" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "commandcode")

      assert AgentRunner.agent_backend() == AppServer
    end

    test "the schema accepts commandcode and still rejects unknown backends" do
      assert "commandcode" in Schema.Agent.backends()

      assert %{backend: "commandcode"} =
               Schema.Agent.changeset(%Schema.Agent{}, %{"backend" => "commandcode"})
               |> Changeset.apply_changes()

      refute Schema.Agent.changeset(%Schema.Agent{}, %{"backend" => "gemini"}).valid?
      refute Schema.CommandCode.changeset(%Schema.CommandCode{}, %{"turn_timeout_ms" => 0}).valid?
      refute Schema.CommandCode.changeset(%Schema.CommandCode{}, %{"turn_timeout_ms" => -1}).valid?
    end

    test "commandcode settings default to the CLI on PATH with a one-hour turn budget" do
      cc = Config.settings!().commandcode

      assert cc.command == []
      assert cc.cli_path == nil
      assert cc.model == nil
      assert cc.effort == nil
      assert cc.extra_args == []
      assert cc.turn_timeout_ms == 3_600_000
    end
  end

  describe "argv" do
    test "defaults to the npm shim with the unattended flags, prompt last" do
      assert {:ok, argv} = AppServer.build_command("hi", nil, empty_cc())

      assert argv == [
               "command-code",
               "--yolo",
               "--no-auto-update",
               "--skip-onboarding",
               "--output-format",
               "json",
               "-p",
               "hi"
             ]
    end

    test "cli_path switches to the node entry point" do
      assert AppServer.default_command(cli_path: "C:/cc/dist/index.mjs") == ["node", "C:/cc/dist/index.mjs"]

      assert {:ok, argv} =
               AppServer.build_command("hi", nil, %{empty_cc() | cli_path: "C:/cc/dist/index.mjs"})

      assert Enum.take(argv, 2) == ["node", "C:/cc/dist/index.mjs"]
    end

    test "an explicit command is used verbatim and never mixed with the default" do
      assert {:ok, argv} = AppServer.build_command("hi", nil, %{empty_cc() | command: ["cc", "--flag"]})

      assert Enum.take(argv, 2) == ["cc", "--flag"]
      refute "command-code" in argv
    end

    test "model, effort, resume id and extra args are threaded through" do
      cc = %{empty_cc() | model: "deepseek/deepseek-v4.1-flash", effort: "high", extra_args: ["--max-turns", "7"]}

      assert {:ok, argv} = AppServer.build_command("hi", "cmd-sess-9", cc)

      assert arg_after(argv, "--session") == "cmd-sess-9"
      assert arg_after(argv, "-m") == "deepseek/deepseek-v4.1-flash"
      assert arg_after(argv, "--effort") == "high"
      assert arg_after(argv, "--max-turns") == "7"
      assert Enum.take(argv, -2) == ["-p", "hi"]
    end

    test "no --session on the first turn" do
      assert {:ok, argv} = AppServer.build_command("hi", nil, empty_cc())

      refute "--session" in argv
    end
  end

  describe "event mapping" do
    test "deltas become chunks" do
      metadata = %{commandcode_session_id: "s1"}

      assert {:agent_message_chunk, %{session_id: "s1", text: "ok"}} =
               AppServer.cc_event(%{"type" => "text_delta", "delta" => "ok"}, metadata)

      assert {:agent_thought_chunk, %{session_id: "s1", text: "Simple"}} =
               AppServer.cc_event(%{"type" => "thinking_delta", "delta" => "Simple"}, metadata)
    end

    test "the three tool lifecycle events share one tool_call_id and carry the status" do
      metadata = %{commandcode_session_id: "s1"}

      assert {:tool_call, queued} = AppServer.cc_event(Jason.decode!(@tool_queued)["event"], metadata)
      assert {:tool_call, running} = AppServer.cc_event(Jason.decode!(@tool_running)["event"], metadata)
      assert {:tool_call, done} = AppServer.cc_event(Jason.decode!(@tool_completed)["event"], metadata)

      assert [queued.status, running.status, done.status] == ["queued", "running", "completed"]
      assert Enum.uniq([queued.tool_call_id, running.tool_call_id, done.tool_call_id]) == ["call-1"]
      assert queued.title == "write_file"
      assert queued.input == %{"file_path" => "a.txt", "content" => "ok"}
      assert done.output == "File created successfully"
    end

    # The regression this guards: `message_update` carries the *cumulative* content, so treating
    # it as a chunk would double-count every character of the reply.
    test "cumulative message_update / message_end are NOT chunks" do
      metadata = %{commandcode_session_id: "s1"}

      assert {:commandcode_event, %{commandcode_event: %{"type" => "message_update"}}} =
               AppServer.cc_event(Jason.decode!(@message_update)["event"], metadata)

      assert {:commandcode_event, %{commandcode_event: %{"type" => "message_end"}}} =
               AppServer.cc_event(Jason.decode!(@message_end)["event"], metadata)

      assert {:commandcode_event, %{commandcode_event: %{"type" => "turn_end", "hadToolCalls" => true}}} =
               AppServer.cc_event(Jason.decode!(@turn_end)["event"], metadata)
    end

    test "anything unrecognised is a catch-all event the orchestrator ignores" do
      assert {:commandcode_event, %{session_id: "s1"}} =
               AppServer.cc_event(%{"type" => "future_event"}, %{commandcode_session_id: "s1"})
    end
  end

  describe "token usage" do
    test "normalizes the CLI's camelCase counters into the shape the orchestrator reads" do
      assert AppServer.token_usage(Jason.decode!(@usage)) == %{
               "input_tokens" => 16_547,
               "output_tokens" => 2,
               "total_tokens" => 16_549,
               "cache_read_tokens" => 5_248,
               "cache_write_tokens" => 0
             }
    end

    test "also accepts snake_case, and returns nil when there is nothing to report" do
      assert AppServer.token_usage(%{"input_tokens" => 3, "output_tokens" => 4})["total_tokens"] == 7
      assert AppServer.token_usage(%{}) == nil
      assert AppServer.token_usage(nil) == nil
    end
  end

  describe "session lifecycle" do
    test "start/run/stop emits the events the orchestrator consumes and reports the turn" do
      with_local_workspace(fn workspace ->
        session = start_session!(workspace)

        {turn, messages} = run_turn_collect(session, @happy_lines)

        names = Enum.map(messages, & &1.event)

        assert hd(names) == :session_started
        assert :agent_message_chunk in names
        assert :agent_thought_chunk in names
        assert :commandcode_event in names
        assert List.last(names) == :token_usage

        # The emitted session id and the returned one must be the same string: the orchestrator
        # counts turns by that id.
        started = Enum.find(messages, &(&1.event == :session_started))
        assert turn.session_id == started.session_id
        assert turn.stop_reason == "end_turn"
        assert turn.commandcode_session_id == "cmd-sess-1"
        assert turn.usage["cache_read_tokens"] == 5_248

        AppServer.stop_session(session)
      end)
    end

    test "the second turn resumes the CLI session and gets its own turn id" do
      with_local_workspace(fn workspace ->
        session = start_session!(workspace)
        parent = self()

        {:ok, first} = AppServer.run_turn(session, "one", issue(), stream: capturing_stream(@happy_lines, parent))
        first_argv = next_argv()

        {:ok, second} = AppServer.run_turn(session, "two", issue(), stream: capturing_stream(@happy_lines, parent))
        second_argv = next_argv()

        assert first.session_id != second.session_id
        refute "--session" in first_argv
        assert arg_after(second_argv, "--session") == "cmd-sess-1"

        AppServer.stop_session(session)
      end)
    end

    test "a turn that never reports run_start fails with the CLI's own diagnostics attached" do
      with_local_workspace(fn workspace ->
        session = start_session!(workspace)

        lines = ["not json, just the CLI complaining", ~s({"type":"event","event":{"type":"turn_start","turnNumber":1}})]

        assert {:error, {:commandcode_start_failed, 1, diagnostics}} =
                 AppServer.run_turn(session, "one", issue(), stream: fake_stream(lines, 1))

        assert Enum.any?(diagnostics, &String.contains?(&1, "just the CLI complaining"))
        AppServer.stop_session(session)
      end)
    end

    test "a non-zero exit with no result line is a failure" do
      with_local_workspace(fn workspace ->
        session = start_session!(workspace)

        assert {:error, {:commandcode_exit_status, 3, _}} =
                 AppServer.run_turn(session, "one", issue(), stream: fake_stream([@run_start], 3))

        AppServer.stop_session(session)
      end)
    end

    test "a non-zero exit WITH a result line is a normal turn (--max-turns exits 8 after finishing)" do
      with_local_workspace(fn workspace ->
        session = start_session!(workspace)

        assert {:ok, turn} =
                 AppServer.run_turn(session, "one", issue(), stream: fake_stream(@happy_lines, 8))

        assert turn.stop_reason == "end_turn"

        AppServer.stop_session(session)
      end)
    end

    test "a stream-level failure (e.g. the turn timeout) is reported as a turn error" do
      with_local_workspace(fn workspace ->
        session = start_session!(workspace)
        parent = self()

        stream = fn _command, _cwd, _timeout, _state, _handle -> {:error, :turn_timeout} end

        assert {:error, :turn_timeout} =
                 AppServer.run_turn(session, "one", issue(), stream: stream, on_message: send_to(parent))

        messages = drain_messages([])
        assert Enum.map(messages, & &1.event) == [:session_started, :turn_ended_with_error]
        AppServer.stop_session(session)
      end)
    end

    test "a remote worker host is refused before anything is spawned" do
      assert {:error, {:unsupported_worker_host, "build-01"}} =
               AppServer.start_session("/tmp/whatever", worker_host: "build-01")
    end

    test "a workspace outside the configured root is refused" do
      with_local_workspace(fn _workspace ->
        outside = Path.join(System.tmp_dir!(), "definitely-outside-#{System.unique_integer([:positive])}")
        File.mkdir_p!(outside)

        assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _, _}} =
                 AppServer.start_session(outside)

        File.rm_rf(outside)
      end)
    end

    test "stop_session is idempotent and never raises" do
      with_local_workspace(fn workspace ->
        session = start_session!(workspace)

        assert AppServer.stop_session(session) == :ok
        assert AppServer.stop_session(session) == :ok
        assert AppServer.stop_session(%{}) == :ok
      end)
    end
  end

  # ─── helpers ────────────────────────────────────────────────────────────────

  defp empty_cc, do: %{command: [], cli_path: nil, model: nil, effort: nil, extra_args: []}

  defp arg_after(argv, flag) do
    case Enum.find_index(argv, &(&1 == flag)) do
      nil -> nil
      index -> Enum.at(argv, index + 1)
    end
  end

  # `capturing_stream/2` sends one `{:argv, ...}` per turn; drain them in turn order.
  defp next_argv do
    receive do
      {:argv, argv} -> argv
    after
      1_000 -> flunk("expected an argv capture from the injected stream")
    end
  end

  defp fake_stream(lines, exit_code) do
    fn _command, _cwd, _timeout, state, handle ->
      # `handle` is `(state, line -> state)` (see `stream_port/5`), while `Enum.reduce/3` yields
      # `(element, acc)` — hence the swap.
      {:ok, Enum.reduce(lines, state, fn line, acc -> handle.(acc, line) end), exit_code}
    end
  end

  defp capturing_stream(lines, parent) do
    fn command, _cwd, _timeout, state, handle ->
      send(parent, {:argv, command})
      {:ok, Enum.reduce(lines, state, fn line, acc -> handle.(acc, line) end), 0}
    end
  end

  defp start_session!(workspace) do
    assert {:ok, session} = AppServer.start_session(workspace)
    on_exit(fn -> AppServer.stop_session(session) end)
    session
  end

  defp run_turn_collect(session, lines) do
    parent = self()
    on_message = send_to(parent)

    assert {:ok, turn} = AppServer.run_turn(session, "do the thing", issue(), stream: fake_stream(lines, 0), on_message: on_message)

    {turn, drain_messages([])}
  end

  defp send_to(pid), do: fn message -> send(pid, {:cc_message, message}) end

  defp drain_messages(acc) do
    receive do
      {:cc_message, message} -> drain_messages([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp issue, do: %Issue{id: "MT-CC", identifier: "MT-CC", title: "t", state: "In Progress"}

  # Points `workspace.root` at a fresh temp dir and pre-creates the workspace directory the way
  # `AgentRunner` gets it from `Workspace.create_for_issue/2`.
  defp with_local_workspace(fun) do
    test_root = Path.join(System.tmp_dir!(), "symphony-elixir-cc-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-CC")

    File.mkdir_p!(workspace)

    write_workflow_file!(
      Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_backend: "commandcode",
      commandcode_turn_timeout_ms: 5_000,
      acp_turn_timeout_ms: 5_000
    )

    try do
      fun.(workspace)
    after
      File.rm_rf(test_root)
    end
  end
end
