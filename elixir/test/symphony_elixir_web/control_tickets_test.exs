defmodule SymphonyElixirWeb.ControlTicketsTest do
  # async: false -- points the workflow at a ticket directory (that path is global state) and starts
  # the endpoint under test.
  use ExUnit.Case, async: false

  alias SymphonyElixir.Workflow

  # Before `import Phoenix.ConnTest`: its helpers resolve the endpoint from this attribute.
  @endpoint SymphonyElixirWeb.Endpoint

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  setup do
    previous = Workflow.workflow_file_path()
    on_exit(fn -> Workflow.set_workflow_file_path(previous) end)

    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    root = Path.join(System.tmp_dir!(), "control-tickets-#{System.unique_integer([:positive])}")
    tickets = Path.join(root, "tickets")
    File.mkdir_p!(tickets)
    on_exit(fn -> File.rm_rf(root) end)

    write_ticket!(tickets, "SYM-7", """
    ---
    id: SYM-7
    issue: 7
    title: "Cache the git roots lookup"
    state: ready
    labels: [perf, windows]
    priority: 2
    assignee_id: lhl20
    blocked_by: [SYM-8]
    branch_name: symphony/SYM-7
    links: [{url: "https://github.com/openai/symphony/pull/42", title: "PR #42", kind: pr}]
    ---

    Cache the git roots lookup per run and add a test.

    ## Discussion

    - **octocat** (2026-01-02T03:04:05Z, id=1001): Please also cover the Windows path.
    - **local-agent** (2026-01-02T04:00:00Z, id=local-1): Covered in the branch.
    """)

    write_ticket!(tickets, "SYM-8", """
    ---
    id: SYM-8
    issue: 8
    title: "Ship the board"
    state: done
    labels: [ui]
    priority: 1
    assignee_id: someone
    branch_name: symphony/SYM-8
    ---

    Body text of the second ticket.
    """)

    write_workflow!(root, tickets)
    start_endpoint()

    {:ok, tickets: tickets}
  end

  test "the board lists tickets with their state, labels, blockers, branch and pull request" do
    {:ok, view, html} = live(build_conn(), "/control/tickets")

    assert html =~ "SYM-7"
    assert html =~ "Cache the git roots lookup"
    assert html =~ "Ship the board"
    assert html =~ ~s(href="/control/tickets/SYM-7")
    assert html =~ ~s(href="/control/tickets/SYM-8")

    # State, priority, labels, assignee, blockers, branch and the recorded pull request.
    assert html =~ "state-badge-warning"
    assert html =~ "perf, windows"
    assert html =~ "lhl20"
    assert html =~ "SYM-8 (done)"
    assert html =~ "symphony/SYM-7"
    assert html =~ ~s(href="https://github.com/openai/symphony/pull/42")

    # The state counts a tracker shows above the list.
    assert html =~ "ready 1"
    assert html =~ "done 1"

    # And the list is still there after a filter round trip.
    assert render(view) =~ "SYM-7"
  end

  test "the board filters by label, state, assignee and priority" do
    {:ok, view, html} = live(build_conn(), "/control/tickets")

    assert html =~ ~s(href="/control/tickets/SYM-7")
    assert html =~ ~s(href="/control/tickets/SYM-8")

    label_filtered = filter_change(view, %{"label" => "ui"})
    refute label_filtered =~ ~s(href="/control/tickets/SYM-7")
    assert label_filtered =~ ~s(href="/control/tickets/SYM-8")

    state_filtered = filter_change(view, %{"state" => "ready"})
    assert state_filtered =~ ~s(href="/control/tickets/SYM-7")
    refute state_filtered =~ ~s(href="/control/tickets/SYM-8")

    assignee_filtered = filter_change(view, %{"assignee" => "someone"})
    refute assignee_filtered =~ ~s(href="/control/tickets/SYM-7")
    assert assignee_filtered =~ ~s(href="/control/tickets/SYM-8")

    priority_filtered = filter_change(view, %{"priority" => "2"})
    assert priority_filtered =~ ~s(href="/control/tickets/SYM-7")
    refute priority_filtered =~ ~s(href="/control/tickets/SYM-8")

    assert filter_change(view, %{"label" => "nope"}) =~ "No ticket matches these filters."
  end

  test "one ticket shows its description, comments, links, branch and blockers" do
    {:ok, _view, html} = live(build_conn(), "/control/tickets/SYM-7")

    assert html =~ "Cache the git roots lookup"
    assert html =~ "Cache the git roots lookup per run and add a test."
    assert html =~ "symphony/SYM-7"
    assert html =~ ~s(href="https://github.com/openai/symphony/pull/42")
    assert html =~ "octocat"
    assert html =~ "1001"
    assert html =~ "local-1"
    assert html =~ "Please also cover the Windows path."
    assert html =~ ~s(href="/control/tickets/SYM-8")
    assert html =~ "done"
  end

  test "an identifier that is not in the queue says so instead of crashing" do
    {:ok, view, html} = live(build_conn(), "/control/tickets/SYM-404")

    assert html =~ "No ticket with this identifier is in the queue."
    assert render(view) =~ "back to the board"
  end

  # A browser sends every field of the form on `phx-change`, so a filter is always the whole set with
  # one entry changed. Saying that here keeps one filter's assertion from depending on the last one.
  defp filter_change(view, params) do
    filters =
      %{"state" => "any", "label" => "any", "assignee" => "any", "priority" => "any", "sort" => "identifier"}
      |> Map.merge(params)

    render_change(form(view, "form"), %{"filters" => filters})
  end

  defp write_ticket!(dir, id, text) do
    File.write!(Path.join(dir, "#{id}.md"), text)
  end

  defp write_workflow!(root, tickets) do
    path = Path.join(root, "WORKFLOW.md")

    File.write!(path, """
    ---
    tracker:
      kind: file
      provider:
        path: "#{slash(tickets)}"
      active_states: [ready, in-progress]
      terminal_states: [done, cancelled]
    janitor:
      tickets_path: "#{slash(tickets)}"
    ---

    Test prompt.
    """)

    Workflow.set_workflow_file_path(path)
    :ok
  end

  defp slash(path), do: String.replace(path, "\\", "/")

  defp start_endpoint do
    config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end
end
