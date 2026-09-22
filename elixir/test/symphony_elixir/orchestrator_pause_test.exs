defmodule SymphonyElixir.OrchestratorPauseTest do
  # async: false —— 会写 workflow 文件并改全局 app env（memory tracker 的 issue 列表）
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Orchestrator, Workflow}
  alias SymphonyElixir.Tracker.Issue

  setup do
    previous = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    path = Workflow.workflow_file_path()

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :memory_tracker_issues, previous)
      Workflow.set_workflow_file_path(path)
    end)

    :ok
  end

  defp active_issue do
    %Issue{
      id: "pause-1",
      identifier: "MT-PAUSE-1",
      title: "Should not be picked up while paused",
      description: "Seed for the pause test.",
      state: "open",
      labels: []
    }
  end

  test "paused means no new work is taken on, and the state is visible" do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [active_issue()])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      active_states: ["open"]
    )

    name = Module.concat(__MODULE__, :PausedOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: name)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    # snapshot/pause/resume take a registered name, like the rest of this API (they use
    # Process.whereis/1); send/2 and :sys.get_state/1 take the pid.
    # Not paused to begin with: the snapshot says so, and the API surfaces this field.
    assert %{paused: false} = Orchestrator.snapshot(name, 1_000)

    assert %{paused: true} = Orchestrator.pause(name)
    assert %{paused: true} = Orchestrator.snapshot(name, 1_000)

    # A poll cycle while paused: the active issue is there, a slot is free, and nothing is claimed.
    # This is the promise the flag exists for -- reconciliation still runs, dispatch does not.
    send(pid, :tick)
    state = :sys.get_state(pid)

    assert MapSet.size(state.claimed) == 0
    assert state.running == %{}

    # Resuming flips it back, so the flag is not a one-way door.
    assert %{paused: false} = Orchestrator.resume(name)
    assert %{paused: false} = Orchestrator.snapshot(name, 1_000)

    # And it reports :unavailable rather than crashing when no orchestrator is running.
    assert Orchestrator.pause(Module.concat(__MODULE__, :NotRunning)) == :unavailable
  end
end
