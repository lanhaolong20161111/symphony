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

  # ---- the page's write path, over the service ---------------------------------

  test "the state control PATCHes the service, and the page shows the state it answered",
       %{root: root} do
    write_workflow!(root, service_tracker())

    # One client answers both directions of the page's transport, which is what the endpoint config
    # carries: the reads, and the write the seam hands the adapter when the form is submitted. This one
    # remembers the state it was asked to write, so the re-read after the write answers what the service
    # would answer.
    {client, writes} = stateful_service_client()
    start_endpoint(ticket_reader_client: client)
    {:ok, view, _html} = live(build_conn(), "/control/tickets/SYM-7")

    html = view |> form("form[phx-submit=set_state]", state: "done") |> render_submit()

    # What would have gone on the wire: the service's own PATCH, at the identifier's URL -- and nothing
    # else, so no second request was made behind the page's back.
    assert service_writes(writes) == [
             %{method: :patch, url: "http://127.0.0.1:4997/tickets/SYM-7", payload: %{"state" => "done"}}
           ]

    # The page re-read the ticket, so the state the service answered is on it without a manual refresh,
    # and nothing claims the write was refused.
    assert html =~ ~s(<span class="state-badge">done</span>)
    assert html =~ ~s(<option value="done" selected)
    refute html =~ "That change was not written"
  end

  test "the comment box POSTs the comment to the service, signed operator", %{root: root} do
    write_workflow!(root, service_tracker())
    {client, writes} = service_write_client(200)
    start_endpoint(ticket_reader_client: client)
    {:ok, view, _html} = live(build_conn(), "/control/tickets/SYM-7")

    view |> form("form[phx-submit=comment]", comment: "Please also cover the Windows path.") |> render_submit()

    # The signature is the page's own, not the agent's: the ticket's history has to say who wrote it.
    assert service_writes(writes) == [
             %{
               method: :post,
               url: "http://127.0.0.1:4997/tickets/SYM-7/comments",
               payload: %{"author" => "operator", "body" => "Please also cover the Windows path."}
             }
           ]
  end

  test "a state the service refuses renders its reason and claims nothing was written", %{root: root} do
    write_workflow!(root, service_tracker())
    {client, writes} = service_write_client(500)
    start_endpoint(ticket_reader_client: client)
    {:ok, view, _html} = live(build_conn(), "/control/tickets/SYM-7")

    html = view |> form("form[phx-submit=set_state]", state: "done") |> render_submit()

    assert [%{method: :patch}] = service_writes(writes)

    # The page is still a page, still showing the ticket it had read, and the reason is the service's
    # own answer rather than a claim that something was written.
    assert html =~ "That change was not written"
    assert html =~ "HTTP 500"
    assert html =~ "Cache the git roots lookup"
    refute html =~ "The ticket could not be read"
    assert html =~ ~s(<span class="state-badge state-badge-warning">ready)
  end

  test "a comment the service does not hold renders its reason, and no comment is claimed",
       %{root: root} do
    write_workflow!(root, service_tracker())
    {client, writes} = service_write_client(404)
    start_endpoint(ticket_reader_client: client)
    {:ok, view, _html} = live(build_conn(), "/control/tickets/SYM-7")

    html = view |> form("form[phx-submit=comment]", comment: "hello") |> render_submit()

    assert [%{method: :post}] = service_writes(writes)
    assert html =~ "That change was not written"
    assert html =~ "the ticket service has no ticket for"
    assert html =~ "ticket_service_ticket_not_found"
    assert html =~ "Cache the git roots lookup"
  end

  test "a service that cannot be reached renders the refusal, for both controls", %{root: root} do
    write_workflow!(root, service_tracker())
    start_endpoint(ticket_reader_client: refusing_writes())
    {:ok, view, _html} = live(build_conn(), "/control/tickets/SYM-7")

    comment_html = view |> form("form[phx-submit=comment]", comment: "hello") |> render_submit()

    assert comment_html =~ "That change was not written"
    assert comment_html =~ "the ticket service did not answer"
    assert comment_html =~ "econnrefused"

    state_html = view |> form("form[phx-submit=set_state]", state: "done") |> render_submit()

    assert state_html =~ "That change was not written"
    assert state_html =~ "econnrefused"

    # Still the ticket the page had read: a failed write re-reads nothing, so it cannot turn "refused"
    # into "no ticket with this identifier".
    assert state_html =~ "Cache the git roots lookup"
    refute state_html =~ "This ticket could not be read"
  end

  test "nothing is written without a submit", %{root: root} do
    write_workflow!(root, service_tracker())
    {client, writes} = service_write_client(200)
    start_endpoint(ticket_reader_client: client)

    {:ok, view, html} = live(build_conn(), "/control/tickets/SYM-7")

    assert html =~ "Add a comment"
    assert service_writes(writes) == []

    view |> element("button[phx-click=refresh]") |> render_click()

    assert service_writes(writes) == []

    # A state the workflow does not declare is refused before the writer is ever asked.
    refused = render_submit(view, "set_state", %{"state" => "shipped"})

    assert refused =~ "The state shipped is not one of the states this workflow declares"
    assert service_writes(writes) == []
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

  # The page's write seam, stubbed. One client serves both directions, because the endpoint config
  # carries one function: a read as `(nil, url, nil)` -- the read direction of the transport seam, which
  # `TicketReader` hands a three-argument client -- and a write as `(method, url, payload)`.
  #
  # A write is recorded in an agent rather than sent to this process, because it happens inside the
  # LiveView: the page is handed the client, not the test, so what would have gone on the wire is read
  # back from the agent afterwards.
  #
  # A non-2xx answer is returned as it is, so the page renders the service's own failure. A 404's body is
  # the store's not-found envelope, which is what the adapter maps to its ticket-shaped failure.
  defp service_write_client(status) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    client = fn
      nil, _url, nil ->
        {:ok, %{status: 200, body: deep_row()}}

      method, url, payload when is_atom(method) ->
        Agent.update(agent, &(&1 ++ [%{method: method, url: url, payload: payload}]))
        answer_write(status)
    end

    {client, agent}
  end

  # The one that remembers: a PATCH answers the state it was asked to write, and the read after it
  # answers the same state -- so "the page shows the state the service answered" is asserted against a
  # service that actually moved, not against a stub that was told what to say.
  defp stateful_service_client do
    {:ok, state} = Agent.start_link(fn -> "ready" end)
    {:ok, writes} = Agent.start_link(fn -> [] end)

    client = fn
      nil, _url, nil ->
        {:ok, %{status: 200, body: deep_row(%{"state" => state_object(Agent.get(state, & &1))})}}

      :patch, url, payload when is_map(payload) ->
        Agent.update(writes, &(&1 ++ [%{method: :patch, url: url, payload: payload}]))
        Agent.update(state, fn _old -> payload["state"] end)
        {:ok, %{status: 200, body: deep_row(%{"state" => state_object(payload["state"])})}}

      method, url, payload when is_atom(method) ->
        Agent.update(writes, &(&1 ++ [%{method: method, url: url, payload: payload}]))
        {:ok, %{status: 200, body: deep_row()}}
    end

    {client, writes}
  end

  defp service_writes(agent), do: Agent.get(agent, & &1)

  defp answer_write(status) when status in 200..299 do
    {:ok, %{status: status, body: deep_row(%{"state" => state_object("done")})}}
  end

  defp answer_write(404) do
    body = %{"error" => %{"code" => "not_found", "message" => "no ticket with identifier \"SYM-7\""}}
    {:ok, %{status: 404, body: body}}
  end

  defp answer_write(status) do
    {:ok, %{status: status, body: %{"error" => %{"code" => "db", "message" => "the store answered #{status}"}}}}
  end

  defp state_object(name), do: %{"type" => "completed", "name" => name, "display_name" => name}

  # The service that is down for writes only: the page's read still answers -- a page whose service
  # cannot be read at all is a different test above -- and every write is the connection refusal a
  # service on a port nothing is listening on produces. One client, both directions.
  defp refusing_writes do
    fn
      nil, _url, nil -> {:ok, %{status: 200, body: deep_row()}}
      _method, _url, _payload -> {:error, {:ticket_service_unreachable, %{reason: :econnrefused}}}
    end
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

  # The deep read: the same row with the comments the list endpoint does not read. `overrides` is what a
  # write's answer changes -- a successful PATCH answers the ticket in its new state, and the re-read
  # after it has to say the same thing.
  defp deep_row(overrides \\ %{}) do
    service_row(
      Map.merge(
        %{
          "blockers" => [live_blocker("SYM-8", "in-progress")],
          "blocked_by" => ["SYM-8"],
          "comments" => [
            comment(1001, "octocat", "Please also cover the Windows path.", 1_760_000_010_000),
            comment(1002, "local-agent", "Covered in the branch.", 1_760_000_020_000)
          ]
        },
        overrides
      )
    )
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
