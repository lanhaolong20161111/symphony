defmodule SymphonyElixir.Janitor.ServerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Janitor.Server

  # These tests drive the scheduling directly. `:round` is injected so nothing here touches git or
  # GitHub, and `first_delay_ms: 0` makes the first round happen immediately rather than after the
  # production five-second settle.

  defp start_server(opts) do
    test_pid = self()

    round = fn options ->
      send(test_pid, {:round, options})
      :ok
    end

    # `enabled: true` explicitly: a disabled janitor returns `:ignore`, which is exactly what the
    # last test checks, and every other test needs it running.
    defaults = [enabled: true, round: round, options: [tickets: "/tmp/x"]]

    start_supervised!({Server, Keyword.merge(defaults, opts)})
  end

  test "runs a round, then waits the interval before the next one" do
    start_server(interval_ms: 60_000, first_delay_ms: 0)

    assert_receive {:round, options}, 1_000
    assert options[:tickets] == "/tmp/x"

    # The second round must not arrive early: the timer is the whole point of the interval.
    refute_receive {:round, _}, 150
  end

  test "keeps running rounds on the interval" do
    start_server(interval_ms: 120, first_delay_ms: 0)

    for _ <- 1..3 do
      assert_receive {:round, _}, 1_000
    end
  end

  test "a round that raises does not stop the server" do
    test_pid = self()

    round = fn _options ->
      send(test_pid, :attempt)
      raise "boom"
    end

    start_supervised!({Server, Keyword.merge([enabled: true, round: round, options: []], interval_ms: 120, first_delay_ms: 0)})

    # If the exception escaped, the server would be gone and the second round would never happen.
    assert_receive :attempt, 1_000
    assert_receive :attempt, 1_000
    assert Process.alive?(Process.whereis(Server))
  end

  test "the supervisor restarts it after it exits" do
    # The point of moving the janitor under Symphony: nobody has to notice that it died. A
    # `:permanent` child is restarted by its supervisor. `use GenServer` omits the key, and an
    # omitted `:restart` means `:permanent` -- so assert the effective policy, not the key.
    assert Map.get(Server.child_spec([]), :restart, :permanent) == :permanent

    start_server(interval_ms: 60_000, first_delay_ms: 0)
    original = Process.whereis(Server)
    assert is_pid(original)

    Process.exit(original, :kill)

    assert eventually(fn ->
             case Process.whereis(Server) do
               pid when is_pid(pid) and pid != original -> true
               _ -> false
             end
           end)
  end

  defp eventually(fun, attempts \\ 50)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  test "does nothing at all when it is not enabled" do
    # The standing rule for this fork: an addition must be inert until a workflow asks for it. A
    # disabled janitor returns `:ignore` from `init/1`, so it is not even started -- and
    # `start_link/1` says so rather than pretending to have succeeded.
    test_pid = self()

    round = fn _options ->
      send(test_pid, {:round, :should_not_happen})
      :ok
    end

    assert Server.start_link(
             enabled: false,
             round: round,
             options: [],
             interval_ms: 50,
             first_delay_ms: 0
           ) == :ignore

    refute_receive {:round, _}, 200
  end
end
