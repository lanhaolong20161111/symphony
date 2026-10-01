defmodule SymphonyElixir.TicketServiceTrackerTest do
  # The adapter takes its tracker settings and its transport as arguments, so these tests touch no
  # global application environment and no test opens a socket: every call below is answered by an
  # injected client, and the default client (`TicketService.get/1`, `TicketService.request/3`) is never
  # reached. A read hands that client a URL; the two writes hand it a method, a URL and a body.
  use ExUnit.Case, async: true

  alias SymphonyElixir.Tracker.File, as: FileTracker
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Tracker.TicketService

  @base_url "http://127.0.0.1:4020"

  defp settings(overrides \\ %{}) do
    Map.merge(
      %{
        provider: %{"url" => @base_url},
        active_states: ["ready", "in-progress"],
        terminal_states: ["done", "cancelled"]
      },
      overrides
    )
  end

  # One row, shaped exactly as `SymphonyTicketsWeb.Presenter.ticket/1` renders a list row: a state
  # object, the live relations, and the store's millisecond timestamps.
  defp ticket(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => 7,
        "identifier" => "SYM-7",
        "title" => "Cache the git roots lookup",
        "description" => "The body.\n",
        "state" => %{"type" => "unstarted", "name" => "ready", "display_name" => "ready"},
        "priority" => 2,
        "assignee" => "operator",
        "branch_name" => "symphony/SYM-7",
        "url" => "https://example.test/SYM-7",
        "labels" => ["perf", "ux"],
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

  defp fetch_states(states, client, overrides \\ %{}) do
    TicketService.fetch_issues_by_states(states,
      client: client,
      tracker_settings: settings(overrides)
    )
  end

  defp fetch_ids(ids, client, overrides \\ %{}) do
    TicketService.fetch_issues_by_ids(ids, client: client, tracker_settings: settings(overrides))
  end

  # ── the two writes ──────────────────────────────────────────────────────────

  # A write client: the same seam as `answering/2` below, handed the method and the body a write carries
  # instead of a URL alone. It records the request, so a test can assert what would have gone on the
  # wire without there being a wire.
  defp service_writes(status, body) do
    fn method, url, payload ->
      send(self(), {:requested, method, url, payload})
      {:ok, %{status: status, body: body}}
    end
  end

  defp refusing_client do
    fn _method, _url, _body -> flunk("a call that must be refused reached the ticket service") end
  end

  defp run(tool, arguments, client, extra \\ []) do
    opts = extra ++ [client: client, tracker_settings: settings()]

    TicketService.execute_agent_tool(tool, arguments, opts)
  end

  defp specs_by_name(adapter) do
    adapter.agent_tool_specs() |> Map.new(&{&1["name"], &1})
  end

  # The part of a tool spec a prompt depends on: the argument names, their types, which are required,
  # and that nothing undeclared is accepted. The prose is deliberately not compared -- this kind's
  # description has to say what this service does, and the file tracker's says what a ticket file does
  # ("newlines are flattened into the single discussion line"), so one shared sentence would be false
  # for one of the two kinds.
  defp argument_shape(spec) do
    schema = spec["inputSchema"]

    %{
      "type" => schema["type"],
      "additionalProperties" => schema["additionalProperties"],
      "required" => schema["required"],
      "properties" => Map.new(schema["properties"], fn {name, property} -> {name, property["type"]} end)
    }
  end

  defp state_object(name), do: %{"type" => "started", "name" => name, "display_name" => name}

  # One comment, shaped exactly as `SymphonyTicketsWeb.Presenter.comment/1` renders it.
  defp comment(overrides) do
    Map.merge(
      %{
        "id" => 3,
        "ticket_id" => 7,
        "parent_id" => nil,
        "author" => "agent",
        "body" => "the body",
        "created_at" => 1_760_000_000_000
      },
      overrides
    )
  end

  describe "rule 2: an empty request is answered by nothing" do
    test "an empty state list and an empty id list are {:ok, []}" do
      called = fn _url -> flunk("an empty request must not reach the ticket service") end

      assert {:ok, []} = TicketService.fetch_issues_by_states([], client: called)
      assert {:ok, []} = TicketService.fetch_issues_by_ids([], client: called)
    end

    test "no call is recorded at all, not merely an empty answer" do
      client = recording(200, rows([]))

      assert {:ok, []} = fetch_states([], client)
      assert {:ok, []} = fetch_ids([], client)

      refute_received {:requested, _url}
    end

    test "the empty answer comes before the settings: a tracker with no URL still answers it" do
      # Contract rule 2 at its strongest (`tracker_contract.exs:149-171`), which the file adapter is
      # measured by: the unusable settings must fail a non-empty request first, so this cannot pass
      # by an adapter that ignores its settings entirely.
      unusable = %{provider: %{}}

      assert {:error, :missing_ticket_service_url} =
               TicketService.fetch_issues_by_states(["ready"], unusable)

      assert {:ok, []} = TicketService.fetch_issues_by_states([], unusable)
      assert {:ok, []} = TicketService.fetch_issues_by_ids([], unusable)

      # And the configured entry points short-circuit before the workflow is read at all.
      assert {:ok, []} = TicketService.fetch_issues_by_states([])
      assert {:ok, []} = TicketService.fetch_issues_by_ids([])
    end
  end

  describe "the states the workflow declares" do
    test "are sent as repeated parameters, in the declared order" do
      client = recording(200, rows([]))

      assert {:ok, []} = fetch_states(["ready", "in-progress"], client)

      assert_received {:requested, url}
      assert url == @base_url <> "/tickets?state=ready&state=in-progress"
    end

    test "a single declared state is one parameter, and a name the service does not know is sent" do
      client = recording(200, rows([]))

      # The adapter has no vocabulary of its own: `paused` goes out because the workflow declared
      # it, and the service's empty answer is not turned into a refusal here.
      assert {:ok, []} = fetch_states(["paused"], client)
      assert_received {:requested, url}
      assert url == @base_url <> "/tickets?state=paused"
    end

    test "a state that needs encoding is encoded, not concatenated raw" do
      client = recording(200, rows([]))

      assert {:ok, []} = fetch_states(["in review", "a&b"], client)
      assert_received {:requested, url}
      assert url == @base_url <> "/tickets?state=in+review&state=a%26b"
    end

    test "a trailing slash in provider.url does not double the path" do
      client = recording(200, rows([]))

      assert {:ok, []} = fetch_states(["ready"], client, %{provider: %{"url" => @base_url <> "/"}})
      assert_received {:requested, url}
      assert url == @base_url <> "/tickets?state=ready"
    end
  end

  describe "by id" do
    test "the ids go out as one comma-separated parameter" do
      client = recording(200, rows([ticket()]))

      assert {:ok, [issue]} = fetch_ids(["7", "SYM-8"], client)

      assert issue.identifier == "SYM-7"
      assert_received {:requested, url}
      assert url == @base_url <> "/tickets?ids=7,SYM-8"
    end

    test "an id the service does not know fails the whole call, naming it" do
      # Verbatim what the service answers for one unreadable identifier of a batch
      # (`store_error.ex:47-48`): 404, and the message names the value that could not be read.
      body = %{"error" => %{"code" => "not_found", "message" => "no ticket with identifier \"SYM-9\""}}
      client = answering(404, body)

      assert {:error, {:ticket_service_ticket_not_found, "SYM-9"}} =
               fetch_ids(["SYM-7", "SYM-9"], client)
    end

    test "the records that did exist are not returned beside the error" do
      body = %{"error" => %{"code" => "not_found", "message" => "no ticket with id 42"}}

      result = fetch_ids(["7", "42"], answering(404, body))

      assert result == {:error, {:ticket_service_ticket_not_found, "42"}}
    end

    test "a 404 that names nothing is still an error, and still not a short list" do
      assert {:error, {:ticket_service_http, 404, %{"error" => %{"code" => "not_found"}}}} =
               fetch_ids(["7"], answering(404, %{"error" => %{"code" => "not_found"}}))
    end
  end

  describe "the service's JSON, as the issue struct" do
    test "every field this surface carries is mapped" do
      client = answering(200, rows([ticket()]))

      assert {:ok, [issue]} = fetch_states(["ready"], client)

      assert %Issue{} = issue
      assert issue.id == "7"
      assert issue.identifier == "SYM-7"
      assert issue.title == "Cache the git roots lookup"
      assert issue.description == "The body.\n"
      assert issue.state == "ready"
      assert issue.priority == 2
      assert issue.assignee_id == "operator"
      assert issue.branch_name == "symphony/SYM-7"
      assert issue.url == "https://example.test/SYM-7"
      assert issue.labels == ["perf", "ux"]
      assert issue.blocked_by == []

      # Milliseconds, stated as a unit rather than left to look like seconds.
      assert %DateTime{} = issue.created_at
      assert DateTime.to_unix(issue.created_at, :millisecond) == 1_760_000_000_000
      assert %DateTime{} = issue.updated_at

      # This adapter reads the ticket service and nothing else; there is no provider-native ref and
      # no per-ticket agent route on that surface.
      assert issue.native_ref == nil
      assert issue.adapter == nil
      assert issue.model == nil

      assert issue.dispatchable
    end

    test "a blocker is the ref shape the file adapter produces, carrying its live state" do
      row = ticket(%{"blocked_by" => ["SYM-3"], "blockers" => [live_blocker("SYM-3", "in-progress")]})

      assert {:ok, [issue]} = fetch_states(["in-progress"], answering(200, rows([row])))

      assert issue.blocked_by == [%{id: "SYM-3", identifier: "SYM-3", state: "in-progress"}]
    end

    test "a resolved block is history, not a blocker" do
      resolved = live_blocker("SYM-3", "ready") |> Map.put("resolved", true)
      row = ticket(%{"blocked_by" => [], "blockers" => [resolved]})

      assert {:ok, [issue]} = fetch_states(["ready"], answering(200, rows([row])))

      assert issue.blocked_by == []
      assert issue.dispatchable
    end

    test "absent collections become [], absent scalars become nil, and a body is not trimmed" do
      row = %{
        "state" => %{"type" => "unstarted", "name" => "ready", "display_name" => "ready"},
        "description" => "  leading space is part of the body\n",
        "dispatchable" => true
      }

      assert {:ok, [issue]} = fetch_states(["ready"], answering(200, rows([row])))

      assert issue.id == nil
      assert issue.identifier == nil
      assert issue.title == nil
      assert issue.description == "  leading space is part of the body\n"
      assert issue.priority == nil
      assert issue.assignee_id == nil
      assert issue.labels == []
      assert issue.blocked_by == []
      assert issue.created_at == nil
      assert issue.updated_at == nil
    end
  end

  describe "dispatchable: the blocker rule and the service's column" do
    test "no blockers, the first active state: dispatchable" do
      assert {:ok, [issue]} = fetch_states(["ready"], answering(200, rows([ticket()])))
      assert issue.dispatchable
    end

    test "a live blocker while the ticket is in the first active state: held back" do
      row = ticket(%{"blockers" => [live_blocker("SYM-3", "ready")], "blocked_by" => ["SYM-3"]})

      assert {:ok, [issue]} = fetch_states(["ready"], answering(200, rows([row])))

      assert issue.dispatchable == false
    end

    test "a live blocker in a later state of its own: still held back" do
      # The blocker is live whatever state it is in; only a terminal one stops gating.
      row = ticket(%{"blockers" => [live_blocker("SYM-3", "in-progress")], "blocked_by" => ["SYM-3"]})

      assert {:ok, [issue]} = fetch_states(["ready"], answering(200, rows([row])))

      assert issue.dispatchable == false
    end

    test "the same live blocker once the ticket has moved past the first active state: dispatched" do
      # `active_states`' order is load-bearing, as it is for the file adapter: once work has started,
      # an unfinished blocker stops gating and cannot freeze a ticket that is already in progress.
      in_progress = %{"type" => "started", "name" => "in-progress", "display_name" => "in-progress"}
      row = ticket(%{"state" => in_progress, "blockers" => [live_blocker("SYM-3", "ready")]})

      assert {:ok, [issue]} = fetch_states(["in-progress"], answering(200, rows([row])))

      assert issue.dispatchable
    end

    test "a blocker that is terminal: dispatched" do
      row = ticket(%{"blockers" => [live_blocker("SYM-3", "done")], "blocked_by" => ["SYM-3"]})

      assert {:ok, [issue]} = fetch_states(["ready"], answering(200, rows([row])))

      assert issue.dispatchable
    end

    test "a blocker whose state cannot be seen: held back" do
      row = ticket(%{"blockers" => [%{"blocker_identifier" => "SYM-3", "resolved" => false}]})

      assert {:ok, [issue]} = fetch_states(["ready"], answering(200, rows([row])))

      assert issue.blocked_by == [%{id: "SYM-3", identifier: "SYM-3", state: nil}]
      assert issue.dispatchable == false
    end

    test "the service's own dispatchable: false wins, with no blockers to explain it" do
      row = ticket(%{"dispatchable" => false})

      assert {:ok, [issue]} = fetch_states(["ready"], answering(200, rows([row])))

      assert issue.blocked_by == []
      assert issue.dispatchable == false
    end

    test "the service's own dispatchable: false wins over the derived rule's yes and its no" do
      # The stored column is a person's "not this one": it is a veto, and the adapter never lifts it.
      parked = ticket(%{"dispatchable" => false, "blockers" => [live_blocker("SYM-3", "ready")]})
      in_progress = %{"type" => "started", "name" => "in-progress", "display_name" => "in-progress"}

      parked_later = ticket(%{"state" => in_progress, "dispatchable" => false})

      assert {:ok, [first]} = fetch_states(["ready"], answering(200, rows([parked])))
      assert {:ok, [second]} = fetch_states(["in-progress"], answering(200, rows([parked_later])))

      assert first.dispatchable == false
      assert second.dispatchable == false
    end

    test "a missing or non-boolean column is not a yes" do
      # Fail closed: absent is not consent, and neither is a string.
      absent = ticket() |> Map.delete("dispatchable")
      wrong_type = ticket(%{"dispatchable" => "true"})

      assert {:ok, [first]} = fetch_states(["ready"], answering(200, rows([absent])))
      assert {:ok, [second]} = fetch_states(["ready"], answering(200, rows([wrong_type])))

      assert first.dispatchable == false
      assert second.dispatchable == false
    end
  end

  describe "the service's failures" do
    test "a non-2xx answer, a body that is not JSON and a connection error are three errors" do
      # Never a raise: each of these is a value the poll loop can act on.
      http = fetch_states(["ready"], answering(500, %{"error" => %{"code" => "db"}}))
      not_json = fetch_states(["ready"], answering(200, "not json at all"))
      not_the_shape = fetch_states(["ready"], answering(200, %{"other" => []}))
      unreachable = fetch_ids(["7"], fn _url -> {:error, {:ticket_service_unreachable, :econnrefused}} end)

      assert {:error, {:ticket_service_http, 500, %{"error" => %{"code" => "db"}}}} = http
      assert {:error, {:ticket_service_invalid_payload, "not json at all"}} = not_json
      assert {:error, {:ticket_service_invalid_payload, %{"other" => []}}} = not_the_shape
      assert {:error, {:ticket_service_unreachable, :econnrefused}} = unreachable
    end

    test "a row that is not an object fails the read instead of disappearing" do
      # Contract rule 3: an unreadable record is an error, never silently absent -- a scheduler must
      # not read "one row was nonsense" as "there is less work".
      assert {:error, :ticket_service_malformed_ticket} =
               fetch_states(["ready"], answering(200, %{"tickets" => [ticket(), "not a row"]}))
    end

    test "an undeclared URL fails the read rather than polling a guessed address" do
      assert {:error, :missing_ticket_service_url} =
               fetch_states(["ready"], answering(200, rows([])), %{provider: %{}})

      assert {:error, :missing_ticket_service_url} =
               fetch_states(["ready"], answering(200, rows([])), %{provider: %{"url" => "  "}})
    end
  end

  describe "validate_config" do
    test "refuses a missing URL, with no probe" do
      assert {:error, :missing_ticket_service_url} = TicketService.validate_config(%{provider: %{}})
      assert {:error, :missing_ticket_service_url} = TicketService.validate_config(%{})

      assert {:error, :missing_ticket_service_url} =
               TicketService.validate_config(%{provider: %{"url" => ""}})

      assert {:error, :invalid_ticket_service_settings} = TicketService.validate_config(nil)
    end

    test "accepts a declared URL without asking whether the service is up" do
      # Port 1 is not listening, and this returns at once: whether the service answers is decided at
      # fetch time, not while a workflow is being loaded.
      assert :ok = TicketService.validate_config(%{provider: %{"url" => "http://127.0.0.1:1"}})
      assert :ok = TicketService.validate_config(settings())
    end
  end

  describe "secret_environment_names" do
    test "is an empty list, which is a value rather than an exemption" do
      assert TicketService.secret_environment_names(settings()) == []
      assert TicketService.secret_environment_names(%{}) == []
    end
  end

  describe "the tools this adapter advertises" do
    test "are the file tracker's comment and state tools, by name" do
      assert Enum.map(TicketService.agent_tool_specs(), & &1["name"]) ==
               ["ticket_comment", "ticket_state"]

      # The composition that offered this project no tools at all is at the boundary, not here; this is
      # this adapter's own list. The file tracker's list is unchanged by this slice: the janitor's three
      # tools, publisher first.
      assert Enum.map(FileTracker.agent_tool_specs(), & &1["name"]) ==
               ["symphony_publish", "ticket_comment", "ticket_state"]
    end

    test "carry the file tracker's argument shapes, so one prompt serves both kinds" do
      service = specs_by_name(TicketService)
      file = specs_by_name(FileTracker)

      Enum.each(["ticket_comment", "ticket_state"], fn name ->
        assert argument_shape(service[name]) == argument_shape(file[name])
      end)
    end

    test "an unknown tool is refused in the shape the other adapters refuse one" do
      result = TicketService.execute_agent_tool("no_such_tool", %{}, client: refusing_client())

      assert result["success"] == false
      assert [%{"type" => "inputText", "text" => text}] = result["contentItems"]
      assert text == result["output"]

      payload = Jason.decode!(result["output"])
      assert payload["error"]["message"] =~ "Unsupported dynamic tool"
      assert payload["error"]["supportedTools"] == ["ticket_comment", "ticket_state"]

      # The same envelope, and the same message shape the janitor's tools answer with.
      janitor = FileTracker.execute_agent_tool("no_such_tool", %{}, [])
      assert Map.keys(janitor) == Map.keys(result)
      assert Jason.decode!(janitor["output"])["error"]["message"] =~ "Unsupported dynamic tool"
    end
  end

  describe "ticket_state" do
    test "PATCHes the ticket with the state as its only attribute" do
      client = service_writes(200, ticket(%{"state" => state_object("in-review")}))

      result = run("ticket_state", %{"ticket" => "SYM-7", "state" => "in-review"}, client)

      assert_received {:requested, :patch, url, body}
      assert url == @base_url <> "/tickets/SYM-7"
      assert body == %{"state" => "in-review"}
      assert result["success"] == true
      assert Jason.decode!(result["output"])["state"] == "in-review"
    end

    test "reports the state the service answered, not the one that was asked for" do
      # The service accepted the PATCH and its own answer says the ticket is still `ready`. That is the
      # state this tool reports, so a run never tells a human about a move that did not happen.
      client = service_writes(200, ticket(%{"state" => state_object("ready")}))

      result = run("ticket_state", %{"ticket" => "SYM-7", "state" => "done"}, client)

      assert result["success"] == true
      assert Jason.decode!(result["output"])["state"] == "ready"
    end

    test "an answer that names no state is a failure rather than a guess" do
      # A PATCH is idempotent, so refusing here costs nothing and asking again is safe -- unlike the
      # comment beside it, where a failure could invite a duplicate.
      client = service_writes(200, %{"identifier" => "SYM-7"})

      result = run("ticket_state", %{"ticket" => "SYM-7", "state" => "done"}, client)

      assert result["success"] == false
      assert Jason.decode!(result["output"])["error"]["message"] =~ "cannot read"
    end

    test "the ref it sends is the ticket's identifier, not the service's numeric id" do
      # The running issue carries both (`id` is the service's row id). The identifier is what every
      # layer names the ticket by -- the agent's argument, the prompt, the issue struct -- and the
      # service resolves it through the same `tickets_by_identifiers` path its `ids=` batch uses.
      client = service_writes(200, ticket(%{"state" => state_object("done")}))

      result = run("ticket_state", %{"state" => "done"}, client, issue: %{id: "7", identifier: "SYM-7"})

      assert_received {:requested, :patch, url, _body}
      assert url == @base_url <> "/tickets/SYM-7"
      assert result["success"] == true
    end

    test "a ref that needs encoding is one path segment, not two" do
      client = service_writes(200, ticket(%{"state" => state_object("done")}))

      result = run("ticket_state", %{"ticket" => "SYM 7/x", "state" => "done"}, client)

      assert_received {:requested, :patch, url, _body}
      assert url == @base_url <> "/tickets/SYM%207%2Fx"
      assert result["success"] == true
    end
  end

  describe "ticket_comment" do
    test "POSTs the author and the body, and a non-ASCII body survives the round trip" do
      body = "已复核：缓存命中率从 12% 升到 96%，非 ASCII 原样写回。"
      client = service_writes(201, comment(%{"body" => body}))

      result = run("ticket_comment", %{"ticket" => "SYM-7", "body" => body}, client)

      assert_received {:requested, :post, url, sent}
      assert url == @base_url <> "/tickets/SYM-7/comments"
      assert sent == %{"author" => "agent", "body" => body}
      assert result["success"] == true

      payload = Jason.decode!(result["output"])
      assert payload["ticket"] == "SYM-7"
      assert payload["comment"] == %{"id" => "3", "author" => "agent"}
    end

    test "a 2xx whose answer is thin is still a success: a comment is not idempotent" do
      # The service accepted the comment; the id is simply not in the answer. Failing here would invite
      # the agent to submit the same comment again, which is the one thing this tool must not cause.
      client = service_writes(201, %{})

      result = run("ticket_comment", %{"ticket" => "SYM-7", "body" => "x"}, client)

      assert result["success"] == true
      assert Jason.decode!(result["output"])["comment"] == %{"id" => nil, "author" => nil}
    end

    test "one request per call: the adapter never retries a comment behind the agent" do
      # `@req_opts` carries `retry: false`, and the tool itself submits once. A retry would post the
      # same comment twice and report whichever attempt finished last, with the duplicate invisible.
      client = service_writes(500, %{"error" => %{"code" => "db"}})

      result = run("ticket_comment", %{"ticket" => "SYM-7", "body" => "x"}, client)

      assert result["success"] == false
      assert_received {:requested, :post, _, _}
      refute_received {:requested, :post, _, _}
    end
  end

  describe "the failures the two tools report" do
    test "a 404 is a readable failure that names the ticket, for both tools" do
      # Verbatim what this service answers for a value it cannot read (`store_error.ex:45-48`): the same
      # mapping the reads use, because "no ticket with identifier X" is one fact either way.
      body = %{"error" => %{"code" => "not_found", "message" => "no ticket with identifier \"SYM-9\""}}

      state = run("ticket_state", %{"ticket" => "SYM-9", "state" => "done"}, service_writes(404, body))
      comment = run("ticket_comment", %{"ticket" => "SYM-9", "body" => "x"}, service_writes(404, body))

      Enum.each([state, comment], fn result ->
        assert result["success"] == false
        payload = Jason.decode!(result["output"])
        assert payload["error"]["ticket"] == "SYM-9"
        assert payload["error"]["message"] =~ "no ticket for"
      end)
    end

    test "a non-2xx that is not a 404 keeps its status and its body" do
      body = %{"error" => %{"code" => "unknown_state", "message" => "no such state"}}

      result = run("ticket_state", %{"ticket" => "SYM-7", "state" => "nope"}, service_writes(500, body))

      assert result["success"] == false
      message = Jason.decode!(result["output"])["error"]["message"]
      assert message =~ "HTTP 500"
      assert message =~ "unknown_state"
    end

    test "a connection error is a failure the agent can read, never a raise" do
      client = fn _method, _url, _body -> {:error, {:ticket_service_unreachable, :econnrefused}} end

      result = run("ticket_comment", %{"ticket" => "SYM-7", "body" => "x"}, client)

      assert result["success"] == false
      message = Jason.decode!(result["output"])["error"]["message"]
      assert message =~ "could not be reached"
      assert message =~ "econnrefused"
    end

    test "a body that is not an object is a failure for both tools, never a silent success" do
      state = run("ticket_state", %{"ticket" => "SYM-7", "state" => "done"}, service_writes(200, "nope"))
      comment = run("ticket_comment", %{"ticket" => "SYM-7", "body" => "x"}, service_writes(200, "nope"))

      Enum.each([state, comment], fn result ->
        assert result["success"] == false
        assert Jason.decode!(result["output"])["error"]["message"] =~ "cannot read"
      end)
    end

    test "a tracker that declares no url refuses the write without calling anywhere" do
      result =
        TicketService.execute_agent_tool(
          "ticket_state",
          %{"ticket" => "SYM-7", "state" => "done"},
          client: refusing_client(),
          tracker_settings: %{provider: %{}}
        )

      assert result["success"] == false
      assert Jason.decode!(result["output"])["error"]["message"] =~ "provider.url"
    end

    test "a call that names no ticket, or no value to write, is refused before the service is asked" do
      client = refusing_client()

      blank_body = run("ticket_comment", %{"ticket" => "SYM-7", "body" => "   "}, client)
      no_ticket = run("ticket_comment", %{"body" => "x"}, client)
      no_state = run("ticket_state", %{"ticket" => "SYM-7"}, client)

      Enum.each([blank_body, no_ticket, no_state], fn result ->
        assert result["success"] == false
        assert result["output"] =~ "needs a ticket identifier"
      end)
    end
  end
end
