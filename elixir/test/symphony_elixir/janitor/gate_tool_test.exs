defmodule SymphonyElixir.Janitor.GateToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Janitor.GateTool
  alias SymphonyElixir.Shell
  alias SymphonyElixir.Tracker.File, as: FileTracker

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
  # there, which is the trap `TestSupport` documents.
  defp write_gate_workflow!(command, opts \\ []) do
    root = Keyword.get_lazy(opts, :workspace_root, fn -> tmp_dir("symphony-gate-workspaces") end)
    timeout = Keyword.get(opts, :timeout_ms, @declared_timeout)

    gate =
      case command do
        nil -> "gate:\n"
        declared -> "gate:\n  command: \"#{declared}\"\n  timeout_ms: #{timeout}\n"
      end

    contents = """
    ---
    tracker:
      kind: memory
    workspace:
      root: "#{String.replace(root, "\\", "/")}"
    #{gate}---
    Gate tool test workflow.
    """

    File.write!(Workflow.workflow_file_path(), contents)
    assert :ok = WorkflowStore.force_reload()

    root
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
      write_gate_workflow!(nil)

      assert GateTool.tool_specs() == []

      assert spec_names(FileTracker.agent_tool_specs()) ==
               ["symphony_publish", "ticket_comment", "ticket_state"]

      write_gate_workflow!(@gate_command)

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

      # The three janitor tools are still advertised beside it.
      assert spec_names(FileTracker.agent_tool_specs()) ==
               ["symphony_publish", "ticket_comment", "ticket_state", "symphony_gate"]
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
    test "the file tracker routes the gate tool and leaves the janitor's three alone" do
      write_gate_workflow!(@gate_command)
      workspace = tmp_dir("symphony-gate-session")

      gate =
        FileTracker.execute_agent_tool("symphony_gate", %{},
          issue: %{identifier: "SYM-26"},
          workspace: workspace,
          runner: recording_runner({:ok, "green", 0})
        )

      assert gate["success"]

      state =
        FileTracker.execute_agent_tool(
          "ticket_state",
          %{"ticket" => "SYM-26", "state" => "in-review"},
          set_state: fn ticket, state ->
            send(self(), {:state_set, ticket, state})
            {:ok, %{ticket: ticket, state: state}}
          end
        )

      assert state["success"]
      assert_received {:state_set, "SYM-26", "in-review"}

      unsupported = FileTracker.execute_agent_tool("not_a_tool", %{}, [])

      refute unsupported["success"]

      assert decode_payload(unsupported)["error"]["supportedTools"] ==
               ["symphony_publish", "ticket_comment", "ticket_state"]
    end
  end
end
