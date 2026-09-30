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

    # The registry this page reads another project's queue from. `Projects.registry_dir/0` expands it,
    # so a `Path.join(System.tmp_dir!(), ...)` value is found even though `Path.wildcard/1` is strict
    # about mixed separators.
    registry = Path.join(root, "projects")
    File.mkdir_p!(registry)
    previous_registry = Application.get_env(:symphony_elixir, :projects_dir)
    Application.put_env(:symphony_elixir, :projects_dir, registry)

    on_exit(fn ->
      if previous_registry,
        do: Application.put_env(:symphony_elixir, :projects_dir, previous_registry),
        else: Application.delete_env(:symphony_elixir, :projects_dir)
    end)

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

    {:ok, tickets: tickets, root: root, registry: registry}
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

  test "the project parameter shows another registry project's queue, not this instance's",
       %{registry: registry, root: root} do
    _other = other_project!(registry, root)

    {:ok, _view, html} = live(build_conn(), "/control/tickets?project=other")

    # The other project's tickets, read from its own workflow file's queue.
    assert html =~ "OTH-1"
    assert html =~ "Other project board"
    assert html =~ "in-progress 1"

    # And not this instance's, which is a different directory with tickets in it.
    refute html =~ "SYM-7"
    refute html =~ "SYM-8"

    # The parameter travels with the link, so opening a ticket keeps reading the same project.
    assert html =~ ~s(href="/control/tickets/OTH-1?project=other")
  end

  test "without the parameter the board is still this instance's own queue",
       %{registry: registry, root: root} do
    _other = other_project!(registry, root)

    {:ok, _view, html} = live(build_conn(), "/control/tickets")

    assert html =~ "SYM-7"
    refute html =~ "OTH-1"
    assert html =~ ~s(href="/control/tickets/SYM-7")
  end

  test "one ticket of another project shows its body, comments and links, and keeps the parameter",
       %{registry: registry, root: root} do
    _other = other_project!(registry, root)

    {:ok, _view, html} = live(build_conn(), "/control/tickets/OTH-2?project=other")

    assert html =~ "Other project ticket"
    assert html =~ "Body text of the other project."
    assert html =~ "A comment on the other project."
    assert html =~ ~s(href="https://github.com/acme/other/pull/9")

    # The board it goes back to, and the blocker it links to, are in the same project.
    assert html =~ ~s(href="/control/tickets?project=other")
    assert html =~ ~s(href="/control/tickets/OTH-3?project=other")

    # Nothing from this instance's queue is mixed in.
    refute html =~ "SYM-7"
  end

  test "an unknown project renders the reason and keeps the page alive" do
    {:ok, view, html} = live(build_conn(), "/control/tickets?project=nope")

    assert html =~ "there is no project named nope in the registry"
    assert html =~ "The ticket queue could not be read"
    # Still a page: the error card, not an empty board and not a crash.
    refute html =~ "No ticket matches these filters."
    refute html =~ "Board"
    assert render(view) =~ "Symphony Tracker"
  end

  test "a ticket page for an unknown project says so instead of claiming the ticket is missing" do
    {:ok, _view, html} = live(build_conn(), "/control/tickets/SYM-7?project=nope")

    assert html =~ "there is no project named nope in the registry"
    refute html =~ "No ticket with this identifier is in the queue."
  end

  test "a project whose workflow file cannot be read renders the reason, not an empty board",
       %{registry: registry} do
    File.write!(Path.join(registry, "garbage.md"), "---\nnot: [a, map\n---\n\nnope\n")

    {:ok, view, html} = live(build_conn(), "/control/tickets?project=garbage")

    assert html =~ "the workflow file of project garbage cannot be read"
    assert html =~ "does not parse"
    refute html =~ "No ticket matches these filters."
    assert render(view) =~ "The ticket queue could not be read"
  end

  test "a project whose workflow file is unreadable renders the reason, not an empty board",
       %{registry: registry} do
    # A directory where the registry expects a file: the file is listed, and reading it is `eisdir`.
    File.mkdir_p!(Path.join(registry, "unreadable.md"))

    {:ok, view, html} = live(build_conn(), "/control/tickets?project=unreadable")

    assert html =~ "the workflow file of project unreadable cannot be read"
    refute html =~ "No ticket matches these filters."
    assert render(view) =~ "The ticket queue could not be read"
  end

  # A second project in the registry, with its own queue directory and two tickets in it. Written with
  # the real parser in mind: `Projects` parses this file exactly as it parses a running instance's.
  defp other_project!(registry, root) do
    queue = Path.join(root, "other-tickets")
    File.mkdir_p!(queue)

    write_ticket!(queue, "OTH-1", """
    ---
    id: OTH-1
    title: "Other project board"
    state: ready
    labels: [other]
    priority: 3
    ---

    Body text of the other project.
    """)

    write_ticket!(queue, "OTH-2", """
    ---
    id: OTH-2
    title: "Other project ticket"
    state: in-progress
    labels: [other]
    priority: 1
    blocked_by: [OTH-3]
    branch_name: other/OTH-2
    links: [{url: "https://github.com/acme/other/pull/9", title: "PR #9", kind: pr}]
    ---

    Body text of the other project.

    ## Discussion

    - **octocat** (2026-02-01T00:00:00Z, id=2001): A comment on the other project.
    """)

    File.write!(Path.join(registry, "other.md"), """
    ---
    server:
      host: 127.0.0.1
      port: 4119
    tracker:
      kind: file
      provider:
        path: "#{slash(queue)}"
      active_states: [ready, in-progress]
      terminal_states: [done, cancelled]
    janitor:
      enabled: false
      interval_ms: 30000
      issues_repo: acme/other-issues
      tickets_repo: acme/other-tickets
      tickets_path: "#{slash(queue)}"
    workspace:
      root: "#{slash(Path.join(root, "other-workspace"))}"
    agent:
      backend: codex
    ---

    Work on the other project.
    """)

    queue
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
