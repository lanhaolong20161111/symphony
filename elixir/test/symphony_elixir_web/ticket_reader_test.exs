defmodule SymphonyElixirWeb.TicketReaderTest do
  # The reader takes its tracker settings and its transport as arguments, so these tests touch no
  # global application environment where they can avoid it and no test opens a socket: every service
  # call is answered by an injected client, and `TicketService.get/1` is never reached.
  use ExUnit.Case, async: true

  alias SymphonyElixirWeb.TicketReader

  @service_url "http://127.0.0.1:4020"

  defp service_settings(overrides \\ %{}) do
    Map.merge(
      %{
        kind: "ticket_service",
        provider: %{"url" => @service_url},
        active_states: ["ready", "in-progress"],
        terminal_states: ["done", "cancelled"]
      },
      overrides
    )
  end

  defp file_settings(dir) do
    %{
      kind: "file",
      provider: %{"path" => dir},
      active_states: ["ready", "in-progress"],
      terminal_states: ["done", "cancelled"]
    }
  end

  # One ticket as `SymphonyTicketsWeb.Presenter.ticket/1` renders it: a state object, the live
  # relations, the comments oldest first, and the store's millisecond timestamps.
  defp service_row(overrides \\ %{}) do
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
        "url" => "https://example.test/SYM-7",
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

  defp rows(tickets), do: %{"tickets" => tickets}
  defp answering(status, body), do: fn _url -> {:ok, %{status: status, body: body}} end

  # Records the URL it was asked for, so a test can assert what would have gone on the wire without
  # there being a wire.
  defp recording(status, body) do
    fn url ->
      send(self(), {:requested, url})
      {:ok, %{status: status, body: body}}
    end
  end

  defp ticket_for(settings, identifier, client) do
    TicketReader.fetch(settings, identifier, client: client)
  end

  describe "the file tracker: today's contract, unchanged" do
    setup do
      dir = Path.join(System.tmp_dir!(), "ticket-reader-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    end

    test "the list carries the list fields, and one ticket's read carries its body and discussion",
         %{dir: dir} do
      write_ticket!(dir, "SYM-7", """
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

      write_ticket!(dir, "SYM-8", """
      ---
      id: SYM-8
      title: "Ship the board"
      state: done
      labels: [ui]
      priority: 1
      ---

      Body text of the second ticket.
      """)

      settings = file_settings(dir)
      assert {:ok, tickets} = TicketReader.list(settings)
      assert Enum.map(tickets, & &1.identifier) == ["SYM-7", "SYM-8"]

      seven = Enum.find(tickets, &(&1.identifier == "SYM-7"))
      assert seven.title == "Cache the git roots lookup"
      assert seven.state == "ready"
      assert seven.priority == 2
      assert seven.labels == ["perf", "windows"]
      assert seven.assignee == "lhl20"
      assert seven.blocked_by == [%{identifier: "SYM-8", state: "done"}]
      assert seven.branch_name == "symphony/SYM-7"
      assert seven.tracker == :file
      assert seven.path == Path.join(Path.expand(dir), "SYM-7.md")

      # The body without the discussion section, which the comments panel shows on its own.
      assert seven.description == "Cache the git roots lookup per run and add a test."

      assert seven.discussion == [
               %{
                 author: "octocat",
                 at: "2026-01-02T03:04:05Z",
                 id: "1001",
                 text: "Please also cover the Windows path."
               },
               %{
                 author: "local-agent",
                 at: "2026-01-02T04:00:00Z",
                 id: "local-1",
                 text: "Covered in the branch."
               }
             ]

      assert seven.links == [
               %{url: "https://github.com/openai/symphony/pull/42", title: "PR #42", kind: "pr"}
             ]

      assert seven.pr_url == "https://github.com/openai/symphony/pull/42"
    end

    test "one ticket is found by identifier and by its front-matter id", %{dir: dir} do
      write_ticket!(dir, "SYM-9", """
      ---
      id: 9
      identifier: SYM-9
      title: "By either name"
      state: ready
      ---

      The body.
      """)

      settings = file_settings(dir)

      assert {:ok, by_identifier} = TicketReader.fetch(settings, "SYM-9")
      assert by_identifier.title == "By either name"

      # The tracker's `id` is the stable dispatch identity and may be the provider's own number, which
      # is what the page's identifier lookup has always accepted as well.
      assert {:ok, by_id} = TicketReader.fetch(settings, "9")
      assert by_id.identifier == "SYM-9"
    end

    test "an identifier that is not in the queue is :not_found, not an empty ticket", %{dir: dir} do
      write_ticket!(dir, "SYM-7", """
      ---
      id: SYM-7
      title: "Only ticket"
      state: ready
      ---

      The body.
      """)

      assert {:error, :not_found} = TicketReader.fetch(file_settings(dir), "SYM-404")
    end

    test "a file whose front matter does not parse is not a ticket, and is not an error", %{dir: dir} do
      File.write!(Path.join(dir, "README.md"), "Not front matter at all.\n")
      write_ticket!(dir, "SYM-7", """
      ---
      id: SYM-7
      title: "The ticket"
      state: ready
      ---

      The body.
      """)

      assert {:ok, tickets} = TicketReader.list(file_settings(dir))
      assert Enum.map(tickets, & &1.identifier) == ["SYM-7"]
    end

    test "a BOARD- file is listed by the tracker but read from no file, as it always has been", %{dir: dir} do
      # `BOARD-` files are the tracker's own listing convention and the console's index skips them, so
      # such a ticket has no body and no links here. Both halves of that are the behaviour this seam
      # inherited, and neither is an error.
      write_ticket!(dir, "BOARD-1", "---\nid: BOARD-1\ntitle: \"The board\"\nstate: ready\n---\n")

      assert {:ok, [board]} = TicketReader.list(file_settings(dir))
      assert board.identifier == "BOARD-1"
      assert board.path == nil
      assert board.description == ""
      assert board.links == []
    end

    test "a queue directory that is not there is the tracker's own error" do
      missing = Path.join(System.tmp_dir!(), "ticket-reader-missing-#{System.unique_integer([:positive])}")

      assert {:error, {:file_tracker_path_not_found, path}} =
               TicketReader.list(file_settings(missing))

      assert path == Path.expand(missing)
    end

    test "a front matter description overrides the body", %{dir: dir} do
      write_ticket!(dir, "SYM-7", """
      ---
      id: SYM-7
      title: "Overridden"
      state: ready
      description: "From the front matter."
      ---

      The body, which the front matter replaces.
      """)

      assert {:ok, ticket} = TicketReader.fetch(file_settings(dir), "SYM-7")
      assert ticket.description == "From the front matter."
    end
  end

  describe "the ticket service: the deep read is the service's own call" do
    test "the list asks for the states the workflow declares, in order, deduplicated" do
      settings =
        service_settings(%{
          active_states: ["ready", "ready", "in-progress"],
          terminal_states: ["done", "ready"]
        })

      client = recording(200, rows([service_row()]))

      assert {:ok, [ticket]} = TicketReader.list(settings, client: client)
      assert ticket.identifier == "SYM-7"
      assert ticket.state == "ready"
      assert ticket.labels == ["perf", "windows"]
      assert ticket.priority == 2
      assert ticket.branch_name == "symphony/SYM-7"
      assert ticket.assignee == "operator"
      assert ticket.tracker == :service
      assert ticket.path == nil

      assert_received {:requested, url}
      assert url == @service_url <> "/tickets?state=ready&state=in-progress&state=done"
    end

    test "the list carries the live blocks the row was read with, and drops the resolved ones" do
      row =
        service_row(%{
          "blockers" => [
            live_blocker("SYM-8", "in-progress"),
            %{"blocker_identifier" => "SYM-9", "blocker_state" => nil, "resolved" => true}
          ]
        })

      assert {:ok, [ticket]} = TicketReader.list(service_settings(), client: answering(200, rows([row])))
      assert ticket.blocked_by == [%{identifier: "SYM-8", state: "in-progress"}]
    end

    test "one ticket is the service's deep read: its own URL, its labels, its body and its comments" do
      comments = [
        comment(1001, "octocat", "Please also cover the Windows path.", 1_760_000_010_000),
        comment(1002, "local-agent", "Covered in the branch.", 1_760_000_020_000)
      ]

      row =
        service_row(%{
          "blockers" => [live_blocker("SYM-8", "in-progress")],
          "comments" => comments
        })

      client = recording(200, row)

      assert {:ok, ticket} = ticket_for(service_settings(), "SYM-7", client)

      assert_received {:requested, url}
      assert url == @service_url <> "/tickets/SYM-7"

      assert ticket.identifier == "SYM-7"
      assert ticket.title == "Cache the git roots lookup"
      assert ticket.state == "ready"
      assert ticket.labels == ["perf", "windows"]
      assert ticket.blocked_by == [%{identifier: "SYM-8", state: "in-progress"}]
      assert ticket.tracker == :service
      assert ticket.description == "Cache the git roots lookup per run and add a test."

      # Oldest first, each with its author -- the store's order (`store.ex:996`) and the page's.
      assert ticket.discussion == [
               %{
                 author: "octocat",
                 at: "2025-10-09T08:53:30.000Z",
                 id: "1001",
                 text: "Please also cover the Windows path."
               },
               %{
                 author: "local-agent",
                 at: "2025-10-09T08:53:40.000Z",
                 id: "1002",
                 text: "Covered in the branch."
               }
             ]
    end

    test "a comment's author is never blank: a row without one says so" do
      row = service_row(%{"comments" => [comment(1001, nil, "Anonymous.", 1_760_000_010_000)]})

      assert {:ok, ticket} = ticket_for(service_settings(), "SYM-7", answering(200, row))
      assert [%{author: "unknown", text: "Anonymous."}] = ticket.discussion
    end

    test "a 404 that names the value is :not_found" do
      body = %{"error" => %{"code" => "not_found", "message" => "no ticket with identifier \"SYM-404\""}}

      assert {:error, :not_found} =
               ticket_for(service_settings(), "SYM-404", answering(404, body))
    end

    test "a 404 that names nothing is the service's answer, not a missing ticket" do
      body = %{"error" => %{"code" => "not_found", "message" => "no route for GET /tickets"}}

      assert {:error, {:ticket_service_http, 404, ^body}} =
               ticket_for(service_settings(), "SYM-7", answering(404, body))
    end

    test "a body that is not a ticket is refused rather than rendered as an empty one" do
      assert {:error, {:ticket_service_invalid_payload, "not json at all"}} =
               ticket_for(service_settings(), "SYM-7", answering(200, "not json at all"))

      # A JSON object that names no ticket is the same answer: an error envelope with a 200 on it, for
      # instance, must not become a ticket with nothing in it.
      assert {:error, {:ticket_service_invalid_payload, %{"ok" => true}}} =
               ticket_for(service_settings(), "SYM-7", answering(200, %{"ok" => true}))
    end

    test "the transport's own error is passed through unchanged" do
      refused = fn _url -> {:error, {:ticket_service_unreachable, %{reason: :econnrefused}}} end

      assert {:error, {:ticket_service_unreachable, %{reason: :econnrefused}}} =
               ticket_for(service_settings(), "SYM-7", refused)
    end

    test "a client that raises is a read that failed, not a crash" do
      exploding = fn _url -> raise "no socket" end

      assert {:error, {:ticket_read_failed, message}} =
               ticket_for(service_settings(), "SYM-7", exploding)

      assert message =~ "no socket"
    end

    test "a non-2xx that is not a 404 carries its status" do
      assert {:error, {:ticket_service_http, 500, %{"error" => "boom"}}} =
               ticket_for(service_settings(), "SYM-7", answering(500, %{"error" => "boom"}))
    end

    test "a tracker with no url is refused rather than asked on a guessed port" do
      settings = service_settings(%{provider: %{}})

      assert {:error, :missing_ticket_service_url} =
               TicketReader.list(settings, client: answering(200, rows([])))

      assert {:error, :missing_ticket_service_url} =
               ticket_for(settings, "SYM-7", answering(200, service_row()))
    end

    test "a workflow that declares no state is refused, and nothing is asked" do
      settings = service_settings(%{active_states: [], terminal_states: []})
      called = fn _url -> flunk("a request that asks for no state must not reach the ticket service") end

      assert {:error, :no_ticket_service_states} = TicketReader.list(settings, client: called)
    end

    test "a declared-but-blank state is nothing asked for, not an empty state name" do
      settings = service_settings(%{active_states: ["  "], terminal_states: [nil]})

      assert {:error, :no_ticket_service_states} =
               TicketReader.list(settings, client: answering(200, rows([])))
    end
  end

  describe "a tracker this console cannot read" do
    test "the list and one ticket are both refused, and nothing is asked" do
      settings = %{
        kind: "linear",
        provider: %{"api_key" => "secret"},
        active_states: ["ready"],
        terminal_states: ["done"]
      }

      called = fn _url -> flunk("a tracker this console cannot read must not be asked anything") end

      assert {:error, {:ticket_kind_not_readable, "linear"}} = TicketReader.list(settings, client: called)

      assert {:error, {:ticket_kind_not_readable, "linear"}} =
               TicketReader.fetch(settings, "SYM-7", client: called)

      refute_received {:requested, _url}
    end

    test "a tracker with no kind at all is refused too" do
      assert {:error, :invalid_tracker_settings} = TicketReader.list(%{provider: %{}})
      assert {:error, :invalid_tracker_settings} = TicketReader.fetch(%{provider: %{}}, "SYM-7")
    end
  end

  describe "the two questions the pages ask about the tracker itself" do
    test "states/2 is the workflow's own order, active first, deduplicated, blanks dropped" do
      settings = %{active_states: ["ready", "", "in-progress"], terminal_states: ["ready", "done"]}

      assert TicketReader.states(settings) == ["ready", "in-progress", "done"]
      assert TicketReader.states(settings, :active) == ["ready", "in-progress"]
      assert TicketReader.states(settings, :terminal) == ["ready", "done"]
      assert TicketReader.states(%{}) == []
    end

    test "queue_path/1 is the file queue's directory, and nil for a service tracker" do
      dir = Path.join(System.tmp_dir!(), "ticket-reader-queue-#{System.unique_integer([:positive])}")

      assert TicketReader.queue_path(file_settings(dir)) == Path.expand(dir)
      assert TicketReader.queue_path(service_settings()) == nil
      assert TicketReader.queue_path(%{provider: %{"path" => ""}}) == nil
      assert TicketReader.queue_path(%{}) == nil
    end
  end

  defp write_ticket!(dir, id, text), do: File.write!(Path.join(dir, "#{id}.md"), text)
end
