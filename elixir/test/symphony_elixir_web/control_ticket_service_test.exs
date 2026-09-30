defmodule SymphonyElixirWeb.ControlTicketServiceTest do
  # async: false -- every test moves the workflow file path (global state), points the tracker at a
  # service URL and starts the endpoint under test with its own injected transport.
  use ExUnit.Case, async: false

  alias SymphonyElixir.Workflow

  # Before `import Phoenix.ConnTest`: its helpers resolve the endpoint from this attribute.
  @endpoint SymphonyElixirWeb.Endpoint

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  # Deliberately not 4020, where a real ticket service may be running on this machine: every test here
  # injects the transport, and a stub that missed would then reach nothing at all rather than reach
  # something that is not part of the test.
  @service_url "http://127.0.0.1:4997"
  @list_url @service_url <> "/tickets?state=ready&state=in-progress&state=done&state=cancelled"

  setup do
    previous = Workflow.workflow_file_path()
    on_exit(fn -> Workflow.set_workflow_file_path(previous) end)

    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    root = Path.join(System.tmp_dir!(), "control-ticket-service-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, root: root}
  end

  test "the board lists the service's tickets with their state, labels, blockers and branch",
       %{root: root} do
    write_workflow!(root, service_tracker())
    start_endpoint(ticket_reader_client: service_client(service_tickets()))

    {:ok, _view, html} = live(build_conn(), "/control/tickets")

    assert html =~ "SYM-7"
    assert html =~ "Cache the git roots lookup"
    assert html =~ "SYM-8"
    assert html =~ "Ship the board"
    assert html =~ ~s(href="/control/tickets/SYM-7")

    # The list fields a tracker shows, from the one list read the service answers.
    assert html =~ "perf, windows"
    assert html =~ "operator"
    assert html =~ "SYM-8 (in-progress)"
    assert html =~ "symphony/SYM-7"
    assert html =~ "ready 1"
    assert html =~ "in-progress 1"

    # Not an empty board: the service answered with two tickets.
    refute html =~ "No ticket matches these filters."
  end

  test "one ticket shows the description and the comments the service holds, in order, with their authors",
       %{root: root} do
    write_workflow!(root, service_tracker())
    start_endpoint(ticket_reader_client: service_client(service_tickets()))

    {:ok, _view, html} = live(build_conn(), "/control/tickets/SYM-7")

    assert html =~ "Cache the git roots lookup"
    assert html =~ "Cache the git roots lookup per run and add a test."

    # The deep read's own answer: the comments, oldest first, each with its author, its time and its id.
    assert html =~ "The comments the ticket service holds for this ticket"
    assert html =~ "octocat"
    assert html =~ "local-agent"
    assert html =~ "Please also cover the Windows path."
    assert html =~ "Covered in the branch."
    assert html =~ "1001"
    assert html =~ "1002"
    assert html =~ "2025-10-09T08:53:30.000Z"

    assert at(html, "Please also cover the Windows path.") < at(html, "Covered in the branch.")

    # The rest of the ticket, from the same answer.
    assert html =~ "perf, windows"
    assert html =~ "symphony/SYM-7"
    assert html =~ ~s(href="/control/tickets/SYM-8")
    assert html =~ "in-progress"

    # Never an empty-looking page: the ticket is not a file ticket and the page says where it came from.
    assert html =~ "read from the ticket service, not from a file"
    refute html =~ "No comment on this ticket yet."
    refute html =~ "not found beside the queue"
  end

  test "a service ticket that holds no description says so instead of showing an empty panel",
       %{root: root} do
    write_workflow!(root, service_tracker())

    blank = service_row(%{"description" => nil, "comments" => []})
    start_endpoint(ticket_reader_client: service_client([blank], blank))

    {:ok, _view, html} = live(build_conn(), "/control/tickets/SYM-7")

    assert html =~ "The ticket service holds no description for this ticket."
    refute html =~ "code-panel"

    # The ticket is still readable, and the page says why there are no comments rather than leaving the
    # panel blank: the deep read answered, and the answer was "no comments".
    assert html =~ "No comment on this ticket yet."
    assert html =~ "perf, windows"
  end

  test "a ticket the service does not hold says so instead of claiming it has no description",
       %{root: root} do
    write_workflow!(root, service_tracker())

    not_found = fn
      "http://127.0.0.1:4997/tickets/SYM-404" ->
        {:ok,
         %{
           status: 404,
           body: %{"error" => %{"code" => "not_found", "message" => "no ticket with identifier \"SYM-404\""}}
         }}

      other ->
        unexpected(other)
    end

    start_endpoint(ticket_reader_client: not_found)

    {:ok, _view, html} = live(build_conn(), "/control/tickets/SYM-404")

    assert html =~ "No ticket with this identifier is in the queue."
    refute html =~ "No comment on this ticket yet."
    refute html =~ "code-panel"
  end

  test "a service answer that is not a ticket renders its reason rather than an empty ticket",
       %{root: root} do
    write_workflow!(root, service_tracker())
    start_endpoint(ticket_reader_client: answering_html())

    {:ok, _view, html} = live(build_conn(), "/control/tickets/SYM-7")

    assert html =~ "This ticket could not be read"
    assert html =~ "the ticket service answered something that is not a ticket"
    assert html =~ "not a ticket"

    # Never an empty ticket: no description panel, no comments panel, and no claim that the ticket has
    # no description.
    refute html =~ "code-panel"
    refute html =~ "No comment on this ticket yet."
    refute html =~ "No ticket with this identifier is in the queue."
  end

  test "a service that refuses the connection renders the refusal rather than an empty ticket",
       %{root: root} do
    write_workflow!(root, service_tracker())
    start_endpoint(ticket_reader_client: refusing())

    {:ok, _view, html} = live(build_conn(), "/control/tickets/SYM-7")

    assert html =~ "This ticket could not be read"
    assert html =~ "the ticket service did not answer"
    assert html =~ "econnrefused"
    assert html =~ "ticket_service_unreachable"
    refute html =~ "No ticket with this identifier is in the queue."
  end

  test "a board whose service is down renders the reason, not an empty board", %{root: root} do
    write_workflow!(root, service_tracker())
    start_endpoint(ticket_reader_client: refusing())

    {:ok, _view, html} = live(build_conn(), "/control/tickets")

    assert html =~ "The ticket queue could not be read"
    assert html =~ "the ticket service did not answer"
    refute html =~ "No ticket matches these filters."
  end

  test "a workflow that declares no state does not become an empty board", %{root: root} do
    write_workflow!(root, service_tracker("active_states: []", "terminal_states: []"))
    start_endpoint(ticket_reader_client: fn url -> unexpected(url) end)

    {:ok, _view, html} = live(build_conn(), "/control/tickets")

    assert html =~ "the workflow declares no active_states or terminal_states"
    assert html =~ "no_ticket_service_states"
    refute html =~ "No ticket matches these filters."
  end

  test "a tracker kind this console cannot read says which kind, for the board and for one ticket",
       %{root: root} do
    # `memory` is a real tracker here and it loads without credentials, which is what makes it the
    # honest representative: a kind the console has no deep read for, configured and running.
    write_workflow!(root, other_tracker("memory"))
    start_endpoint(ticket_reader_client: fn url -> unexpected(url) end)

    {:ok, _board, board} = live(build_conn(), "/control/tickets")

    assert board =~ "The ticket queue could not be read"
    # The kind is `inspect`ed into the sentence, so its quotes arrive HTML-escaped.
    assert board =~ "configured as &quot;memory&quot;"
    assert board =~ "ticket_kind_not_readable"
    refute board =~ "No ticket matches these filters."

    {:ok, _view, html} = live(build_conn(), "/control/tickets/SYM-7")

    # The explicit message, and never an empty-looking ticket: no body panel, no comments panel, and no
    # claim that this ticket is missing or has no description.
    assert html =~ "This ticket could not be read"
    assert html =~ "configured as &quot;memory&quot;"
    refute html =~ "code-panel"
    refute html =~ "No comment on this ticket yet."
    refute html =~ "No ticket with this identifier is in the queue."

    # Still a page, not a crash.
    assert html =~ "Symphony Tracker"
  end

  test "a file tracker whose page keeps reading files is untouched by the service path", %{root: root} do
    # The same page, the same seam, the other kind: nothing about the service client is reached.
    tickets = Path.join(root, "tickets")
    File.mkdir_p!(tickets)

    File.write!(Path.join(tickets, "SYM-7.md"), """
    ---
    id: SYM-7
    title: "A file ticket"
    state: ready
    ---

    From the file, not from the service.
    """)

    write_workflow!(root, file_tracker(tickets))
    start_endpoint(ticket_reader_client: fn url -> unexpected(url) end)

    {:ok, _view, html} = live(build_conn(), "/control/tickets/SYM-7")

    assert html =~ "From the file, not from the service."
    assert html =~ Path.join(Path.expand(tickets), "SYM-7.md")
    refute html =~ "read from the ticket service, not from a file"
  end

  # A client that answers only the URLs this page is supposed to ask for, and turns anything else into
  # a visible error: a wrong URL is a failing assertion, not a silent empty page.
  defp service_client(tickets, deep \\ nil) do
    deep = deep || deep_row()

    fn
      @list_url ->
        {:ok, %{status: 200, body: %{"tickets" => tickets}}}

      "http://127.0.0.1:4997/tickets/SYM-7" ->
        {:ok, %{status: 200, body: deep}}

      other ->
        unexpected(other)
    end
  end

  defp unexpected(url) do
    {:ok, %{status: 500, body: %{"error" => %{"message" => "unexpected request: #{url}"}}}}
  end

  # What a service on a port nothing is listening on answers, in the words `TicketService.get/1` uses.
  defp refusing do
    fn _url -> {:error, {:ticket_service_unreachable, %{reason: :econnrefused}}} end
  end

  defp answering_html do
    fn _url -> {:ok, %{status: 200, body: "<html>not a ticket</html>"}} end
  end

  # The list read: two rows, shaped exactly as `SymphonyTicketsWeb.Presenter.ticket/1` renders them.
  defp service_tickets do
    [
      service_row(%{
        "blockers" => [live_blocker("SYM-8", "in-progress")],
        "blocked_by" => ["SYM-8"]
      }),
      service_row(%{
        "id" => 8,
        "identifier" => "SYM-8",
        "title" => "Ship the board",
        "description" => "Body text of the second ticket.\n",
        "state" => %{"type" => "started", "name" => "in-progress", "display_name" => "in-progress"},
        "priority" => 1,
        "labels" => ["ui"],
        "branch_name" => "symphony/SYM-8",
        "comments" => []
      })
    ]
  end

  defp service_row(overrides) do
    Map.merge(
      %{
        "id" => 7,
        "identifier" => "SYM-7",
        "title" => "Cache the git roots lookup",
        "description" => "Cache the git roots lookup per run and add a test.\n",
        "state" => %{"type" => "unstarted", "name" => "ready", "display_name" => "ready"},
        "priority" => 2,
        "assignee" => "operator",
        "branch_name" => "symphony/SYM-7",
        "url" => "",
        "labels" => ["perf", "windows"],
        "blocked_by" => [],
        "blockers" => [],
        "attachments" => [],
        "comments" => [],
        "dispatchable" => true,
        "created_at" => 1_760_000_000_000,
        "updated_at" => 1_760_000_060_000
      },
      overrides
    )
  end

  # The deep read: the same row with the comments the list endpoint does not read.
  defp deep_row do
    service_row(%{
      "blockers" => [live_blocker("SYM-8", "in-progress")],
      "blocked_by" => ["SYM-8"],
      "comments" => [
        comment(1001, "octocat", "Please also cover the Windows path.", 1_760_000_010_000),
        comment(1002, "local-agent", "Covered in the branch.", 1_760_000_020_000)
      ]
    })
  end

  defp comment(id, author, body, created_at) do
    %{
      "id" => id,
      "ticket_id" => 7,
      "parent_id" => nil,
      "author" => author,
      "body" => body,
      "created_at" => created_at
    }
  end

  defp live_blocker(identifier, state) do
    %{
      "blocker_identifier" => identifier,
      "blocker_state" => %{"type" => "started", "name" => state, "display_name" => state},
      "resolved" => false
    }
  end

  # Where a piece of the page's text is, so "in order" can be asserted as an order rather than as two
  # independent presences.
  defp at(html, text) do
    case :binary.match(html, text) do
      {position, _length} -> position
      :nomatch -> flunk("the page does not contain #{inspect(text)}")
    end
  end

  defp start_endpoint(overrides) do
    config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp write_workflow!(root, tracker) do
    path = Path.join(root, "WORKFLOW.md")

    File.write!(path, """
    ---
    #{tracker}
    ---

    Test prompt.
    """)

    Workflow.set_workflow_file_path(path)
    :ok
  end

  defp service_tracker(
         active \\ "active_states: [ready, in-progress]",
         terminal \\ "terminal_states: [done, cancelled]"
       ) do
    """
    tracker:
      kind: ticket_service
      provider:
        url: "#{@service_url}"
      #{active}
      #{terminal}
    """
  end

  defp file_tracker(tickets) do
    """
    tracker:
      kind: file
      provider:
        path: "#{slash(tickets)}"
      active_states: [ready, in-progress]
      terminal_states: [done, cancelled]
    """
  end

  defp other_tracker(kind) do
    """
    tracker:
      kind: #{kind}
      active_states: [ready]
      terminal_states: [done]
    """
  end

  defp slash(path), do: String.replace(path, "\\", "/")
end
