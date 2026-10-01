defmodule SymphonyElixir.AutoLandTest do
  # async: false -- every file-tracker test moves the global workflow file path, points the tracker
  # and the janitor's writes at a temp queue, and writes real tickets. Nothing here runs `gh`: the
  # land operation is injected, and the read is either the deployment's own tracker over that temp
  # queue or a function this file supplies.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.AutoLand
  alias SymphonyElixir.Config
  alias SymphonyElixir.Workflow

  @body "Ship the picker and keep every other byte.\n"

  # The four verdicts that stop a landing, with the skill's own name for each code and one of its own
  # lines: the sweep has to leave the ticket alone and say why, not paraphrase the reason.
  @refusals [
    %{code: 5, name: "conflict", message: "PR has merge conflicts."},
    %{code: 2, name: "feedback", message: "Review comments detected. Address before merge."},
    %{code: 4, name: "head moved", message: "PR head updated"},
    %{code: 3, name: "checks", message: "Checks failed:"}
  ]

  setup do
    previous = Workflow.workflow_file_path()
    on_exit(fn -> Workflow.set_workflow_file_path(previous) end)
    :ok
  end

  test "the block is off by default, and a workflow that says nothing about it starts no sweep" do
    defaults = struct(Config.Schema.AutoLand)

    refute defaults.enabled
    assert defaults.label == "auto-land"
    assert defaults.interval_ms > 0
    assert defaults.timeout_ms > 0
    assert defaults.max_per_pass == 1

    dir = queue!(%{"SYM-7" => %{}})

    # The deployment's own config: the block is absent, so the switch is off...
    refute Config.settings!().auto_land.enabled

    # ...and the child the application starts with this workflow is not a process at all.
    assert AutoLand.start_link(interval_ms: 20, first_delay_ms: 0) == :ignore

    # Which is why the ticket was never read, let alone landed.
    assert File.read!(ticket_path(dir, "SYM-7")) =~ "state: in-review"
  end

  test "a disabled sweep reads nothing, calls nothing and starts no process" do
    parent = self()

    tickets = fn _opts ->
      send(parent, :read)
      {:ok, [%{identifier: "SYM-7", state: "in-review", labels: ["auto-land"]}]}
    end

    land = fn _pr_url, _branch ->
      send(parent, :landed)
      {:ok, %{number: 7, url: pr_url(7)}}
    end

    off = settings(enabled: false)

    assert AutoLand.run_once(settings: off, tickets: tickets, land: land) ==
             %{read: :disabled, tickets: 0, candidates: 0, merged: 0, reported: %{}}

    refute_received :read
    refute_received :landed

    # A disabled `init/1` answers `:ignore`, so there is no timer to tick either.
    assert AutoLand.start_link(settings: off, tickets: tickets, land: land, interval_ms: 10, first_delay_ms: 0) ==
             :ignore

    refute_receive :read, 120
    refute_receive :landed, 20
  end

  test "a ticket in the review state without the label is left alone" do
    dir = queue!(%{"SYM-7" => %{labels: "[perf, windows]"}})
    before = File.read!(ticket_path(dir, "SYM-7"))
    {land, calls} = land_fake({:ok, %{number: 7, url: pr_url(7)}})

    log =
      capture_log(fn ->
        report = AutoLand.run_once(settings: settings(), land: land)

        assert report.candidates == 0
        assert report.merged == 0
        assert report.reported["SYM-7"] == :no_label
      end)

    assert land_calls(calls) == []
    assert File.read!(ticket_path(dir, "SYM-7")) == before
    assert log =~ "SYM-7 is in-review but carries no auto-land label"
  end

  test "a labelled ticket whose verdict is ok is landed, and the ticket records it" do
    dir = queue!(%{"SYM-7" => %{}})
    before = File.read!(ticket_path(dir, "SYM-7"))
    {land, calls} = land_fake({:ok, %{number: 7, url: pr_url(7)}})

    report = AutoLand.run_once(settings: settings(), land: land)
    after_text = File.read!(ticket_path(dir, "SYM-7"))

    # Handed exactly what the ticket records -- the pull request from its `links:` entry and the
    # branch beside it -- and the ticket is the only thing it was told: no pull request could have
    # been invented or searched for.
    assert land_calls(calls) == [%{pr_url: pr_url(7), branch: "symphony/SYM-7"}]
    assert report.candidates == 1
    assert report.merged == 1

    # The workflow's own terminal state, and the body it already had.
    assert after_text =~ "state: done\n"
    assert after_text =~ @body

    # And the trace the ticket has to carry: who landed it, the verdict, and what the merge did.
    assert after_text =~ "## Discussion"
    assert after_text =~ "- **auto-land** ("
    assert after_text =~ "id=local-1"
    assert after_text =~ "auto-land landed pull request 7 (#{pr_url(7)})"
    assert after_text =~ "Land verdict: ok (exit 0)"
    assert after_text =~ "squash-merged with the branch deleted"
    assert after_text =~ "This ticket was moved to done."

    assert String.starts_with?(after_text, String.replace(before, "state: in-review", "state: done"))
  end

  for refusal <- @refusals do
    test "a #{refusal.name} refusal merges nothing, writes nothing and is said once" do
      refusal = unquote(Macro.escape(refusal))
      dir = queue!(%{"SYM-7" => %{}})
      before = File.read!(ticket_path(dir, "SYM-7"))
      {land, calls} = land_fake({:refused, refusal.code, [refusal.message]})
      call = %{pr_url: pr_url(7), branch: "symphony/SYM-7"}

      log =
        capture_log(fn ->
          first = AutoLand.run_once(settings: settings(), land: land)

          assert first.candidates == 1
          assert first.merged == 0
          assert first.reported["SYM-7"] == {:refused, refusal.code}

          # The reason is remembered, so a second pass over the same refusal adds no line.
          second = AutoLand.run_once(settings: settings(), land: land, reported: first.reported)

          assert second.merged == 0
        end)

      # Asked once per pass, with the ticket's own two facts -- and a refusal writes nothing at all:
      # no state, no comment, not one byte different.
      assert land_calls(calls) == [call, call]
      assert File.read!(ticket_path(dir, "SYM-7")) == before
      assert log =~ refusal.name
      assert log =~ refusal.message
      assert occurrences(log, "auto-land: SYM-7 was not landed") == 1
    end
  end

  test "a ticket that records no pull request is skipped rather than searched for" do
    dir = queue!(%{"SYM-7" => %{links: ""}})
    before = File.read!(ticket_path(dir, "SYM-7"))
    {land, calls} = land_fake({:ok, %{number: 7, url: pr_url(7)}})

    log =
      capture_log(fn ->
        report = AutoLand.run_once(settings: settings(), land: land)

        assert report.candidates == 0
        assert report.reported["SYM-7"] == :no_pull_request
      end)

    assert land_calls(calls) == []
    assert File.read!(ticket_path(dir, "SYM-7")) == before
    assert log =~ "SYM-7 records no pull request"
    assert log =~ "nothing was searched for and nothing was merged"
  end

  test "a ticket that records a pull request but no branch is skipped rather than guessed" do
    dir = queue!(%{"SYM-7" => %{branch: ""}})
    before = File.read!(ticket_path(dir, "SYM-7"))
    {land, calls} = land_fake({:ok, %{number: 7, url: pr_url(7)}})

    log =
      capture_log(fn ->
        report = AutoLand.run_once(settings: settings(), land: land)

        assert report.candidates == 0
        assert report.reported["SYM-7"] == :no_branch
      end)

    assert land_calls(calls) == []
    assert File.read!(ticket_path(dir, "SYM-7")) == before
    assert log =~ "SYM-7 records a pull request but no branch"
  end

  test "a pass lands at most max_per_pass tickets, and the next pass takes the rest" do
    dir = queue!(%{"SYM-7" => %{}, "SYM-8" => %{}})
    {land, calls} = land_fake({:ok, %{number: 7, url: pr_url(7)}})

    first = AutoLand.run_once(settings: settings(), land: land)

    # Both were considered -- the cap bounds merges, not the decision -- and exactly one merged.
    assert first.candidates == 2
    assert first.merged == 1
    assert length(land_calls(calls)) == 1
    assert File.read!(ticket_path(dir, "SYM-7")) =~ "state: done\n"
    assert File.read!(ticket_path(dir, "SYM-8")) =~ "state: in-review\n"

    second = AutoLand.run_once(settings: settings(), land: land, reported: first.reported)

    assert second.merged == 1
    assert length(land_calls(calls)) == 2
    assert File.read!(ticket_path(dir, "SYM-8")) =~ "state: done\n"
  end

  test "one land operation is in flight at a time" do
    _dir = queue!(%{"SYM-7" => %{}, "SYM-8" => %{}})
    {:ok, counter} = Agent.start_link(fn -> %{in_flight: 0, most: 0, calls: 0} end)

    land = fn _pr_url, _branch ->
      Agent.update(counter, fn state ->
        in_flight = state.in_flight + 1
        %{state | in_flight: in_flight, most: max(state.most, in_flight), calls: state.calls + 1}
      end)

      Process.sleep(20)
      Agent.update(counter, &%{&1 | in_flight: &1.in_flight - 1})
      {:ok, %{number: 7, url: pr_url(7)}}
    end

    report = AutoLand.run_once(settings: settings(max_per_pass: 2), land: land)
    state = Agent.get(counter, & &1)

    assert report.merged == 2
    assert state.calls == 2
    assert state.most == 1
  end

  test "a pass that is still running is never started a second time" do
    parent = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    # The read blocks until this test releases it, which is what keeps the first pass in flight.
    tickets = fn _opts ->
      count = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(parent, {:read, count})

      receive do
        :release -> {:ok, []}
      end
    end

    start_supervised!({AutoLand, settings: settings(), tickets: tickets, interval_ms: 10, first_delay_ms: 0})

    assert_receive {:read, 1}, 1_000

    # The first pass is still inside its read: the next tick is armed only once a pass returns, and a
    # pass runs in the server's own process, so there is nothing else to read or land.
    refute_receive {:read, 2}, 150
    assert Agent.get(counter, & &1) == 1

    send(Process.whereis(AutoLand), :release)
    assert_receive {:read, 2}, 1_000
    send(Process.whereis(AutoLand), :release)
  end

  test "a land operation that raises is reported and the next ticket is still considered" do
    dir = queue!(%{"SYM-7" => %{}, "SYM-8" => %{}})

    land = fn target, _branch ->
      if String.ends_with?(target, "/7"), do: raise("boom"), else: {:ok, %{number: 8, url: target}}
    end

    log =
      capture_log(fn ->
        report = AutoLand.run_once(settings: settings(max_per_pass: 2), land: land)

        assert report.merged == 1
        assert report.reported["SYM-7"] == {:error, {:land_raised, "boom"}}
      end)

    assert log =~ "the land operation raised: boom"

    # The ticket that raised is untouched; the one after it was landed, so the pass survived.
    assert File.read!(ticket_path(dir, "SYM-7")) =~ "state: in-review\n"
    assert File.read!(ticket_path(dir, "SYM-8")) =~ "state: done\n"
  end

  test "an attempt that runs out of time is abandoned without writing anything" do
    dir = queue!(%{"SYM-7" => %{}})
    before = File.read!(ticket_path(dir, "SYM-7"))

    land = fn _pr_url, _branch ->
      Process.sleep(5_000)
      {:ok, %{number: 7, url: pr_url(7)}}
    end

    log =
      capture_log(fn ->
        report = AutoLand.run_once(settings: settings(timeout_ms: 50), land: land)

        assert report.merged == 0
        assert report.reported["SYM-7"] == {:error, :deadline_exceeded}
      end)

    assert log =~ "did not finish inside its deadline"
    assert File.read!(ticket_path(dir, "SYM-7")) == before
  end

  test "a tracker that cannot be read is said once and lands nothing" do
    {land, calls} = land_fake({:ok, %{number: 7, url: pr_url(7)}})
    unreadable = fn _opts -> {:error, :no_ticket_service_states} end

    log =
      capture_log(fn ->
        first = AutoLand.run_once(settings: settings(), tickets: unreadable, land: land)

        assert first.read == {:error, :no_ticket_service_states}
        assert first.merged == 0

        second =
          AutoLand.run_once(settings: settings(), tickets: unreadable, land: land, reported: first.reported)

        assert second.merged == 0
      end)

    assert land_calls(calls) == []
    assert occurrences(log, "the tracker could not be read") == 1
    assert log =~ "no_ticket_service_states"
  end

  # ---- a service-backed ticket: the recording goes through the tracker seam ---------------------

  test "a service-backed ticket is recorded through the tracker seam, not through a file queue" do
    # The deployment's tracker is the ticket service, and its writes are recorded by the injected
    # transport: the state first (it is what the scheduler reads), then one comment signed `auto-land`.
    # Nothing here writes a ticket file, because a service deployment has none.
    write_service_workflow!()
    {client, writes} = service_writes()
    {land, calls} = land_fake({:ok, %{number: 7, url: pr_url(7)}})

    report =
      AutoLand.run_once(
        settings: settings(),
        tickets: fn _opts -> {:ok, [service_ticket()]} end,
        client: client,
        land: land
      )

    assert report.candidates == 1
    assert report.merged == 1
    assert report.reported["SYM-7"] == :merged

    assert service_calls(writes) == [
             %{method: :patch, url: "http://127.0.0.1:4997/tickets/SYM-7", payload: %{"state" => "done"}},
             %{
               method: :post,
               url: "http://127.0.0.1:4997/tickets/SYM-7/comments",
               payload: %{"author" => "auto-land", "body" => landing_note()}
             }
           ]

    assert land_calls(calls) == [%{pr_url: pr_url(7), branch: "symphony/SYM-7"}]
  end

  test "a service that refuses the recording says so once, and the merge still counts" do
    # The merge happened and the ticket does not say so: reported in that order, and reported once --
    # the next pass must not try to land a pull request that is already gone.
    write_service_workflow!()
    client = fn _method, _url, _payload -> {:error, {:ticket_service_unreachable, %{reason: :econnrefused}}} end
    {land, _calls} = land_fake({:ok, %{number: 7, url: pr_url(7)}})

    log =
      capture_log(fn ->
        report =
          AutoLand.run_once(
            settings: settings(),
            tickets: fn _opts -> {:ok, [service_ticket()]} end,
            client: client,
            land: land
          )

        assert report.merged == 1
        assert match?({:unrecorded, _reason}, report.reported["SYM-7"])

        second =
          AutoLand.run_once(
            settings: settings(),
            tickets: fn _opts -> {:ok, [service_ticket()]} end,
            client: client,
            land: land,
            reported: report.reported
          )

        assert second.merged == 1
      end)

    assert occurrences(log, "auto-land: pull request was merged for SYM-7") == 1
    assert log =~ "the ticket service did not answer"
  end

  # ---- fixtures -------------------------------------------------------------------------------

  defp settings(overrides \\ []) do
    struct!(Config.Schema.AutoLand, Keyword.merge([enabled: true], overrides))
  end

  # A file queue with the tickets given, plus the workflow that declares it: the sweep's read (through
  # the deployment's configured tracker) and the host's writes (through `Janitor`) both come from this
  # one file, so what these tests exercise is the real seam rather than a stub of it.
  defp queue!(tickets) do
    root = Path.join(System.tmp_dir!(), "auto-land-#{System.unique_integer([:positive])}")
    dir = Path.join(root, "tickets")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(root) end)

    Enum.each(tickets, fn {id, overrides} ->
      File.write!(ticket_path(dir, id), ticket_text(id, overrides))
    end)

    workflow = Path.join(root, "WORKFLOW.md")
    File.write!(workflow, workflow_text(dir))
    Workflow.set_workflow_file_path(workflow)

    dir
  end

  defp ticket_path(dir, id), do: Path.join(dir, "#{id}.md")

  defp ticket_text(id, overrides) do
    [
      "---\n",
      "id: #{id}\n",
      "issue: 7\n",
      "title: \"Land the pull request unattended\"\n",
      "state: #{Map.get(overrides, :state, "in-review")}\n",
      "labels: #{Map.get(overrides, :labels, "[auto-land]")}\n",
      "priority: 2\n",
      line("branch_name: ", Map.get(overrides, :branch, "symphony/#{id}")),
      line("", Map.get(overrides, :links, link(id))),
      "---\n",
      @body
    ]
    |> Enum.join()
  end

  # The workflow's own terminal state is `done` and its first entry is the one a landing takes, so a
  # landing that moved a ticket elsewhere (or to an invented state) cannot pass.
  defp workflow_text(dir) do
    """
    ---
    tracker:
      kind: file
      provider:
        path: "#{slash(dir)}"
      active_states: [ready, in-progress]
      terminal_states: [done, cancelled]
    janitor:
      tickets_path: "#{slash(dir)}"
    ---

    Test prompt.
    """
  end

  # The pull request the janitor records on a ticket, in the shape `Ticket.add_link/4` writes: the
  # entry the land button reads and the sweep mirrors.
  defp link(id) do
    number = id |> String.replace(~r/\D/, "") |> String.to_integer()
    ~s(links: [{url: "#{pr_url(number)}", title: "PR ##{number}", kind: pr}])
  end

  # A ticket as the console's reader renders one for a service-backed deployment: the fields the sweep
  # judges, with the pull request and the branch the reader would have found.
  defp service_ticket do
    %{
      identifier: "SYM-7",
      id: "7",
      state: "in-review",
      labels: ["auto-land"],
      pr_url: pr_url(7),
      branch_name: "symphony/SYM-7"
    }
  end

  # The service deployment's write path, stubbed: one three-argument client, recording every call in an
  # agent -- the writes happen inside the sweep's own process, so they are read back rather than
  # received. No read is answered, because the sweep's read is injected as `:tickets` above.
  #
  # The answer is the two shapes the adapter reads out of a write: a PATCH answers the ticket with the
  # state it holds (which is what `write_state/3` reports), and a comment answers with its id and author.
  defp service_writes do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    client = fn method, url, payload ->
      Agent.update(agent, &(&1 ++ [%{method: method, url: url, payload: payload}]))
      {:ok, %{status: 200, body: write_answer(method)}}
    end

    {client, agent}
  end

  defp write_answer(:patch) do
    %{"id" => "7", "identifier" => "SYM-7", "state" => %{"name" => "done", "display_name" => "done"}}
  end

  defp write_answer(_post) do
    %{"id" => 11, "ticket_id" => 7, "author" => "auto-land", "body" => "landed"}
  end

  defp service_calls(agent), do: Agent.get(agent, & &1)

  # The service deployment's workflow: the tracker is the service, so the sweep's read and the writes
  # both belong to that kind. `provider.url` is a port nothing is listening on, and nothing here opens a
  # socket -- every request is answered by the injected client.
  defp write_service_workflow! do
    root = Path.join(System.tmp_dir!(), "auto-land-service-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    workflow = Path.join(root, "WORKFLOW.md")

    File.write!(workflow, """
    ---
    tracker:
      kind: ticket_service
      provider:
        url: "http://127.0.0.1:4997"
      active_states: [ready, in-progress]
      terminal_states: [done, cancelled]
    ---

    Test prompt.
    """)

    Workflow.set_workflow_file_path(workflow)
    :ok
  end

  # The landing the sweep writes on the ticket, in the page's own words.
  defp landing_note do
    "auto-land landed pull request 7 (#{pr_url(7)}). Land verdict: ok (exit 0). " <>
      "Result: squash-merged with the branch deleted. This ticket was moved to done."
  end

  defp pr_url(number), do: "https://github.com/me/repo/pull/#{number}"

  defp slash(path), do: String.replace(path, "\\", "/")

  defp line(_prefix, ""), do: ""
  defp line(prefix, value), do: prefix <> value <> "\n"

  # The land operation, replaced: it records what it was handed, which is how "no pull request was
  # invented" is checked rather than asserted, and it answers what the caller told it to.
  defp land_fake(reply) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    fake = fn pr_url, branch ->
      Agent.update(agent, &(&1 ++ [%{pr_url: pr_url, branch: branch}]))
      reply
    end

    {fake, agent}
  end

  defp land_calls(agent), do: Agent.get(agent, & &1)

  defp occurrences(text, needle) do
    text |> String.split(needle) |> length() |> Kernel.-(1)
  end
end
