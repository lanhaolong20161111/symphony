defmodule SymphonyElixirWeb.TicketReader do
  @moduledoc """
  Where a ticket comes from, per tracker kind -- the one seam the ticket pages read through.

  The console's ticket pages are the project's Linear-shaped view: a board and one ticket's page.
  The board's fields come from whichever adapter the workflow configures, but a ticket's **body** and
  its **discussion** are a deeper read than a list: only some trackers answer them at all, and the two
  that do answer them in different ways. This module is where that difference lives, so the presenter
  resolves the tracker settings once and then calls one function, rather than branching on the kind in
  every place that needs a field.

  ## One function per question, two kinds behind it

  `list/2` answers the board's question -- every ticket, with the fields a list row carries.
  `fetch/3` answers the page's question -- **one** ticket, with its body, its discussion and its
  links. `states/2` and `queue_path/1` answer the two questions both pages ask about the tracker
  itself: which states its workflow declares, and where its tickets live on disk.

  The two kinds this console reads:

    * **`file`** -- today's contract, unchanged. The list is `SymphonyElixir.Tracker.File.tickets/1`,
      i.e. the same parse the dispatcher uses, so the board and the scheduler cannot disagree about
      what a ticket says. The body, the `## Discussion` entries and the `links:` list are read from
      the ticket file itself, because the tracker's `Issue` carries none of them. The directory is
      scanned **once** per read and indexed by front-matter id and by file stem: the tracker reports
      identifiers, not paths, and a per-ticket scan would make a board of N tickets cost N directory
      listings.
    * **`ticket_service`** -- the deep read is the service's own call. `GET {provider.url}/tickets?state=`
      for the list, and `GET {provider.url}/tickets/:ref` for one ticket: that one answer carries the
      ticket with its labels, blockers, attachments and comments, which is what makes it a deep read
      rather than a list row. Its store answers a ticket's comments oldest first (`store.ex:996`), and
      that order is kept: the page shows them in the order a conversation is read in.

  ## A kind that cannot be read here says so

  Every other kind -- `linear`, `github`, `jira`, `asana`, `gitlab`, `memory` -- answers
  `{:error, {:ticket_kind_not_readable, kind}}`, and the page renders that reason. It is deliberately
  not an empty list and not an empty body: an empty board reads as "no work to do" and an empty
  description reads as "this ticket has no description", and both invite someone to redo work that is
  already done. Those adapters read their issues through the **running** instance's configuration
  (`SymphonyElixir.Tracker.adapter/0` reads `Config.settings!()`), so a named registry project could
  not be read through one anyway -- it would read whichever queue happens to be this instance's. A
  refusal that names the kind is honest; a read of the wrong queue is not.

  ## The transport, injected

  `:client` replaces the HTTP call for a `ticket_service` tracker -- the same shape
  `SymphonyElixir.Tracker.TicketService` takes: it is handed the URL and answers
  `{:ok, %{status: integer(), body: term()}}` or `{:error, term()}`. The default is
  `TicketService.get/1`, which is the only function here that opens a connection, so no test needs a
  socket. A client answers the same error tuples the adapter produces (`{:ticket_service_unreachable,
  reason}` and friends), and they are passed through unchanged: a page has to render the reason rather
  than an empty ticket.
  """

  alias SymphonyElixir.Janitor.Ticket
  alias SymphonyElixir.Tracker.File, as: FileTracker
  alias SymphonyElixir.Tracker.TicketService

  @type ticket :: map()

  # `links: [{url: "https://...", title: "PR #12", kind: pr}]` -- the shape `Ticket.add_link/4` writes.
  @link_regex ~r/\{url:\s*"([^"]*)",\s*title:\s*"([^"]*)",\s*kind:\s*"?([A-Za-z_-]+)"?\}/
  # `- **author** (2026-01-01T00:00:00Z, id=local-1): text` -- the shape `Ticket.comment_line/4` writes.
  @comment_regex ~r/^-\s+\*\*(.+?)\*\*\s+\(([^)]*)\):\s*(.*)$/
  @discussion_regex ~r/^##\s*Discussion\s*$\n(.*?)(?=^##\s|\z)/ms

  # The service's 404 names the value that could not be read ("no ticket with id 7", "no ticket with
  # identifier \"SYM-9\"": `symphony_tickets_web/store_error.ex:45-48`). The same pattern the adapter
  # keeps privately, repeated here because this slice may not change the adapter: a 404 whose body does
  # not name a value is a route answer, and calling that "no such ticket" would be a claim this reader
  # cannot support.
  @missing_ticket ~r/\Ano ticket with (?:id|identifier) (.*)\z/

  @tickets_path "/tickets"

  @doc """
  Every ticket the configured tracker holds, in the shape the pages render.

  A list read is a list read: for a `ticket_service` tracker the row carries its own description but no
  comments, because the list endpoint does not read them -- `fetch/3` is the call that answers a
  ticket's body and discussion. A `file` read answers both either way, because a file's body and its
  discussion are in the file the read has already opened.
  """
  @spec list(map(), keyword()) :: {:ok, [ticket()]} | {:error, term()}
  def list(tracker_settings, opts \\ []) do
    with {:ok, source} <- source(tracker_settings) do
      reads(source, tracker_settings, opts)
    end
  end

  @doc """
  One ticket, with its body, its discussion and its links -- the page's read.

  For a `file` tracker this is the list read with one ticket taken out of it, which is what the page
  has always done. For a `ticket_service` tracker it is the service's deep read
  (`GET {url}/tickets/:ref`), so the page costs one request and gets the comments with the ticket.

  A service answer that says the ticket is not there is `{:error, :not_found}`; every other failure is
  passed through with its reason, so a page can render it instead of an empty ticket.
  """
  @spec fetch(map(), String.t(), keyword()) :: {:ok, ticket()} | {:error, :not_found | term()}
  def fetch(tracker_settings, identifier, opts \\ []) when is_binary(identifier) do
    with {:ok, source} <- source(tracker_settings) do
      one(source, tracker_settings, identifier, opts)
    end
  end

  @doc """
  The states the tracker's workflow declares, in its own order, deduplicated, blanks dropped.

  `:active` first, then `:terminal` for `:all` (the default) -- the order `active_states` was written
  in is load-bearing (`tracker/file.ex`), and it is the order a `ticket_service` read is asked in.

  From the workflow rather than from a list written here: those two lists are the scheduler's dispatch
  vocabulary, and a state nobody declared is a ticket nothing picks up again.
  """
  @spec states(map(), :all | :active | :terminal) :: [String.t()]
  def states(tracker_settings, which \\ :all) do
    which
    |> state_keys()
    |> Enum.flat_map(&declared(Map.get(tracker_settings, &1)))
    |> Enum.uniq()
  end

  @doc """
  Where this tracker's tickets live on disk, or `nil` when it is not a file queue.

  The presenter's write seam reads this too: a write made while reading a named project has to land in
  that project's queue, and one resolver for that path is one place it can be wrong.
  """
  @spec queue_path(map()) :: String.t() | nil
  def queue_path(%{provider: provider}) when is_map(provider) do
    case provider["path"] || provider[:path] do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _other -> nil
    end
  end

  def queue_path(_tracker_settings), do: nil

  defp state_keys(:active), do: [:active_states]
  defp state_keys(:terminal), do: [:terminal_states]
  defp state_keys(:all), do: [:active_states, :terminal_states]

  defp declared(states) do
    states
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
  end

  # ---- which tracker is this ----

  defp source(%{kind: "file"}), do: {:ok, :file}
  defp source(%{kind: "ticket_service"}), do: {:ok, :service}

  defp source(%{kind: kind}) when is_binary(kind) and kind != "" do
    {:error, {:ticket_kind_not_readable, kind}}
  end

  defp source(_tracker_settings), do: {:error, :invalid_tracker_settings}

  # ---- the file tracker ----

  defp reads(:file, tracker_settings, _opts) do
    with {:ok, issues} <- FileTracker.tickets(tracker_settings) do
      index = file_index(queue_path(tracker_settings))
      {:ok, Enum.map(issues, &file_ticket(&1, index))}
    end
  end

  defp reads(:service, tracker_settings, opts), do: service_tickets(tracker_settings, opts)

  defp one(:file, tracker_settings, identifier, _opts) do
    with {:ok, tickets} <- reads(:file, tracker_settings, []) do
      case Enum.find(tickets, &(&1.identifier == identifier or &1.id == identifier)) do
        nil -> {:error, :not_found}
        ticket -> {:ok, ticket}
      end
    end
  end

  defp one(:service, tracker_settings, identifier, opts) do
    service_ticket(tracker_settings, identifier, opts)
  end

  # One listing and one read per file. A file whose front matter does not parse is not a ticket, so it
  # is simply not in the index (the tracker skips the same files, which is how README.md lives beside
  # the queue).
  defp file_index(nil), do: %{}

  defp file_index(dir) do
    case File.ls(dir) do
      {:ok, names} -> names |> Enum.filter(&ticket_file?/1) |> Enum.reduce(%{}, &index_file(dir, &1, &2))
      {:error, _reason} -> %{}
    end
  end

  defp ticket_file?(name), do: String.ends_with?(name, ".md") and not String.starts_with?(name, "BOARD-")

  defp index_file(dir, name, acc) do
    path = Path.join(dir, name)

    with {:ok, text} <- File.read(path),
         {:ok, %{front_matter: front_matter, body: body}} <- Ticket.split(text) do
      entry = %{path: path, body: body || "", text: text}
      id = Ticket.get(front_matter, "id")

      acc
      |> Map.put(Path.rootname(name), entry)
      |> put_id(id, entry)
    else
      _other -> acc
    end
  end

  defp put_id(acc, "", _entry), do: acc
  defp put_id(acc, id, entry), do: Map.put(acc, id, entry)

  defp file_ticket(issue, index) do
    entry = Map.get(index, issue.identifier) || Map.get(index, issue.id) || %{}
    text = Map.get(entry, :text)
    links = links(text)

    issue
    |> base_ticket()
    |> Map.merge(%{
      tracker: :file,
      description: file_description(issue),
      discussion: discussion(text),
      links: links,
      pr_url: pr_url(links),
      path: Map.get(entry, :path)
    })
  end

  # The tracker's `description` is the ticket body when the front matter does not override it, and the
  # body carries the `## Discussion` section -- which the comments panel shows on its own. Cutting it
  # here is what keeps a comment from appearing twice on one page.
  defp file_description(issue) do
    (issue.description || "")
    |> strip_discussion()
    |> String.trim()
  end

  defp strip_discussion(body) do
    case Regex.run(~r/\A(.*?)(?=^##\s*Discussion\s*$)/ms, body) do
      [_, head] -> head
      _other -> body
    end
  end

  defp links(nil), do: []

  defp links(text) do
    case Ticket.split(text) do
      {:ok, %{front_matter: front_matter}} -> front_matter |> Ticket.get("links") |> parse_links()
      :skip -> []
    end
  end

  defp parse_links(""), do: []

  defp parse_links(value) do
    @link_regex
    |> Regex.scan(value)
    |> Enum.map(fn [_, url, title, kind] -> %{url: url, title: title, kind: kind} end)
  end

  defp pr_url(links) do
    links
    |> Enum.find(&pull_request?/1)
    |> case do
      nil -> nil
      link -> link.url
    end
  end

  defp pull_request?(%{kind: kind, url: url}) do
    kind in ["pr", "pull_request", "pull-request"] or String.contains?(url || "", "/pull/")
  end

  defp discussion(nil), do: []

  defp discussion(text) do
    case Regex.run(@discussion_regex, text) do
      [_, section] -> section |> String.split("\n") |> Enum.flat_map(&parse_comment/1)
      _other -> []
    end
  end

  defp parse_comment(line) do
    case Regex.run(@comment_regex, line) do
      [_, author, meta, text] ->
        [%{author: author, at: comment_timestamp(meta), id: comment_id(meta), text: String.trim(text)}]

      _other ->
        []
    end
  end

  defp comment_timestamp(meta), do: meta |> String.split(", id=") |> List.first() |> String.trim()

  defp comment_id(meta) do
    case Regex.run(~r/id=([^,\s]+)/, meta) do
      [_, id] -> id
      _other -> ""
    end
  end

  # ---- the ticket service ----

  defp service_tickets(tracker_settings, opts) do
    with {:ok, states} <- service_states(tracker_settings),
         {:ok, issues} <-
           TicketService.fetch_issues_by_states(states, service_options(tracker_settings, opts)) do
      {:ok, Enum.map(issues, &service_row_ticket/1)}
    end
  end

  # A workflow that declares no state asks the service for nothing, and the service answers an empty
  # request with an empty list before it reads anything (contract rule 2). That empty list would reach
  # the board as an empty board, which reads as "no work to do" -- so it is refused here instead.
  defp service_states(tracker_settings) do
    case states(tracker_settings) do
      [] -> {:error, :no_ticket_service_states}
      declared -> {:ok, declared}
    end
  end

  defp service_options(tracker_settings, opts) do
    [tracker_settings: tracker_settings] ++ non_nil(Keyword.take(opts, [:client]))
  end

  defp non_nil(opts), do: Enum.reject(opts, fn {_key, value} -> is_nil(value) end)

  # A list row: the service read it with its labels and its live blocks, and it carries its own
  # description. Its comments are `[]` because the list endpoint did not read them, not because there
  # are none -- which is why `fetch/3` is the call a page makes.
  defp service_row_ticket(issue) do
    issue
    |> base_ticket()
    |> Map.merge(%{
      tracker: :service,
      description: service_description(issue.description),
      discussion: [],
      links: [],
      pr_url: nil,
      path: nil
    })
  end

  defp service_ticket(tracker_settings, identifier, opts) do
    with {:ok, url} <- service_ticket_url(tracker_settings, identifier),
         {:ok, row} <- service_get(url, opts) do
      service_ticket_from_row(row)
    end
  end

  defp service_ticket_url(tracker_settings, identifier) do
    provider = provider(tracker_settings)

    case provider["url"] || provider[:url] do
      url when is_binary(url) and url != "" ->
        {:ok, String.trim_trailing(url, "/") <> @tickets_path <> "/" <> URI.encode_www_form(identifier)}

      _other ->
        {:error, :missing_ticket_service_url}
    end
  end

  defp provider(%{provider: provider}) when is_map(provider), do: provider
  defp provider(_tracker_settings), do: %{}

  # The one call that can open a connection, and the one place a stub takes its place. A client that
  # raises is answered as a read that failed rather than a page that came down.
  defp service_get(url, opts) do
    client = Keyword.get(opts, :client) || (&TicketService.get/1)

    client.(url)
    |> service_body()
  rescue
    error -> {:error, {:ticket_read_failed, Exception.message(error)}}
  end

  # The body is handed on unparsed: what it means is `service_ticket_from_row/1`'s answer, and one
  # parser is one place a body can be read wrongly.
  defp service_body({:ok, %{status: status, body: body}}) when status in 200..299, do: {:ok, body}
  defp service_body({:ok, %{status: 404, body: body}}), do: service_missing(body)

  defp service_body({:ok, %{status: status, body: body}}) do
    {:error, {:ticket_service_http, status, body}}
  end

  defp service_body({:ok, other}), do: {:error, {:ticket_service_invalid_payload, other}}
  defp service_body({:error, reason}), do: {:error, reason}
  defp service_body(other), do: {:error, {:ticket_service_unreachable, other}}

  defp service_missing(body) do
    case offender(body) do
      nil -> {:error, {:ticket_service_http, 404, body}}
      _value -> {:error, :not_found}
    end
  end

  defp offender(%{"error" => %{"message" => message}}) when is_binary(message) do
    case Regex.run(@missing_ticket, message) do
      [_, _value] -> message
      nil -> nil
    end
  end

  defp offender(_body), do: nil

  # The deep read is only a ticket when it names one. A JSON object that carries no identifier -- an
  # error envelope answered with 200, a body a client decoded wrongly -- is refused rather than
  # rendered as a ticket with nothing in it.
  defp service_ticket_from_row(%{"identifier" => identifier} = row) when is_binary(identifier) do
    ticket =
      row
      |> base_service_ticket()
      |> Map.merge(%{
        tracker: :service,
        description: service_description(row["description"]),
        discussion: comments(row["comments"]),
        links: [],
        pr_url: nil,
        path: nil
      })

    {:ok, ticket}
  end

  defp service_ticket_from_row(body), do: {:error, {:ticket_service_invalid_payload, body}}

  defp base_service_ticket(row) do
    %{
      identifier: text(row["identifier"]),
      id: text(row["id"]),
      title: text(row["title"]),
      state: state_name(row["state"]),
      priority: to_integer(row["priority"]),
      labels: labels(row["labels"]),
      assignee: text(row["assignee"]),
      blocked_by: blocker_refs(row),
      branch_name: text(row["branch_name"]),
      url: text(row["url"]),
      adapter: nil,
      model: nil
    }
  end

  # A body is passed on as the service holds it, trimmed only because the page has always trimmed the
  # file tracker's body: whitespace around a body is not part of what it says.
  defp service_description(value) when is_binary(value), do: String.trim(value)
  defp service_description(_value), do: nil

  # A state is an object on this surface (`presenter.ex:65-69`). `name` is the machine name the
  # workflow's `active_states` / `terminal_states` lists are written in, which is the value both pages
  # and the scheduler branch on; `type` is the service's own scheduling vocabulary and is not needed
  # here.
  defp state_name(%{"name" => name}) when is_binary(name), do: text(name)
  defp state_name(_state), do: nil

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(value) when is_integer(value), do: Integer.to_string(value)
  defp text(_value), do: nil

  defp labels(values) when is_list(values), do: Enum.filter(values, &is_binary/1)
  defp labels(_values), do: []

  # The live blocks only, each as `%{identifier:, state:}`: a resolved block is history, and the
  # page's "Blocked by" panel asks which blocker holds this ticket back now. A body read before the
  # live relations were rendered carries `blocked_by` as bare identifiers instead, which is the same
  # answer with the blocker's state unknown.
  defp blocker_refs(row) do
    case row["blockers"] do
      relations when is_list(relations) ->
        relations
        |> Enum.reject(&resolved?/1)
        |> Enum.map(&blocker_ref/1)
        |> Enum.reject(&is_nil/1)

      _other ->
        row
        |> Map.get("blocked_by", [])
        |> List.wrap()
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&%{identifier: &1, state: nil})
    end
  end

  defp resolved?(%{"resolved" => true}), do: true
  defp resolved?(_relation), do: false

  defp blocker_ref(relation) when is_map(relation) do
    case text(relation["blocker_identifier"]) do
      nil -> nil
      identifier -> %{identifier: identifier, state: state_name(relation["blocker_state"])}
    end
  end

  defp blocker_ref(_relation), do: nil

  # The store answers a ticket's comments ordered by `created_at, id` (`store.ex:996`), oldest first,
  # and that order is kept: the page shows them in the order a conversation is read in.
  defp comments(values) when is_list(values) do
    values
    |> Enum.map(&comment/1)
    |> Enum.reject(&is_nil/1)
  end

  defp comments(_values), do: []

  # A comment always has an author (the store requires one), so a row without one is a row this reader
  # cannot read as written -- it says so rather than leaving the panel's Author column blank.
  defp comment(row) when is_map(row) do
    %{
      author: text(row["author"]) || "unknown",
      at: comment_at(row["created_at"]),
      id: text(row["id"]) || "",
      text: comment_text(row["body"])
    }
  end

  defp comment(_row), do: nil

  defp comment_text(body) when is_binary(body), do: String.trim(body)
  defp comment_text(_body), do: ""

  # The store's timestamps are milliseconds since the epoch (`store.ex:47`), and the page's `At`
  # column shows the same ISO-8601 shape the file tracker's comment lines carry.
  defp comment_at(value) when is_integer(value) do
    case DateTime.from_unix(value, :millisecond) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      {:error, _reason} -> Integer.to_string(value)
    end
  end

  defp comment_at(value) when is_binary(value), do: value
  defp comment_at(_value), do: ""

  # ---- what a ticket is, either way ----

  defp base_ticket(issue) do
    %{
      identifier: issue.identifier,
      id: issue.id,
      title: issue.title,
      state: issue.state,
      priority: issue.priority,
      labels: issue.labels || [],
      assignee: issue.assignee_id,
      blocked_by: Enum.map(issue.blocked_by || [], &blocker/1),
      branch_name: issue.branch_name,
      url: issue.url,
      adapter: Map.get(issue, :adapter),
      model: Map.get(issue, :model)
    }
  end

  defp blocker(%{identifier: identifier, state: state}), do: %{identifier: identifier, state: state}
  defp blocker(other), do: %{identifier: to_string(other), state: nil}

  # An integer or nil, and a quoted integer is accepted for the same reason the adapter accepts one: a
  # hand-written ticket may quote it. A float is not an integer, and a string with anything after the
  # number is not one either -- truncating either would invent a priority nobody wrote.
  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _other -> nil
    end
  end

  defp to_integer(_value), do: nil
end
