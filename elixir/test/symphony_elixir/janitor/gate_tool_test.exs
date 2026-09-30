defmodule SymphonyElixir.Janitor.GateToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Janitor.GateTool
  alias SymphonyElixir.MCP.TrackerServer
  alias SymphonyElixir.Shell
  alias SymphonyElixir.Tracker.File, as: FileTracker
  alias SymphonyElixir.Tracker.Memory
  alias SymphonyElixir.Tracker.TicketService

  # Nothing here runs a gate, starts a shell or opens a socket: `:runner` replaces `Shell.run/3`, the
  # same seam the janitor tools and the tracker clients take. What is worth pinning is the rule that
  # keeps the host safe -- a call names a ticket, never a command -- plus the ways a run can fail
  # while still answering as a value.

  @gate_command "mix lint && mix test"
  @declared_timeout 900_000

  # U+65E5 is three bytes, so a cut at an 8 KiB boundary can land inside it -- which is the whole
  # reason the byte cap goes through the character-safe truncation.
  @three_byte_char "\u65E5"

  defp spec_names(specs), do: Enum.map(specs, & &1["name"])

  defp tmp_dir(prefix) do
    dir = Path.expand(Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}"))
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # The workflow a person would write, with or without the gate block. `workspace.root` goes into a
  # YAML double-quoted scalar, so it is written with forward slashes: a Windows backslash is an escape
  # there, which is the trap `TestSupport` documents. The tracker is `memory` by default because most
  # cases here are about the gate itself; the composition cases name the kind they are about -- `file`,
  # whose adapter has tools of its own, and `ticket_service`, whose adapter has none.
  defp write_gate_workflow!(command, opts \\ []) do
    root = Keyword.get_lazy(opts, :workspace_root, fn -> tmp_dir("symphony-gate-workspaces") end)
    timeout = Keyword.get(opts, :timeout_ms, @declared_timeout)
    kind = Keyword.get(opts, :tracker, "memory")

    gate =
      case command do
        nil -> "gate:\n"
        declared -> "gate:\n  command: \"#{declared}\"\n  timeout_ms: #{timeout}\n"
      end

    contents = """
    ---
    #{tracker_block(kind)}workspace:
      root: "#{String.replace(root, "\\", "/")}"
    #{gate}---
    Gate tool test workflow.
    """

    File.write!(Workflow.workflow_file_path(), contents)
    assert :ok = WorkflowStore.force_reload()

    root
  end

  defp tracker_block("memory"), do: "tracker:\n  kind: memory\n"

  defp tracker_block("file") do
    # A directory that exists, because a file tracker without a readable path is a workflow that fails
    # to validate -- and a failed reload keeps the previous configuration.
    tickets = tmp_dir("symphony-gate-tickets")

    "tracker:\n  kind: file\n  provider:\n    path: \"#{String.replace(tickets, "\\", "/")}\"\n" <>
      "  active_states: [ready]\n  terminal_states: [done]\n"
  end

  defp tracker_block("ticket_service") do
    # The service-backed kind: it deliberately advertises no tracker tools of its own, which is the
    # case the gate tool has to reach anyway. `provider.url` is declared because `validate_config/1`
    # requires it -- and it probes nothing, so no socket is opened by this or any test here.
    "tracker:\n  kind: ticket_service\n  provider:\n    url: \"http://127.0.0.1:4020\"\n" <>
      "  active_states: [ready]\n  terminal_states: [done]\n"
  end

  defp recording_runner(result) do
    test_pid = self()

    fn executable, args, opts ->
      send(test_pid, {:gate_ran, executable, args, opts})
      result
    end
  end

  defp decode_payload(response), do: Jason.decode!(response["output"])

  defp failure_of(response), do: decode_payload(response)["error"]

  describe "the advertised spec" do
    test "is there when the project declares a gate, and gone when it does not" do
      # The tracker is `file` because this pins the composed list: the adapter's tools and the host's,
      # and nothing extra when no gate is declared. `Tracker.bind_agent_tools/0` is what every
      # transport advertises (`codex/dynamic_tool.ex`, `mcp/tracker_server.ex`, the HTTP endpoint);
      # `FileTracker.agent_tool_specs/0` is only what that list is composed with.
      write_gate_workflow!(nil, tracker: "file")

      assert GateTool.tool_specs() == []

      assert spec_names(DynamicTool.bind().tool_specs) ==
               ["symphony_publish", "ticket_comment", "ticket_state"]

      assert spec_names(FileTracker.agent_tool_specs()) ==
               ["symphony_publish", "ticket_comment", "ticket_state"]

      write_gate_workflow!(@gate_command, tracker: "file")

      assert [spec] = GateTool.tool_specs()
      assert spec["name"] == "symphony_gate"
      assert spec["inputSchema"]["type"] == "object"
      assert spec["inputSchema"]["additionalProperties"] == false
      assert Map.keys(spec["inputSchema"]["properties"]) == ["ticket"]
      refute Map.has_key?(spec["inputSchema"], "required")

      # The reason travels with the tool, because the description is the only text every run reads.
      assert spec["description"] =~ "sandbox"
      assert spec["description"] =~ "cannot start `mix`"
      assert spec["description"] =~ "on the host"

      # The three janitor tools are still advertised beside it, and the gate is appended by the
      # tracker boundary rather than by the adapter.
      assert spec_names(DynamicTool.bind().tool_specs) ==
               ["symphony_publish", "ticket_comment", "ticket_state", "symphony_gate"]

      assert spec_names(FileTracker.agent_tool_specs()) ==
               ["symphony_publish", "ticket_comment", "ticket_state"]
    end

    test "a blank declaration is not a gate, and says so instead of running the empty string" do
      write_gate_workflow!("   ")

      assert GateTool.tool_specs() == []

      response = GateTool.execute("symphony_gate", %{}, runner: recording_runner(:never_used))

      refute response["success"]
      assert failure_of(response)["message"] =~ "declares no gate"
      refute_received {:gate_ran, _, _, _}
    end
  end

  describe "running the declared gate" do
    test "runs the declared command, through the hooks' shell, in the session's workspace" do
      write_gate_workflow!(@gate_command)
      workspace = tmp_dir("symphony-gate-session")

      response =
        GateTool.execute("symphony_gate", %{},
          issue: %{identifier: "SYM-26"},
          workspace: workspace,
          runner: recording_runner({:ok, "1 doctest, 0 failures", 0})
        )

      assert response["success"]
      assert_received {:gate_ran, executable, args, opts}

      assert executable == (Shell.find_sh() || "sh")
      assert args == ["-lc", @gate_command]
      assert opts[:cd] == workspace
      assert opts[:timeout] == @declared_timeout

      payload = decode_payload(response)
      assert payload["exitCode"] == 0
      assert payload["timedOut"] == false
      assert payload["output"] =~ "0 failures"
      assert payload["gate"] == @gate_command
      assert payload["workspace"] == workspace
      assert payload["ticket"] == "SYM-26"
      refute payload["truncated"]

      assert [%{"type" => "inputText", "text" => text}] = response["contentItems"]
      assert text == response["output"]
    end

    test "the declared timeout is the one the runner is given" do
      write_gate_workflow!("make check", timeout_ms: 1_234)
      workspace = tmp_dir("symphony-gate-session")

      response =
        GateTool.execute("symphony_gate", %{}, workspace: workspace, runner: recording_runner({:ok, "", 0}))

      assert response["success"]
      assert_received {:gate_ran, _executable, args, opts}
      assert args == ["-lc", "make check"]
      assert opts[:timeout] == 1_234
    end

    test "derives the workspace from the ticket when the session names none" do
      # The ACP/MCP stdio server and the HTTP endpoint are separate processes: no session, no
      # workspace, so the ticket the call names is the only thing that can arrive there.
      root = write_gate_workflow!(@gate_command)

      response = GateTool.execute("symphony_gate", %{"ticket" => "SYM-26"}, runner: recording_runner({:ok, "", 0}))

      assert response["success"]
      assert_received {:gate_ran, _executable, _args, opts}
      assert Config.local_workspace_root() == Path.expand(root)
      assert opts[:cd] == Path.join(Config.local_workspace_root(), "SYM-26")
      assert decode_payload(response)["ticket"] == "SYM-26"
    end

    test "a call with neither a session nor a ticket fails instead of guessing a directory" do
      write_gate_workflow!(@gate_command)

      response = GateTool.execute("symphony_gate", %{}, runner: recording_runner(:never_used))

      refute response["success"]
      assert failure_of(response)["message"] =~ "needs a ticket identifier"
      refute_received {:gate_ran, _, _, _}
    end
  end

  describe "what a call may not say" do
    test "an argument that names a command, a shell, a script or a path is refused by name" do
      write_gate_workflow!(@gate_command)
      workspace = tmp_dir("symphony-gate-session")

      for bad <- ~w(command cmd shell sh script path argv cwd env) do
        response =
          GateTool.execute("symphony_gate", %{bad => "rm -rf /"},
            issue: %{identifier: "SYM-26"},
            workspace: workspace,
            runner: recording_runner(:never_used)
          )

        refute response["success"], "expected #{bad} to be refused"
        assert failure_of(response)["message"] =~ "takes no command"
        assert failure_of(response)["message"] =~ bad
        assert failure_of(response)["supportedArguments"] == ["ticket"]
      end

      refute_received {:gate_ran, _, _, _}
    end

    test "a bare shell string or an argv list is refused, not run" do
      write_gate_workflow!(@gate_command)
      workspace = tmp_dir("symphony-gate-session")

      for arguments <- [@gate_command, ["mix", "test"], ["-lc", @gate_command], 7] do
        response =
          GateTool.execute("symphony_gate", arguments,
            issue: %{identifier: "SYM-26"},
            workspace: workspace,
            runner: recording_runner(:never_used)
          )

        refute response["success"]
        assert failure_of(response)["message"] =~ "takes an object naming at most a ticket"
      end

      refute_received {:gate_ran, _, _, _}
    end

    test "a command is refused even beside a ticket the call is allowed to name" do
      write_gate_workflow!(@gate_command)
      workspace = tmp_dir("symphony-gate-session")

      response =
        GateTool.execute("symphony_gate", %{"ticket" => "SYM-26", "command" => "whoami"},
          workspace: workspace,
          runner: recording_runner(:never_used)
        )

      refute response["success"]
      assert failure_of(response)["message"] =~ "takes no command"
      refute_received {:gate_ran, _, _, _}
    end

    test "a ticket argument that is a path, or is not exactly a ticket name, is refused" do
      write_gate_workflow!(@gate_command)

      # `"SYM-26\n"` is in the list on purpose: an unanchored `$` accepts it, and the janitor's own
      # pattern does, after which the value is joined into a path.
      for bad <- ["../../etc", "C:/Windows/System32", "SYM-26/../..", "a b", "SYM-26\n", " SYM-26 ", ""] do
        response = GateTool.execute("symphony_gate", %{"ticket" => bad}, runner: recording_runner(:never_used))

        refute response["success"], "expected #{inspect(bad)} to be refused"
        assert failure_of(response)["message"] =~ "not a ticket identifier"
      end

      refute_received {:gate_ran, _, _, _}
    end

    test "the settings seam declares the command, so a test never needs the workflow" do
      # Injected settings, exactly like the adapters' injected clients: this is what keeps the tool's
      # command out of the caller's hands and out of the test's dependencies.
      workspace = tmp_dir("symphony-gate-session")

      response =
        GateTool.execute("symphony_gate", %{},
          workspace: workspace,
          settings: %{gate: %{command: "make gate", timeout_ms: 5_000}},
          runner: recording_runner({:ok, "ok", 0})
        )

      assert response["success"]
      assert_received {:gate_ran, _executable, args, opts}
      assert args == ["-lc", "make gate"]
      assert opts[:timeout] == 5_000
    end
  end

  describe "every failure is a value" do
    test "a non-zero exit comes back with the status and the tail" do
      write_gate_workflow!(@gate_command)
      workspace = tmp_dir("symphony-gate-session")

      response =
        GateTool.execute("symphony_gate", %{},
          workspace: workspace,
          runner: recording_runner({:ok, "2 tests, 1 failure", 1})
        )

      refute response["success"]
      failure = failure_of(response)
      assert failure["message"] =~ "exited 1"
      assert failure["exitCode"] == 1
      assert failure["output"] =~ "1 failure"
      assert failure["workspace"] == workspace
    end

    test "a timeout comes back with the deadline, and the runner owned the tree kill" do
      write_gate_workflow!(@gate_command, timeout_ms: 900_000)
      workspace = tmp_dir("symphony-gate-session")

      response =
        GateTool.execute("symphony_gate", %{}, workspace: workspace, runner: recording_runner({:error, :timeout}))

      refute response["success"]
      assert_received {:gate_ran, _executable, _args, opts}
      # The deadline is handed to `Shell.run/3`, whose expiry path reads the port's `:os_pid` and calls
      # `Shell.kill_tree/1` -- so the tree dies with the call instead of outliving it.
      assert opts[:timeout] == 900_000

      failure = failure_of(response)
      assert failure["timedOut"] == true
      assert failure["message"] =~ "did not finish within 900000 ms"
      assert failure["message"] =~ "killed the process tree"
    end

    test "a command that cannot start and a runner that raises both come back as failures" do
      write_gate_workflow!(@gate_command)
      workspace = tmp_dir("symphony-gate-session")

      not_found =
        GateTool.execute("symphony_gate", %{},
          workspace: workspace,
          runner: recording_runner({:error, {:not_found, "sh"}})
        )

      refute not_found["success"]
      assert failure_of(not_found)["message"] =~ "could not start"
      assert failure_of(not_found)["message"] =~ "sh"

      exploding = fn _executable, _args, _opts -> raise "the runner exploded" end
      raised = GateTool.execute("symphony_gate", %{}, workspace: workspace, runner: exploding)

      refute raised["success"]
      assert failure_of(raised)["message"] =~ "the runner exploded"
    end

    test "an unknown tool name is refused with the envelope, not an exception" do
      response = GateTool.execute("symphony_something_else", %{}, runner: recording_runner(:never_used))

      refute response["success"]
      assert failure_of(response)["message"] =~ "Unsupported dynamic tool"
      assert failure_of(response)["supportedTools"] == ["symphony_gate"]
      assert [%{"type" => "inputText", "text" => text}] = response["contentItems"]
      assert text == response["output"]
    end
  end

  describe "bounding the answer" do
    test "keeps the last lines of a long transcript" do
      write_gate_workflow!(@gate_command)
      workspace = tmp_dir("symphony-gate-session")
      transcript = Enum.map_join(1..100, "\n", &"line #{&1}")

      response =
        GateTool.execute("symphony_gate", %{}, workspace: workspace, runner: recording_runner({:ok, transcript, 0}))

      assert response["success"]
      payload = decode_payload(response)
      assert payload["truncated"] == true
      assert payload["output"] =~ "line 61"
      assert payload["output"] =~ "line 100"
      refute payload["output"] =~ "line 60"
    end

    test "cuts a large tail on a character boundary, so the answer stays text" do
      write_gate_workflow!(@gate_command)
      workspace = tmp_dir("symphony-gate-session")

      huge = Enum.map_join(1..40, "\n", fn _line -> String.duplicate(@three_byte_char, 100) end)

      response = GateTool.execute("symphony_gate", %{}, workspace: workspace, runner: recording_runner({:ok, huge, 0}))

      # Decoding is the assertion that matters: a cut inside a character would leave bytes that are no
      # longer UTF-8, and the payload could not be encoded as JSON at all.
      assert response["success"]
      payload = decode_payload(response)
      assert payload["truncated"] == true
      assert String.valid?(payload["output"])
      assert payload["output"] =~ @three_byte_char
      assert String.ends_with?(payload["output"], "... (truncated)")
      # 8 KiB of kept output plus the marker line `sanitize_hook_output_for_log/2` appends.
      assert byte_size(payload["output"]) < 8_192 + 64
      assert byte_size(payload["output"]) < byte_size(huge)
    end
  end

  describe "registration" do
    test "the boundary routes the gate tool and leaves the janitor's three alone" do
      write_gate_workflow!(@gate_command, tracker: "file")
      workspace = tmp_dir("symphony-gate-session")
      binding = DynamicTool.bind()

      gate =
        Tracker.execute_bound_agent_tool(binding, "symphony_gate", %{},
          issue: %{identifier: "SYM-26"},
          workspace: workspace,
          runner: recording_runner({:ok, "green", 0})
        )

      assert gate["success"]

      state =
        Tracker.execute_bound_agent_tool(
          binding,
          "ticket_state",
          %{"ticket" => "SYM-26", "state" => "in-review"},
          set_state: fn ticket, state ->
            send(self(), {:state_set, ticket, state})
            {:ok, %{ticket: ticket, state: state}}
          end
        )

      assert state["success"]
      assert_received {:state_set, "SYM-26", "in-review"}

      # Everything that is not a host tool goes to the adapter, whose own contract is unchanged: the
      # file adapter still answers an unknown tool itself (`janitor/agent_tool.ex:250-255`).
      unsupported = Tracker.execute_bound_agent_tool(binding, "not_a_tool", %{}, [])

      refute unsupported["success"]

      assert decode_payload(unsupported)["error"]["supportedTools"] ==
               ["symphony_publish", "ticket_comment", "ticket_state"]
    end

    test "a service-backed project that declares a gate is advertised the gate tool" do
      # The measured bug: `ticket_service` advertises no tools of its own, and the gate used to be
      # composed by the **file** adapter -- so a project whose tickets come from the service was
      # offered no tools at all, its agent read the workflow's `gate.command` and ran it itself in its
      # sandbox, where the project's gate cannot start at all.
      write_gate_workflow!(@gate_command, tracker: "ticket_service")

      binding = DynamicTool.bind()

      assert binding.adapter == TicketService
      assert Config.settings!().tracker.kind == "ticket_service"
      assert spec_names(binding.tool_specs) == ["symphony_gate"]

      # Reached through the boundary with no ticket and no session: the gate tool's own refusal, which
      # is a value -- not the adapter's "unsupported tool". Nothing runs, so the runner is never used.
      response =
        Tracker.execute_bound_agent_tool(binding, "symphony_gate", %{},
          runner: recording_runner(:never_used)
        )

      refute response["success"]
      assert failure_of(response)["message"] =~ "needs a ticket identifier"
      refute_received {:gate_ran, _, _, _}

      # The adapter gained nothing: a tool it does not advertise is still refused by the adapter.
      other = Tracker.execute_bound_agent_tool(binding, "ticket_state", %{}, [])

      refute other["success"]
      assert decode_payload(other)["error"]["message"] =~ "Unsupported dynamic tool"
    end

    test "no declared gate means nothing extra is advertised, whatever the kind" do
      # Pinned by hand: what each of these kinds advertises for itself, which is the whole composed
      # list while the project declares no gate. `memory` and `ticket_service` advertise none, which is
      # a value -- the HTTP tool endpoint reads an empty composed list as `no_agent_tools`.
      advertised = [
        {"memory", Memory, []},
        {"file", FileTracker, ["symphony_publish", "ticket_comment", "ticket_state"]},
        {"ticket_service", TicketService, []}
      ]

      Enum.each(advertised, fn {kind, adapter, tools} ->
        write_gate_workflow!(nil, tracker: kind)

        binding = DynamicTool.bind()

        assert binding.adapter == adapter
        assert spec_names(binding.tool_specs) == tools,
               "#{kind} advertises something extra for a project that declares no gate"
      end)

      # A blank declaration is not a gate either (schema.ex:579-582), and a call that arrives anyway is
      # answered with the sentence saying nothing was declared, not with "unsupported tool".
      write_gate_workflow!("   ", tracker: "ticket_service")
      assert DynamicTool.bind().tool_specs == []

      response =
        Tracker.execute_bound_agent_tool(DynamicTool.bind(), "symphony_gate", %{},
          runner: recording_runner(:never_used)
        )

      refute response["success"]
      assert failure_of(response)["message"] =~ "declares no gate"
      refute_received {:gate_ran, _, _, _}
    end

    test "the transports advertise it, and the MCP path runs it" do
      write_gate_workflow!(@gate_command, tracker: "file")

      # The three transports all read `Tracker.bind_agent_tools/0`: the Codex app-server sends
      # `binding.tool_specs` as `dynamicTools`, the ACP path's stdio MCP server answers `tools/list`
      # with the same list, and the HTTP endpoint answers `no_agent_tools` when it is empty. Both ends
      # of that list, plus one call through the MCP path, are what this pins.
      expected = ["symphony_publish", "ticket_comment", "ticket_state", "symphony_gate"]

      listed = TrackerServer.handle_line(~s({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}))
      assert spec_names(listed["result"]["tools"]) == expected

      assert spec_names(DynamicTool.bind().tool_specs) == expected

      # A call with no ticket is refused by the gate tool -- not by "unsupported tool" -- which is what
      # says the MCP path reaches this module. It names no workspace, so nothing is run.
      call =
        TrackerServer.handle_line(
          ~s({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "symphony_gate", "arguments": {}}})
        )

      assert [%{"type" => "text", "text" => text}] = call["result"]["content"]
      assert text =~ "needs a ticket identifier"
      refute text =~ "Unsupported dynamic tool"
    end
  end
end
