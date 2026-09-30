defmodule SymphonyElixir.Tracker.TicketService do
  @moduledoc """
  The ticket service as a tracker: a reader over the standalone service's HTTP surface.

  `symphony-tickets` owns tickets in its own SQLite database and answers a small JSON surface over
  loopback HTTP (default port 4020, `docs/ticket-service-spec.md` section 4). This module is the one
  place that translates that surface into `SymphonyElixir.Tracker.Issue` structs, so the orchestrator
  polls it exactly as it polls Linear or GitHub.

  It is a **reader**. Nothing here writes a ticket, and no agent tool is advertised: writing from an
  agent is a separate decision, and a reader that silently gained a writer would be taking it.

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

  ## The two calls this adapter makes

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
  @req_opts [receive_timeout: @timeout_ms, retry: false]

  @tickets_path "/tickets"

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
  The one call that opens a connection.

  A failed connection, and anything Req raises around it, is an error value rather than a raise: the
  caller is a poll loop, and "the service did not answer" has to look like a read that failed, not
  like a crashed orchestrator.
  """
  @spec get(String.t()) :: {:ok, %{status: integer(), body: term()}} | {:error, term()}
  def get(url) when is_binary(url) do
    case Req.get(url, @req_opts) do
      {:ok, %{status: status, body: body}} -> {:ok, %{status: status, body: body}}
      {:error, reason} -> {:error, {:ticket_service_unreachable, reason}}
    end
  rescue
    error -> {:error, {:ticket_service_unreachable, Exception.message(error)}}
  end

  # ── the request ─────────────────────────────────────────────────────────────

  defp fetch(query, settings_or_opts) do
    opts = options(settings_or_opts)
    tracker_settings = Keyword.get(opts, :tracker_settings) || Config.settings!().tracker

    with {:ok, url} <- request_url(tracker_settings, query) do
      request(url, tracker_settings, opts)
    end
  end

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

  defp request(url, tracker_settings, opts) do
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
