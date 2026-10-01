defmodule SymphonyElixir.Tracker.TicketService do
  @moduledoc """
  The ticket service as a tracker: a reader over the standalone service's HTTP surface.

  `symphony-tickets` owns tickets in its own SQLite database and answers a small JSON surface over
  loopback HTTP (default port 4020, `docs/ticket-service-spec.md` section 4). This module is the one
  place that translates that surface into `SymphonyElixir.Tracker.Issue` structs, so the orchestrator
  polls it exactly as it polls Linear or GitHub.

  It reads, and it runs the two agent tools that write. That is a decision this adapter takes
  deliberately rather than by accident: a service-backed project used to be advertised **no tools at
  all**, so its agent could not move its ticket (its "I am done" signal) or leave a comment -- the two
  writes every human-facing promise here rests on. Both are executed host-side over the service's own
  HTTP API, and nothing else on that surface is reachable from an agent.

  The gate tool is **not** composed here. It is a property of the project, not of where its tickets
  come from, so the tracker boundary appends it for every kind
  (`SymphonyElixir.Tracker.compose_agent_tool_specs/1`).

  ## Where the service is

  The address lives in the tracker's free-form `provider` map, under `url`:

      tracker:
        kind: ticket_service
        provider:
          url: http://127.0.0.1:4020
        active_states:
          - ready
          - in-progress
        terminal_states:
          - done
          - cancelled

  There is no schema field for it, and no default: `validate_config/1` fails closed when
  `provider.url` is not declared rather than polling a port this adapter guessed at, because a
  misconfigured tracker that polls the wrong address is harder to notice than one that refuses to
  load.

  ## The two calls this adapter reads with

    * `GET {url}/tickets?state=<name>&state=<name>` -- one repeated `state` parameter for every state
      the workflow declares, in the order declared. The service reads repeated parameters out of the
      raw query string (`symphony_tickets_web/query.ex`), because a decoder that keeps only the last
      value would answer a narrower question than the one asked.
    * `GET {url}/tickets?ids=<id>,<id>` -- the ids in one comma-separated parameter, the spelling its
      router documents (`symphony_tickets_web/router.ex`), with each token form-encoded. Its store
      answers in the order asked for and fails the whole request when any value cannot be read,
      naming it; this adapter maps that 404 to `{:error, {:ticket_service_ticket_not_found, value}}`,
      so a short list can never look like "that is all there is".

  `GET /states` and `GET /health` are deliberately not called. The workflow declares the state names
  and they are sent as declared: this adapter has no vocabulary of its own to reconcile, and a name
  the service does not know comes back as an empty list -- which is the contract's rule, not a
  refusal invented here.

  ## The two writes the agent's tools make

  Both tools are the janitor's, by name and by argument schema, because one prompt serves every tracker
  kind: an agent saying "I am done" and "here is the report" must not have to know whether its ticket is
  a file or a row in this service's database. What differs is only who does the writing, and here it is
  this adapter, over the same service API the reads use:

    * `ticket_state` -- `PATCH {url}/tickets/:ref` with `{"state": <name>}`. The answer reports the state
      the service holds afterwards, not the one that was asked for;
    * `ticket_comment` -- `POST {url}/tickets/:ref/comments` with `{"author": "agent", "body": <text>}`.
      The answer reports the comment id the service assigned.

  `:ref` is the ticket's **identifier**, for example `SYM-26`, and not the service's numeric row id. The
  identifier is the name every layer already carries -- the `ticket` argument the agent passes, the
  `identifier` on the issue the run was dispatched for, and the spelling the service's own `ids=` batch
  resolves -- so a run reads and writes its ticket by one name. The service reads a purely numeric
  segment as an id (`symphony_tickets_web/router.ex:22-24`) and the identifiers it generates are
  `SYM-n`; a hand-written all-digit identifier would be unreachable through that surface, which is the
  service's documented limit rather than something this adapter can paper over.

  A comment is **not idempotent**, so nothing here retries one: every call carries `retry: false`
  (`@req_opts`), and no tool submits a request twice. A 2xx is the write's truth and is reported as
  success even when the answer's own shape is thin, because a failure there would be an invitation to
  submit the same comment again. A 404, any other non-2xx, a connection failure and a body that is not
  an object are all failures the agent can read, in the error vocabulary the reads already use.

  ## Which rule decides `dispatchable`

  Both rules, and either can say no. The service stores a `dispatchable` column and renders it; the
  blocker rule is derived here from the live blockers and the workflow's **first** active state,
  exactly as `SymphonyElixir.Tracker.File` derives it. The stored column is a veto -- a person
  parking a ticket must not be overridden by an adapter that found no blockers -- while the derived
  rule is a gate the column cannot lift. The two answers are combined, so the stricter one wins.

  ## No credentials, and why that is a value

  `secret_environment_names/1` answers `[]`, and that is a value rather than an exemption: the
  service authenticates nobody (it binds loopback only), so no provider credential travels to it and
  there is nothing to keep out of an agent's environment.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @timeout_ms 8_000

  # `retry: false` is load-bearing, not tidiness -- the same reasoning as `RecorderClient`: Req
  # retries transport errors with backoff by default, so a service that is down would cost three
  # connection attempts on every poll before the orchestrator is told so.
  #
  # It travels with the writes too, and there it is a correctness rule rather than a cost one: a comment
  # is **not idempotent**, so a retry behind the agent's back would post the same comment twice and
  # report whichever attempt finished last. Nothing in this module submits a request twice.
  @req_opts [receive_timeout: @timeout_ms, retry: false]

  @tickets_path "/tickets"
  @comments_path "/comments"

  # The two agent-facing tools, by the names the file tracker already offers (`Janitor.AgentTool`).
  # One prompt serves every tracker kind, so the name is the contract: an agent must not have to know
  # where its ticket lives to say "I am done" or to leave a comment.
  @comment_tool "ticket_comment"
  @state_tool "ticket_state"

  # The author every comment from a run is signed with. This surface requires an `author` (the store
  # refuses a comment without one), and the caller that has always existed is the agent -- the janitor
  # signs a file ticket's comments the same way (`janitor.ex:834`).
  @comment_author "agent"

  # The descriptions say what this service-backed kind actually does. The names, the argument schemas
  # and the envelope below are the janitor's, copied rather than shared so a change to one kind's tool
  # cannot silently change what the other kind's agent is told it can do.
  @comment_description """
  Add a comment to a ticket, by asking the ticket service to append it. Use it to leave something the
  next reader needs -- why you stopped, what you could not verify, an assumption you made -- instead of
  rewriting the ticket's description, which is the service's own field. The service assigns the comment
  id and answers with it.
  """

  @state_description """
  Move a ticket to a new state, by asking the ticket service to write it: the state names this workflow
  declares, such as `ready` or `in-review`.

  Use this instead of anything else to move the ticket: the service is the only writer of its own
  database, and a name it does not know is refused there rather than guessed at here. The call carries
  the state and nothing else, and the answer reports the state the service holds afterwards rather than
  the one that was asked for.
  """

  @comment_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["body"],
    "properties" => %{
      "ticket" => %{
        "type" => "string",
        "description" => "Ticket identifier to comment on, for example SYM-26. Defaults to the running ticket."
      },
      "body" => %{
        "type" => "string",
        "description" => "The comment. Plain text; the service stores it as written."
      }
    }
  }

  @state_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["state"],
    "properties" => %{
      "ticket" => %{
        "type" => "string",
        "description" => "Ticket to move, for example SYM-26. Defaults to the running ticket."
      },
      "state" => %{
        "type" => "string",
        "description" => "The state to set, for example in-review."
      }
    }
  }

  # The service's 404 names the value that could not be read ("no ticket with id 7", "no ticket with
  # identifier \"SYM-9\"": `symphony_tickets_web/store_error.ex:45-48`). Only the prefix is matched:
  # the batch rule is the point, so the caller has to be told *which* value failed, and the value is
  # the one the service named.
  @missing_ticket ~r/\Ano ticket with (?:id|identifier) (.*)\z/

  # ── reading ─────────────────────────────────────────────────────────────────

  @doc """
  The tickets in `states`, as the service has them.

  An empty list is answered with `{:ok, []}` before anything else runs: asking for nothing is
  answered by nothing, so no URL is resolved and no request is made for it.
  """
  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states([]), do: {:ok, []}

  def fetch_issues_by_states(states) when is_list(states) do
    fetch_issues_by_states(states, [])
  end

  @doc """
  `fetch_issues_by_states/1` with the tracker settings and the transport passed in.

  The second argument is either the tracker settings map (the shape `SymphonyElixir.Tracker.File`
  takes, and what `Config.settings!().tracker` is) or a keyword list of options:

    * `:tracker_settings` -- the tracker block to read, instead of the workflow's;
    * `:client` -- replaces the HTTP call. It takes the URL and answers
      `{:ok, %{status: integer(), body: term()}}` or `{:error, term()}`; the default is `get/1`,
      which is the only function here that opens a connection, so no test needs a socket.

  A read hands the client one argument (the URL) because that is the arity this seam's other caller
  passes: `SymphonyElixirWeb.TicketReader` injects `&TicketService.get/1` through it
  (`ticket_reader.ex:378`). The two tools take the **same** seam and hand it `(method, url, body)`,
  because a write has a body to carry; no call ever uses both directions.

  The empty-list short-circuit is at this entry point as well, ahead of resolving `provider.url`: a
  tracker whose URL is missing still answers `{:ok, []}` for an empty request.
  """
  @spec fetch_issues_by_states([String.t()], map() | keyword()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states([], _settings_or_opts), do: {:ok, []}

  def fetch_issues_by_states(states, settings_or_opts) when is_list(states) do
    with {:ok, query} <- state_query(states) do
      fetch(query, settings_or_opts)
    end
  end

  @doc """
  The tickets with the given ids -- a numeric id or an identifier, as the service reads both --
  complete for the call.

  An empty list is answered with `{:ok, []}` before anything else runs. A value the service cannot
  read fails the whole call, and the error names it: the records that did exist are never returned
  beside it, because an unreadable record and an absent one must not look alike to a scheduler.
  """
  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids([]), do: {:ok, []}

  def fetch_issues_by_ids(issue_ids) when is_list(issue_ids) do
    fetch_issues_by_ids(issue_ids, [])
  end

  @doc """
  `fetch_issues_by_ids/1` with the tracker settings and the transport passed in.

  The argument is the same shape `fetch_issues_by_states/2` takes, and the empty-list
  short-circuit (contract rule 2) is here too.
  """
  @spec fetch_issues_by_ids([String.t()], map() | keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids([], _settings_or_opts), do: {:ok, []}

  def fetch_issues_by_ids(issue_ids, settings_or_opts) when is_list(issue_ids) do
    with {:ok, query} <- id_query(issue_ids) do
      fetch(query, settings_or_opts)
    end
  end

  @doc """
  The names of the environment variables this tracker's credentials travel in: none.

  An empty list is a value, not an exemption. The service is loopback-only and authenticates nobody,
  so no provider credential is ever sent to it and there is nothing for the agent-environment
  binding to redact. The callback is still present and still answers a list, as the contract
  requires of every adapter.
  """
  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(_tracker_settings), do: []

  @doc """
  Validate the tracker block: `provider.url` has to be declared.

  No probe. Whether the service is *up* is a fact about the moment a poll happens; a validation that
  asked would make loading a workflow depend on a reachable service, and would report "the service
  is down" as "this configuration is wrong". Only the URL's presence is checked, so a declared but
  unreachable service fails at fetch time, where that answer belongs.
  """
  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(tracker_settings) when is_map(tracker_settings) do
    if base_url(tracker_settings) do
      :ok
    else
      {:error, :missing_ticket_service_url}
    end
  end

  def validate_config(_tracker_settings), do: {:error, :invalid_ticket_service_settings}

  @doc """
  The read call: `GET url`.

  A failed connection, and anything Req raises around it, is an error value rather than a raise: the
  caller is a poll loop, and "the service did not answer" has to look like a read that failed, not
  like a crashed orchestrator.
  """
  @spec get(String.t()) :: {:ok, %{status: integer(), body: term()}} | {:error, term()}
  def get(url) when is_binary(url), do: request(:get, url, nil)

  @doc """
  The one family of calls that opens a connection: `method` at `url`, with `body` sent as JSON unless
  it is `nil`.

  `get/1` is this with `:get` and no body, so the read path and the two tools share one transport, one
  set of options (`@req_opts`: one timeout, no retry) and one set of error values. A failed connection,
  and anything Req raises around it, is an error value rather than a raise, for the writes as much as
  for the reads: a tool call answers the envelope, never a crashed session.

  Not retried, ever. For the comment that is a correctness rule and not a saving -- see `@req_opts`.
  """
  @spec request(atom(), String.t(), term()) :: {:ok, %{status: integer(), body: term()}} | {:error, term()}
  def request(method, url, body) when is_atom(method) and is_binary(url) do
    case Req.request(Keyword.merge([method: method, url: url] ++ body_options(body), @req_opts)) do
      {:ok, %{status: status, body: answer}} -> {:ok, %{status: status, body: answer}}
      {:error, reason} -> {:error, {:ticket_service_unreachable, reason}}
    end
  rescue
    error -> {:error, {:ticket_service_unreachable, Exception.message(error)}}
  end

  defp body_options(nil), do: []
  defp body_options(body), do: [json: body]

  # ── the agent tools ─────────────────────────────────────────────────────────

  @doc """
  The two tools a service-backed run is offered: `ticket_comment` and `ticket_state`.

  The names, the argument schemas and the return envelope are the file tracker's
  (`SymphonyElixir.Janitor.AgentTool.tool_specs/0`), because one prompt serves every tracker kind: the
  agent says "I am done" without having to know where its ticket lives. What differs is the executor --
  there the host owns the ticket file, here the service owns the row -- and that difference is this
  module's to keep, not the agent's to know.

  The gate tool is not here: it belongs to the project, so the boundary composes it for every kind.
  """
  @spec agent_tool_specs() :: [map()]
  def agent_tool_specs do
    [
      %{
        "name" => @comment_tool,
        "description" => @comment_description,
        "inputSchema" => @comment_input_schema
      },
      %{
        "name" => @state_tool,
        "description" => @state_description,
        "inputSchema" => @state_input_schema
      }
    ]
  end

  @doc """
  Runs one agent tool call over the service's HTTP API.

  `opts` carries `:tracker_settings` (the boundary injects it for a bound call) and `:client`, the
  transport seam the reads take as well -- a write is `client.(method, url, body)` where a read is
  `client.(url)`. It may also carry `:issue`, the ticket this turn is running, which is used when the
  call does not name one. Every test injects a client, so no test opens a socket.

  A call answers the envelope and never raises, as the janitor's tools do: the MCP transport turns an
  exception into a protocol error for the whole session, and a Codex turn only ever sees `success`.
  """
  @spec execute_agent_tool(String.t() | nil, term(), keyword()) :: map()
  def execute_agent_tool(tool, arguments, opts) do
    case tool do
      @comment_tool -> comment(arguments, opts)
      @state_tool -> set_state(arguments, opts)
      other -> unsupported(other)
    end
  rescue
    error -> failure(%{"error" => %{"message" => Exception.message(error)}})
  end

  defp comment(arguments, opts) do
    with ticket when is_binary(ticket) <- ticket_from(arguments, opts),
         body when is_binary(body) <- arguments |> arguments_map() |> Map.get("body") |> presence() do
      payload = %{"author" => @comment_author, "body" => body}

      case write_to_service(:post, ticket, @comments_path, payload, opts) do
        {:ok, answered} -> success(Map.merge(%{"ticket" => ticket}, comment_answer(answered)))
        {:error, reason} -> ticket_failure(ticket, reason)
      end
    else
      _ -> refusal(@comment_tool)
    end
  end

  defp set_state(arguments, opts) do
    with ticket when is_binary(ticket) <- ticket_from(arguments, opts),
         state when is_binary(state) <- arguments |> arguments_map() |> Map.get("state") |> presence() do
      case write_to_service(:patch, ticket, "", %{"state" => state}, opts) do
        {:ok, answered} -> state_answer(ticket, answered)
        {:error, reason} -> ticket_failure(ticket, reason)
      end
    else
      _ -> refusal(@state_tool)
    end
  end

  # One direction of the one transport seam: `client.(method, url, body)` at the service's base URL.
  # The default is `request/3`, the same function `get/1` wraps.
  defp write_to_service(method, ticket, path, payload, opts) do
    with {:ok, url} <- write_url(settings_from(opts), ticket, path) do
      client = Keyword.get(opts, :client, &request/3)

      client.(method, url, payload)
      |> write_response()
    end
  end

  defp write_url(tracker_settings, ticket, path) do
    case base_url(tracker_settings) do
      nil ->
        {:error, :missing_ticket_service_url}

      base ->
        {:ok, String.trim_trailing(base, "/") <> @tickets_path <> "/" <> encode_ref(ticket) <> path}
    end
  end

  # A ref is one path segment, percent-encoded so an identifier carrying a space or a slash cannot turn
  # into two segments. `URI.encode_www_form/1` is deliberately not used: it writes a space as `+`, which
  # is a literal plus in a path and a space only in a query, and this is a path.
  defp encode_ref(ref), do: URI.encode(ref, &URI.char_unreserved?/1)

  # A write's answer, in the error vocabulary the reads already use. `not_found/1` is the read path's
  # own 404 mapping, because "no ticket with identifier X" is one fact whether the ticket was read or
  # written; everything else that is not a 2xx is `{:ticket_service_http, status, body}`, unchanged.
  #
  # A 2xx counts only when its body is an object. These endpoints answer the ticket (PATCH) or the
  # comment (POST), so a body that is not an object is an answer this adapter cannot read -- and a write
  # it cannot see is never reported as one that happened.
  defp write_response({:ok, %{status: status, body: body}}) when status in 200..299 and is_map(body),
    do: {:ok, body}

  defp write_response({:ok, %{status: status, body: body}}) when status in 200..299,
    do: {:error, {:ticket_service_invalid_payload, body}}

  defp write_response({:ok, %{status: 404, body: body}}), do: not_found(body)

  defp write_response({:ok, %{status: status, body: body}}),
    do: {:error, {:ticket_service_http, status, body}}

  # The client's own error, passed through unchanged: the default client already names a connection
  # failure, and a stub that answers an error must be able to prove the adapter does not swallow it.
  defp write_response({:error, reason}), do: {:error, reason}

  # What the service answered, never what was asked for: the PATCH answers the ticket it wrote, and the
  # state that ticket holds is the one reported. A service that could not move the ticket, or a name
  # that maps to a different state, is visible here instead of being papered over with the request.
  #
  # An answer that names no state is a failure rather than a success: this tool exists to report a
  # state, and a PATCH **is** idempotent, so asking again costs nothing -- unlike the comment beside it.
  defp state_answer(ticket, answered) do
    case state_name(answered["state"]) do
      nil -> ticket_failure(ticket, {:ticket_service_invalid_payload, answered})
      state -> success(%{"ticket" => ticket, "state" => state})
    end
  end

  # The comment the service answered: the id it assigned and the author it stored, in the adapter's own
  # field shape, where a null says the service named none.
  #
  # A 2xx is not downgraded to a failure over that, and the reason is not tidiness: a comment is **not
  # idempotent**, so a failure an agent might answer by submitting the same comment again is worse than
  # a thin success -- and the 2xx is the write's truth either way. The non-object body is the one shape
  # that cannot be read at all, and `write_response/1` refuses it above.
  defp comment_answer(answered) do
    %{"comment" => %{"id" => text(answered["id"]), "author" => text(answered["author"])}}
  end

  defp ticket_failure(ticket, reason) do
    failure(%{"error" => %{"message" => describe(reason), "ticket" => ticket}})
  end

  # The refusal an unknown tool gets, in the shape every other adapter refuses one
  # (`Janitor.AgentTool.unsupported_error/1`): the message names the tool, and the answer lists what
  # this adapter would have run.
  defp unsupported(tool) do
    failure(%{
      "error" => %{
        "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
        "supportedTools" => [@comment_tool, @state_tool]
      }
    })
  end

  defp refusal(tool) do
    failure(%{"error" => %{"message" => missing_arguments(tool), "supportedTools" => [tool]}})
  end

  defp missing_arguments(@comment_tool) do
    "#{@comment_tool} needs a ticket identifier and a non-empty body: pass the ticket's identifier, " <>
      "such as SYM-26, together with the text to add."
  end

  defp missing_arguments(@state_tool) do
    "#{@state_tool} needs a ticket identifier and a non-empty state: pass the ticket's identifier, " <>
      "such as SYM-26, together with the state to set."
  end

  # One sentence per error value this adapter can produce, so a run can report what actually happened
  # instead of "an error". The last clause is a catch-all on purpose: a tool call must never raise, and
  # an error value that has not grown a sentence yet still reaches the agent rather than the session.
  defp describe({:ticket_service_ticket_not_found, value}),
    do: "the ticket service has no ticket for #{inspect(value)}"

  defp describe({:ticket_service_http, status, body}),
    do: "the ticket service answered HTTP #{status} with #{inspect(body)}"

  defp describe({:ticket_service_invalid_payload, body}),
    do: "the ticket service answered with a body this adapter cannot read: #{inspect(body)}"

  defp describe({:ticket_service_unreachable, reason}),
    do: "the ticket service could not be reached: #{inspect(reason)}"

  defp describe(:missing_ticket_service_url),
    do: "this tracker declares no provider.url, so there is no ticket service to call"

  defp describe(other), do: inspect(other)

  defp ticket_from(arguments, opts) do
    named = arguments |> arguments_map() |> Map.get("ticket") |> presence()

    named || issue_identifier(Keyword.get(opts, :issue))
  end

  defp arguments_map(arguments) when is_map(arguments), do: arguments
  defp arguments_map(_arguments), do: %{}

  # The identifier, never the service's numeric id: the identifier is the name the agent was given and
  # the name every layer carries, and this adapter reads and writes a ticket by one name.
  defp issue_identifier(%{identifier: identifier}), do: presence(identifier)
  defp issue_identifier(_issue), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp success(payload), do: dynamic_tool_response(true, payload)
  defp failure(payload), do: dynamic_tool_response(false, payload)

  defp dynamic_tool_response(success, payload) do
    output =
      case Jason.encode(payload, pretty: true) do
        {:ok, encoded} -> encoded
        {:error, _reason} -> inspect(payload)
      end

    %{
      "success" => success,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  # ── the request ─────────────────────────────────────────────────────────────

  defp fetch(query, settings_or_opts) do
    opts = options(settings_or_opts)
    tracker_settings = settings_from(opts)

    with {:ok, url} <- request_url(tracker_settings, query) do
      read(url, tracker_settings, opts)
    end
  end

  # The tracker block to act on: the one passed in, or the workflow's. Read here rather than inline in
  # two places, so a read and a write can never end up at two different services.
  defp settings_from(opts), do: Keyword.get(opts, :tracker_settings) || Config.settings!().tracker

  # Two documented forms, one code path: the settings map (the shape the file adapter takes) and a
  # keyword list of options (the shape `ProjectStatus.list/1` takes).
  defp options(%{} = tracker_settings), do: [tracker_settings: tracker_settings]
  defp options(opts) when is_list(opts), do: opts

  defp request_url(tracker_settings, query) do
    case base_url(tracker_settings) do
      nil -> {:error, :missing_ticket_service_url}
      base -> {:ok, String.trim_trailing(base, "/") <> @tickets_path <> "?" <> query}
    end
  end

  # The read direction of the transport seam: the client is handed the URL alone. It is called
  # `read/3`, not `request/3`, so the public transport function keeps the name that says "the one place
  # a connection is opened".
  defp read(url, tracker_settings, opts) do
    client = Keyword.get(opts, :client, &get/1)

    client.(url)
    |> handle_response(tracker_settings)
  end

  defp handle_response({:ok, %{status: status, body: body}}, tracker_settings)
       when status in 200..299 do
    tickets(body, tracker_settings)
  end

  defp handle_response({:ok, %{status: 404, body: body}}, _tracker_settings), do: not_found(body)

  defp handle_response({:ok, %{status: status, body: body}}, _tracker_settings) do
    {:error, {:ticket_service_http, status, body}}
  end

  # The client's own error, passed through unchanged: the default client already names a connection
  # failure, and a stub that answers an error must be able to prove the adapter does not swallow it.
  defp handle_response({:error, reason}, _tracker_settings), do: {:error, reason}

  # A body that is not the list shape -- a binary Req could not decode, a JSON object without
  # "tickets", a list -- is one error rather than a partial read: guessing at what a body meant is
  # how a scheduler ends up believing a short list.
  defp tickets(%{"tickets" => rows}, tracker_settings) when is_list(rows) do
    if Enum.all?(rows, &is_map/1) do
      {:ok, Enum.map(rows, &to_issue(&1, tracker_settings))}
    else
      {:error, :ticket_service_malformed_ticket}
    end
  end

  defp tickets(body, _tracker_settings), do: {:error, {:ticket_service_invalid_payload, body}}

  defp not_found(body) do
    case offender(body) do
      nil -> {:error, {:ticket_service_http, 404, body}}
      value -> {:error, {:ticket_service_ticket_not_found, value}}
    end
  end

  defp offender(%{"error" => %{"message" => message}}) when is_binary(message) do
    case Regex.run(@missing_ticket, message) do
      [_, value] -> String.trim(value, "\"")
      nil -> nil
    end
  end

  defp offender(_body), do: nil

  # `?state=a&state=b`, never `?state=a,b` and never a list encoding Req might choose: the service
  # reads repeated scalar parameters from the raw query string, and both spellings it accepts start
  # with this one.
  defp state_query(states) do
    if Enum.all?(states, &is_binary/1) do
      {:ok, Enum.map_join(states, "&", &("state=" <> URI.encode_www_form(&1)))}
    else
      {:error, :invalid_ticket_service_states}
    end
  end

  # `?ids=a,b`, with each token encoded separately, so a token that carries a comma or a space
  # cannot turn one value into two.
  defp id_query(issue_ids) do
    if Enum.all?(issue_ids, &is_binary/1) do
      {:ok, "ids=" <> Enum.map_join(issue_ids, ",", &URI.encode_www_form/1)}
    else
      {:error, :invalid_ticket_service_ids}
    end
  end

  # ── the service's JSON, as the issue struct ─────────────────────────────────

  defp to_issue(row, tracker_settings) do
    issue = %Issue{
      id: text(row["id"]),
      identifier: text(row["identifier"]),
      title: text(row["title"]),
      description: body(row["description"]),
      state: state_name(row["state"]),
      priority: to_integer(row["priority"]),
      assignee_id: text(row["assignee"]),
      branch_name: text(row["branch_name"]),
      url: text(row["url"]),
      labels: labels(row["labels"]),
      blocked_by: blockers(row),
      created_at: to_datetime(row["created_at"]),
      updated_at: to_datetime(row["updated_at"])
    }

    apply_dispatch_gate(issue, row["dispatchable"], tracker_settings)
  end

  # A state is an object on this surface (`presenter.ex:65-69`): the name is the machine name the
  # workflow's `active_states` / `terminal_states` lists are written in, which is the value the
  # scheduler branches on. The type is the service's own scheduling vocabulary and is not needed
  # here -- importing it would be a second vocabulary to keep in step.
  defp state_name(%{"name" => name}) when is_binary(name), do: text(name)
  defp state_name(_state), do: nil

  # A name is a field: trimmed, and a blank one is nil. A description is the body of the ticket and
  # is passed on exactly as the service holds it -- trimming a body is an edit nobody asked for.
  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(value) when is_integer(value), do: Integer.to_string(value)
  defp text(_value), do: nil

  defp body(value) when is_binary(value), do: value
  defp body(_value), do: nil

  # Labels are not normalized here. The store keeps the name it was given, and `Issue.routable?/2`
  # normalizes both sides of every comparison anyway -- so a second normalizer in this adapter would
  # only make the adapter's answer differ from the service's own.
  defp labels(values) when is_list(values), do: Enum.filter(values, &is_binary/1)
  defp labels(_values), do: []

  # A list row carries the live relations it was read with (`presenter.ex:52-86`), each with the
  # blocker's identifier and the blocker's state, so the gate below can be applied from one poll
  # instead of a call per ticket. The ref shape is the file adapter's (`file.ex:407-427`):
  # `%{id:, identifier:, state:}`, never a bare name.
  defp blockers(row) do
    case row["blockers"] do
      relations when is_list(relations) ->
        relations
        |> Enum.reject(&resolved?/1)
        |> Enum.map(&blocker_ref/1)
        |> Enum.reject(&is_nil/1)

      _other ->
        # The identifier-only form, for a row read before the live relations were rendered. A
        # blocker whose state cannot be seen blocks, which is the same answer the file adapter gives
        # for an absent blocker state.
        row
        |> Map.get("blocked_by", [])
        |> List.wrap()
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&%{id: &1, identifier: &1, state: nil})
    end
  end

  defp resolved?(%{"resolved" => true}), do: true
  defp resolved?(_relation), do: false

  defp blocker_ref(relation) when is_map(relation) do
    identifier = text(relation["blocker_identifier"])

    if identifier do
      %{id: identifier, identifier: identifier, state: state_name(relation["blocker_state"])}
    end
  end

  defp blocker_ref(_relation), do: nil

  # The file adapter's rule, mirrored rather than reinvented (`file.ex:223-253`): a ticket is held
  # back while it sits in the workflow's **first** active state and any of its blockers is not
  # terminal. The order of `active_states` is load-bearing for the same reason it is there, and a
  # blocker whose state cannot be seen blocks, exactly as an absent blocker state does in Linear.
  #
  # The service's stored `dispatchable` column is a second gate, never a substitute: the two answers
  # are combined with `and`, so the stricter one wins. A stored `false` is a person's "not this one"
  # and must not be overridden by an adapter that found no blockers; the derived blocker rule is the
  # gate the column cannot lift.
  defp apply_dispatch_gate(issue, stored_dispatchable, tracker_settings) do
    blockers = issue.blocked_by || []

    blocked? =
      blockers != [] and gating_state?(issue.state, tracker_settings) and
        Enum.any?(blockers, &(not terminal_state?(&1, tracker_settings)))

    %{issue | dispatchable: stored_dispatchable == true and not blocked?}
  end

  defp gating_state?(state, %{active_states: [first | _]}) when is_binary(first) do
    normalize_state(state) == normalize_state(first)
  end

  defp gating_state?(_state, _tracker_settings), do: false

  defp terminal_state?(%{state: state}, tracker_settings) when is_binary(state) do
    terminal = Map.get(tracker_settings, :terminal_states) || []

    terminal
    |> Enum.map(&normalize_state/1)
    |> Enum.member?(normalize_state(state))
  end

  defp terminal_state?(_blocker, _tracker_settings), do: false

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: ""

  # ── values ──────────────────────────────────────────────────────────────────

  # The store's timestamps are milliseconds since the epoch (`store.ex:47`), so the unit is stated
  # here rather than guessed at.
  defp to_datetime(value) when is_integer(value) do
    case DateTime.from_unix(value, :millisecond) do
      {:ok, datetime} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp to_datetime(_value), do: nil

  # An integer or nil, and a quoted integer is accepted for the same reason the file adapter accepts
  # one: a hand-written ticket may quote it. A float is not an integer, and a string with anything
  # after the number is not one either -- truncating either would invent a priority nobody wrote.
  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _other -> nil
    end
  end

  defp to_integer(_value), do: nil

  # ── the tracker settings ────────────────────────────────────────────────────

  defp base_url(tracker_settings) do
    provider_settings = provider(tracker_settings)
    text(provider_settings["url"] || provider_settings[:url])
  end

  defp provider(%{provider: provider}) when is_map(provider), do: provider
  defp provider(_tracker_settings), do: %{}
end
