defmodule SymphonyElixirWeb.ControlTicketActionsTest do
  # async: false -- every test moves the workflow file path, points a queue at a temp directory and
  # starts the endpoint under test.
  use ExUnit.Case, async: false

  alias SymphonyElixir.Workflow

  # Before `import Phoenix.ConnTest`: its helpers resolve the endpoint from this attribute.
  @endpoint SymphonyElixirWeb.Endpoint

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  # Bytes that are not valid UTF-8, spelled in ASCII so this file stays ASCII: `0xE3 0x80` opens a
  # three-byte sequence and `0x3F` is not its third byte. This is the shape a lossy Windows PowerShell
  # write leaves behind (`SymphonyElixir.Janitor.TicketWriteTest` measures that on a Chinese ticket).
  @damaged_tail <<0xE3, 0x80, 0x3F, 0x0A>>

  # The body deliberately repeats the front matter's `state: ready` line. A writer that replaced every
  # match -- which is what the PowerShell original did -- would change this line too, and the state
  # tests below compare the whole file against a single-occurrence replacement, so that cannot pass.
  @body "Ship the picker and keep every other byte.\n\n" <>
          "## Notes\n\nstate: ready is what the front matter said; this line must not be the one that changes.\n"

  setup do
    previous = Workflow.workflow_file_path()
    on_exit(fn -> Workflow.set_workflow_file_path(previous) end)

    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    root = Path.join(System.tmp_dir!(), "control-ticket-actions-#{System.unique_integer([:positive])}")
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

    path = write_ticket!(tickets, "SYM-7", ticket_text("ready"))
    write_workflow!(root, tickets)
    start_test_endpoint()

    {:ok, tickets: tickets, path: path, root: root, registry: registry}
  end

  test "the ticket page offers the workflow's declared states, the current one selected, and a comment box",
       %{path: path} do
    before = File.read!(path)
    {:ok, view, html} = live(build_conn(), "/control/tickets/SYM-7")

    # The workflow's own vocabulary -- the two lists the scheduler dispatches from -- and nothing else.
    for state <- ["ready", "in-progress", "done", "cancelled"] do
      assert html =~ ~s(<option value="#{state}")
    end

    refute html =~ ~s(<option value="shipped")

    # The ticket's own state is the one the control opens on.
    assert view
           |> element(~s(select[name="state"] option[value="ready"][selected]))
           |> render() =~ "ready"

    # The comment box, and the fact that it is signed as the operator rather than as the agent.
    assert html =~ ~s(name="comment")
    assert html =~ "Add a comment"
    assert html =~ "operator"

    # Nothing is written by mounting or by rendering: the file is the byte it was.
    assert File.read!(path) == before
    assert render(view) =~ "SYM-7"
    assert File.read!(path) == before
  end

  test "a state submit writes the state to the ticket file, and the page shows it without a refresh",
       %{path: path} do
    before = File.read!(path)
    {:ok, view, _html} = live(build_conn(), "/control/tickets/SYM-7")

    html =
      view
      |> form("form[phx-submit=set_state]", state: "in-progress")
      |> render_submit()

    after_text = File.read!(path)

    # The file: one front-matter key, and every other byte the byte it was -- including the body line
    # that repeats `state: ready`, which a replace-every-match writer would have changed too (hence
    # `global: false`: the expectation is exactly one occurrence changed).
    assert after_text == String.replace(before, "state: ready", "state: in-progress", global: false)
    assert after_text =~ "state: ready is what the front matter said"

    # The page: re-read after the write, so the new state is on it without a manual refresh.
    assert html =~ "state-badge-active"
    refute html =~ "state-badge-warning"
    assert render(view) =~ "in-progress"
  end

  test "a comment submit appends an operator-attributed entry to the ticket, and the page shows it",
       %{path: path} do
    before = File.read!(path)
    {:ok, view, _html} = live(build_conn(), "/control/tickets/SYM-7")

    comment = "Please also cover the Windows path."

    html =
      view
      |> form("form[phx-submit=comment]", comment: comment)
      |> render_submit()

    after_text = File.read!(path)

    # Appended, never rewritten: the ticket starts with the bytes it had, and the entry is in the
    # reserved section under the id the host assigns to the entries it did not mirror in.
    assert String.starts_with?(after_text, before)
    assert after_text =~ "## Discussion"
    assert after_text =~ "- **operator** ("
    assert after_text =~ "id=local-1"
    assert after_text =~ comment
    refute after_text =~ "- **agent** ("

    # The page: the new comment is in the table, with its author and its id, without a refresh.
    assert html =~ comment
    assert html =~ "local-1"
    assert render(view) =~ comment
  end

  test "neither control writes anything that was not submitted", %{path: path} do
    before = File.read!(path)
    {:ok, view, _html} = live(build_conn(), "/control/tickets/SYM-7")

    # A refresh reads the ticket again and writes nothing either.
    html = view |> element("button[phx-click=refresh]") |> render_click()

    assert html =~ "SYM-7"
    assert File.read!(path) == before
  end

  test "a state the workflow does not declare is refused in the page and writes nothing", %{path: path} do
    before = File.read!(path)
    {:ok, view, _html} = live(build_conn(), "/control/tickets/SYM-7")

    # Sent as a form submit rather than through `form/3`: the select only offers the declared states, so
    # this is the crafted request the view has to refuse rather than a state a person could pick.
    html = render_submit(view, "set_state", %{"state" => "shipped"})

    assert html =~ "That change was not written"
    assert html =~ "The state shipped is not one of the states this workflow declares"
    assert html =~ "nothing was written"
    assert File.read!(path) == before
  end

  test "an empty comment is refused in the page and writes nothing", %{path: path} do
    before = File.read!(path)
    {:ok, view, _html} = live(build_conn(), "/control/tickets/SYM-7")

    html = render_submit(view, "comment", %{"comment" => "   "})

    assert html =~ "That change was not written"
    assert html =~ "The comment is empty"
    assert File.read!(path) == before
    refute File.read!(path) =~ "## Discussion"
  end

  test "a write to a ticket whose bytes are not UTF-8 is refused, with the write path's own reason",
       %{path: path} do
    {:ok, view, html} = live(build_conn(), "/control/tickets/SYM-7")
    assert html =~ "Cache the git roots lookup"

    # The ticket is damaged *after* the page has read it, which is the case the refusal exists for: a
    # reader can still have a good copy while the file on disk is broken.
    damaged = "---\nid: SYM-7\nstate: ready\n---\n" <> "body\n" <> @damaged_tail
    File.write!(path, damaged)
    refute String.valid?(damaged)

    state_html = view |> form("form[phx-submit=set_state]", state: "in-progress") |> render_submit()

    assert state_html =~ "That change was not written"
    # The reason the host returned, not a paraphrase of it.
    assert state_html =~ "ticket_not_utf8"
    assert File.read!(path) == damaged

    comment_html = view |> form("form[phx-submit=comment]", comment: "hello") |> render_submit()

    assert comment_html =~ "ticket_not_utf8"
    assert File.read!(path) == damaged

    # Still a page: the ticket it had read is still shown, with the reason both writes were refused.
    assert render(view) =~ "Cache the git roots lookup"
  end

  test "a write while reading another project's queue lands in that project's files, not this instance's",
       %{path: path, registry: registry, root: root} do
    queue = other_project!(registry, root)
    other_path = Path.join(queue, "OTH-1.md")
    other_before = File.read!(other_path)
    before = File.read!(path)

    {:ok, view, html} = live(build_conn(), "/control/tickets/OTH-1?project=other")

    # That project's own vocabulary, not this instance's.
    for state <- ["queued", "doing", "finished"] do
      assert html =~ ~s(<option value="#{state}")
    end

    refute html =~ ~s(<option value="ready")

    view
    |> form("form[phx-submit=set_state]", state: "finished")
    |> render_submit()

    assert File.read!(other_path) == String.replace(other_before, "state: queued", "state: finished")

    # And this instance's own queue -- which has a ticket of its own -- is untouched, byte for byte.
    assert File.read!(path) == before
  end

  # A second project in the registry, with its own queue directory, its own state vocabulary and one
  # ticket in it. Written with the real parser in mind: `Projects` parses this file exactly as it parses
  # a running instance's.
  defp other_project!(registry, root) do
    queue = Path.join(root, "other-tickets")
    File.mkdir_p!(queue)

    # Same fixture rule as `ticket_text/1`: no blank line directly under the closing delimiter, so the
    # comparison below is about the state key and nothing else.
    write_ticket!(
      queue,
      "OTH-1",
      "---\nid: OTH-1\ntitle: \"Other project ticket\"\nstate: queued\n---\nBody text of the other project.\n"
    )

    File.write!(Path.join(registry, "other.md"), """
    ---
    tracker:
      kind: file
      provider:
        path: "#{slash(queue)}"
      active_states: [queued, doing]
      terminal_states: [finished]
    janitor:
      tickets_path: "#{slash(queue)}"
    ---

    Work on the other project.
    """)

    queue
  end

  defp ticket_text(state) do
    # The body starts directly after the closing delimiter, which is the shape the host's round trip
    # preserves byte for byte: `Ticket.split/1` owns the newlines that follow `---`, so a fixture with a
    # blank line there would be measuring that delimiter (it collapses one blank line) instead of the
    # one-key write these tests are about.
    "---\n" <>
      "id: SYM-7\n" <>
      "issue: 7\n" <>
      "title: \"Cache the git roots lookup\"\n" <>
      "state: #{state}\n" <>
      "labels: [perf, windows]\n" <>
      "priority: 2\n" <>
      "assignee_id: lhl20\n" <>
      "branch_name: symphony/SYM-7\n" <>
      "---\n" <> @body
  end

  defp write_ticket!(dir, id, text) do
    path = Path.join(dir, "#{id}.md")
    File.write!(path, text)
    path
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

  defp start_test_endpoint do
    config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end
end
