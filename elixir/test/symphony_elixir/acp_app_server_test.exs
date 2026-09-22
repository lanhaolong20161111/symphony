defmodule SymphonyElixir.ACP.AppServerTest do
  use SymphonyElixir.TestSupport

  alias AcpSdk.Transport.Memory
  alias Ecto.Changeset
  alias SymphonyElixir.ACP.AppServer
  alias SymphonyElixir.Codex.AppServer, as: CodexAppServer
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.TestSupport.ACP.FakeAgent

  @model_value ~s(["fake","m1"])

  setup do
    # Memory transports and fake agents are linked; teardown must not kill the test process.
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "ACP event mapping" do
    test "maps ACP session/update notifications onto Symphony event names" do
      metadata = %{acp_session_id: "sess-1"}

      assert {:agent_message_chunk, %{session_id: "sess-1", text: "hi"}} =
               AppServer.acp_event(
                 %{
                   "method" => "session/update",
                   "params" => %{"update" => %{"sessionUpdate" => "agent_message_chunk", "content" => %{"type" => "text", "text" => "hi"}}}
                 },
                 metadata
               )

      assert {:agent_thought_chunk, %{session_id: "sess-1", text: "hmm"}} =
               AppServer.acp_event(
                 %{
                   "method" => "session/update",
                   "params" => %{"update" => %{"sessionUpdate" => "agent_thought_chunk", "content" => %{"type" => "text", "text" => "hmm"}}}
                 },
                 metadata
               )

      assert {:tool_call, %{session_id: "sess-1", tool_call_id: "call-1", title: "shell", status: "pending"}} =
               AppServer.acp_event(
                 %{
                   "method" => "session/update",
                   "params" => %{
                     "update" => %{"sessionUpdate" => "tool_call", "toolCallId" => "call-1", "title" => "shell", "status" => "pending"}
                   }
                 },
                 metadata
               )

      assert {:plan, %{entries: [%{"content" => "step"}]}} =
               AppServer.acp_event(
                 %{"method" => "session/update", "params" => %{"update" => %{"sessionUpdate" => "plan", "entries" => [%{"content" => "step"}]}}},
                 metadata
               )

      assert {:acp_usage_update, %{used: 7, size: 100}} =
               AppServer.acp_event(
                 %{"method" => "session/update", "params" => %{"update" => %{"sessionUpdate" => "usage_update", "used" => 7, "size" => 100}}},
                 metadata
               )

      assert {:acp_event, %{session_update: "future_update"}} =
               AppServer.acp_event(
                 %{"method" => "session/update", "params" => %{"update" => %{"sessionUpdate" => "future_update"}}},
                 metadata
               )
    end

    test "maps anything that is not a session/update onto a catch-all raw event" do
      assert {:acp_raw_event, %{session_id: "sess-1", event: %{"method" => "session/request_permission"}}} =
               AppServer.acp_event(%{"method" => "session/request_permission"}, %{acp_session_id: "sess-1"})
    end

    test "treats a non-text content block as empty text" do
      assert {:agent_message_chunk, %{text: ""}} =
               AppServer.acp_event(
                 %{
                   "method" => "session/update",
                   "params" => %{"update" => %{"sessionUpdate" => "agent_message_chunk", "content" => %{"type" => "image"}}}
                 },
                 %{acp_session_id: "sess-1"}
               )
    end
  end

  describe "token usage mapping" do
    test "normalizes ACP-style token maps into the shape the orchestrator reads" do
      assert AppServer.token_usage(%{input_tokens: 3, output_tokens: 4}) ==
               %{"input_tokens" => 3, "output_tokens" => 4, "total_tokens" => 7}

      assert AppServer.token_usage(%{"promptTokens" => 5, "completionTokens" => 6, "totalTokens" => 11}) ==
               %{"input_tokens" => 5, "output_tokens" => 6, "total_tokens" => 11}
    end

    test "stays silent for payloads the orchestrator cannot use" do
      assert AppServer.token_usage(%{"used" => 7, "size" => 100}) == nil
      assert AppServer.token_usage(nil) == nil
    end
  end

  describe "backend selection" do
    test "agent.backend defaults to the Codex app-server" do
      assert AgentRunner.agent_backend() == CodexAppServer
    end

    test "agent.backend: acp selects the ACP backend" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "acp")

      assert AgentRunner.agent_backend() == AppServer
    end

    test "the schema accepts the acp backend and rejects anything else" do
      assert Schema.Agent.backends() == ["codex", "acp", "commandcode"]
      assert Schema.Acp.adapters() == ["dsh", "workbuddy"]

      assert %{backend: "acp"} =
               Schema.Agent.changeset(%Schema.Agent{}, %{"backend" => "acp"})
               |> Changeset.apply_changes()

      refute Schema.Agent.changeset(%Schema.Agent{}, %{"backend" => "gemini"}).valid?
    end

    test "an explicit acp.command is used verbatim instead of the adapter default" do
      write_workflow_file!(Workflow.workflow_file_path(), acp_command: ["node", "custom-agent.js", "--acp"])

      assert Config.settings!().acp.command == ["node", "custom-agent.js", "--acp"]
    end

    test "acp settings default to DSH with permissive timeouts" do
      acp = Config.settings!().acp

      assert acp.adapter == "dsh"
      assert acp.command == []
      assert acp.model == nil
      assert acp.init_timeout_ms == 60_000
      assert acp.turn_timeout_ms == 3_600_000
    end

    test "acp settings reject an unknown adapter and non-positive timeouts" do
      refute Schema.Acp.changeset(%Schema.Acp{}, %{"adapter" => "claude"}).valid?
      refute Schema.Acp.changeset(%Schema.Acp{}, %{"init_timeout_ms" => 0}).valid?
      refute Schema.Acp.changeset(%Schema.Acp{}, %{"turn_timeout_ms" => -1}).valid?
    end
  end

  describe "session lifecycle" do
    test "start/run/stop completes a turn and emits the events the orchestrator consumes" do
      with_local_workspace(fn workspace ->
        session = start_acp_session(workspace)
        on_exit_stop(session)

        messages = run_turn_collect(session, "do the thing")

        session_started = event(messages, :session_started)

        # `<acp-session-id>-<local turn id>-<turn>`; the middle segment is minted per turn.
        assert session_id_segments(session_started.session_id) == ["fake-acp-session", "1"]
        assert session_started.turn == 1
        assert session_started.acp_session_id == FakeAgent.session_id()
        # `session/new` gets the canonicalized workspace, not the raw input path.
        assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)
        assert session_started.workspace == canonical_workspace
        assert %DateTime{} = session_started.timestamp

        # Two ACP `agent_message_chunk` updates arrive as two *incremental* chunks, never as a
        # running total (which would collide with the SDK's `on_stream` semantics).
        assert [%{text: "hello from "}, %{text: "the fake agent"}] =
                 Enum.map(Enum.filter(messages, &(&1.event == :agent_message_chunk)), &Map.take(&1, [:text]))

        assert [%{text: "thinking about do the thing"}] =
                 Enum.map(Enum.filter(messages, &(&1.event == :agent_thought_chunk)), &Map.take(&1, [:text]))

        assert [%{tool_call_id: "call-1", status: "pending"}] =
                 Enum.map(Enum.filter(messages, &(&1.event == :tool_call)), &Map.take(&1, [:tool_call_id, :status]))

        assert [%{entries: [%{"content" => "step one"}]}] =
                 Enum.map(Enum.filter(messages, &(&1.event == :plan)), &Map.take(&1, [:entries]))

        assert [%{used: 7, size: 100}] =
                 Enum.map(Enum.filter(messages, &(&1.event == :acp_usage_update)), &Map.take(&1, [:used, :size]))

        assert_received {:fake_acp, :session_new, %{"cwd" => ^canonical_workspace, "mcpServers" => []}}

        assert_received {:fake_acp, :set_config_option, %{"configId" => "model", "value" => @model_value, "sessionId" => "fake-acp-session"}}

        assert_received {:fake_acp, :prompt, %{"sessionId" => "fake-acp-session", "prompt" => [%{"type" => "text", "text" => "do the thing"}]}}

        assert :ok = AppServer.stop_session(session)
        refute Process.alive?(session.client)
      end)
    end

    test "run/4 starts a session, runs one turn, and stops the client" do
      with_local_workspace(fn workspace ->
        transport = memory_transport()

        assert {:ok, result} = AppServer.run(workspace, "ship it", %{id: "issue-1", identifier: "S-1"}, transport: transport)

        assert session_id_segments(result.session_id) == ["fake-acp-session", "1"]
        assert result.stop_reason == "end_turn"
        assert result.acp_session_id == FakeAgent.session_id()
        assert result.result.text == "hello from the fake agent"
      end)
    end

    test "each run_turn on one session reports a distinct session_id" do
      with_local_workspace(fn workspace ->
        session = start_acp_session(workspace)
        on_exit_stop(session)

        first_id = event(run_turn_collect(session, "turn one"), :session_started).session_id
        second_id = event(run_turn_collect(session, "turn two"), :session_started).session_id

        # The orchestrator's turn_count_for_update/3 only increments when :session_started
        # carries a session_id it has not already recorded. ACP has no per-turn wire id
        # (sessionId is fixed for the whole session), so the backend mints a local unique
        # suffix; reusing the session's `turn` field would pin turn_count at 1 for the run.
        assert first_id != second_id
        assert String.starts_with?(first_id, "#{FakeAgent.session_id()}-")
        assert String.starts_with?(second_id, "#{FakeAgent.session_id()}-")
      end)
    end

    test "a refused turn reports turn_ended_with_error with the session id" do
      with_local_workspace(fn workspace ->
        session = start_acp_session(workspace, scenario: :turn_error)
        on_exit_stop(session)

        parent = self()

        assert {:error, {:prompt_failed, {-32_603, "turn refused"}}} =
                 AppServer.run_turn(session, "nope", issue(), on_message: send_to(parent))

        assert_received {:acp_message, %{event: :session_started}}

        assert_received {:acp_message,
                         %{
                           event: :turn_ended_with_error,
                           reason: {:prompt_failed, {-32_603, "turn refused"}},
                           session_id: session_id
                         }}

        assert String.starts_with?(session_id, "#{FakeAgent.session_id()}-")
      end)
    end

    test "a stream that breaks mid-turn still surfaces the failure" do
      with_local_workspace(fn workspace ->
        session = start_acp_session(workspace, scenario: :stream_error)
        on_exit_stop(session)

        parent = self()

        assert {:error, {:prompt_failed, {-32_603, "stream broke"}}} =
                 AppServer.run_turn(session, "nope", issue(), on_message: send_to(parent))

        assert_received {:acp_message, %{event: :agent_message_chunk, text: "partial"}}
        assert_received {:acp_message, %{event: :turn_ended_with_error}}
      end)
    end

    test "stop_session tolerates an already-stopped client" do
      with_local_workspace(fn workspace ->
        session = start_acp_session(workspace)

        assert :ok = AppServer.stop_session(session)
        assert :ok = AppServer.stop_session(session)
      end)
    end
  end

  describe "startup failures" do
    test "rejects a non-local worker_host without starting anything" do
      with_local_workspace(fn workspace ->
        assert {:error, {:unsupported_worker_host, "builder@example.com"}} =
                 AppServer.start_session(workspace, worker_host: "builder@example.com")
      end)
    end

    test "reports a wrapped error when the ACP agent refuses session/new" do
      with_local_workspace(fn workspace ->
        assert {:error, {:acp_start_failed, {:session_new_failed, {:request_failed, {-32_602, "session/new refused"}}}}} =
                 AppServer.start_session(workspace, transport: memory_transport(scenario: :session_error))

        refute_received {:fake_acp, :prompt, _}
      end)
    end

    test "reports a wrapped error when the ACP agent refuses initialize" do
      with_local_workspace(fn workspace ->
        assert {:error, {:acp_start_failed, {:initialize_failed, {:request_failed, {-32_603, "initialize refused"}}}}} =
                 AppServer.start_session(workspace, transport: memory_transport(scenario: :init_error))
      end)
    end

    test "fails fast when workbuddy has neither command nor cli_path" do
      # The headless entry point is packed inside the WorkBuddy app, so there is no usable
      # default command: without `cli_path` (or an explicit `command`) this must not silently
      # start the wrong thing.
      with_local_workspace_setup(fn test_root, _workspace_root ->
        workspace = Path.join(test_root, "workbuddy-workspace")
        File.mkdir_p!(workspace)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: test_root,
          acp_adapter: "workbuddy",
          acp_cli_path: nil,
          acp_command: nil
        )

        assert {:error, {:missing_acp_cli_path, :workbuddy}} = AppServer.start_session(workspace)
      end)
    end
  end

  describe "workspace safety" do
    test "rejects the workspace root itself" do
      root = Config.local_workspace_root()
      File.mkdir_p!(root)

      assert {:error, {:invalid_workspace_cwd, :workspace_root, _canonical_root}} =
               AppServer.start_session(root, transport: memory_transport())
    end

    test "rejects a workspace outside the configured root" do
      with_local_workspace(fn _workspace ->
        outside = Path.join(System.tmp_dir!(), "symphony-acp-outside-#{System.unique_integer([:positive])}")

        try do
          File.mkdir_p!(outside)

          assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _canonical, _root}} =
                   AppServer.start_session(outside, transport: memory_transport())
        after
          File.rm_rf(outside)
        end
      end)
    end

    @tag :needs_symlinks
    test "rejects a symlinked workspace that escapes the root" do
      with_local_workspace_setup(fn test_root, workspace_root ->
        outside = Path.join(test_root, "outside")
        File.mkdir_p!(outside)

        link = Path.join(workspace_root, "MT-ACP-ESCAPE")

        case File.ln_s(outside, link) do
          :ok ->
            assert {:error, {:invalid_workspace_cwd, :symlink_escape, _expanded, _canonical_root}} =
                     AppServer.start_session(link, transport: memory_transport())

          {:error, _reason} ->
            # Windows without developer mode cannot create symlinks; the escape branch requires
            # one, and the plain outside-root case above still covers the rejection path.
            :ok
        end
      end)
    end

    test "session/new receives the canonicalized workspace" do
      with_local_workspace_setup(
        fn _test_root, workspace_root ->
          workspace = Path.join(workspace_root, "MT-ACP-CANON")
          File.mkdir_p!(workspace)

          session = start_acp_session(workspace)
          on_exit_stop(session)

          assert {:ok, canonical} = SymphonyElixir.PathSafety.canonicalize(workspace)
          assert_received {:fake_acp, :session_new, %{"cwd" => ^canonical}}
        end,
        acp_model: @model_value
      )
    end
  end

  # ───────────────── helpers ─────────────────

  defp issue, do: %{id: "issue-1", identifier: "S-1"}

  # `<acp-session-id>-<local turn id>-<turn>`; the ACP session id itself may contain dashes, so
  # only the last two segments are ours.
  defp session_id_segments(session_id) do
    case Enum.split(String.split(session_id, "-"), -2) do
      {acp_session_id, [turn_id, turn]} when acp_session_id != [] ->
        if turn_id != "" and String.to_integer(turn_id) > 0, do: [Enum.join(acp_session_id, "-"), turn]

      _other ->
        []
    end
  end

  defp with_local_workspace(fun), do: with_local_workspace_setup(fn _test_root, root -> fun.(Path.join(root, "MT-ACP")) end)

  # Points `workspace.root` at a fresh temp dir, pre-creates the workspace directory the way
  # `AgentRunner` gets it from `Workspace.create_for_issue/2`, and installs the ACP settings for
  # the test. One write for both keeps `workspace.root` from being reset to the shared default.
  defp with_local_workspace_setup(fun, acp_overrides \\ []) do
    test_root = Path.join(System.tmp_dir!(), "symphony-elixir-acp-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")

    File.mkdir_p!(Path.join(workspace_root, "MT-ACP"))
    configure_acp(workspace_root, acp_overrides)

    try do
      fun.(test_root, workspace_root)
    after
      File.rm_rf(test_root)
    end
  end

  defp configure_acp(workspace_root, overrides) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          workspace_root: workspace_root,
          acp_adapter: "dsh",
          acp_model: @model_value,
          acp_init_timeout_ms: 5_000,
          acp_turn_timeout_ms: 5_000
        ],
        overrides
      )
    )
  end

  defp start_acp_session(workspace, opts \\ []) do
    assert {:ok, session} =
             AppServer.start_session(workspace, transport: memory_transport(Keyword.take(opts, [:scenario])))

    session
  end

  # Wires a fake ACP agent to one end of an in-process memory transport and returns the other end
  # (the value `AcpSdk.start_client/1` takes as `:transport`).
  defp memory_transport(opts \\ []) do
    {client_transport, agent_transport} = Memory.pair()

    {:ok, _agent} =
      FakeAgent.start_link(agent_transport,
        notify: self(),
        scenario: Keyword.get(opts, :scenario, :end_turn)
      )

    client_transport
  end

  defp on_exit_stop(session) do
    on_exit(fn -> AppServer.stop_session(session) end)
  end

  defp send_to(pid), do: fn message -> send(pid, {:acp_message, message}) end

  # `:session_started` is emitted by `run_turn/4` itself, so drain everything it produced.
  defp run_turn_collect(session, prompt) do
    parent = self()

    assert {:ok, _turn} = AppServer.run_turn(session, prompt, issue(), on_message: send_to(parent))

    drain_messages([])
  end

  defp drain_messages(acc) do
    receive do
      {:acp_message, message} -> drain_messages([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp event(messages, name) do
    case Enum.filter(messages, &(&1.event == name)) do
      [message] -> message
      other -> raise ExUnit.AssertionError, message: "expected exactly one #{inspect(name)} event, got #{inspect(other)}"
    end
  end
end
