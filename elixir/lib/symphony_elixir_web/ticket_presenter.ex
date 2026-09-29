defmodule SymphonyElixirWeb.TicketPresenter do
  @moduledoc """
  Reads the queue's tickets for the control plane's ticket view.

  Read-only on purpose: state changes and comments are made by the agent and the host (the janitor),
  not by this UI, so nothing here writes a ticket.

  ## Where each field comes from

  Two sources, deliberately:

    * the **list-level fields** -- state, priority, labels, assignee, blockers (with each blocker's own
      state), branch name, adapter/model -- come from `SymphonyElixir.Tracker.File.tickets/1`, i.e. the
      same parse the dispatcher uses, so the board and the scheduler cannot disagree about what a
      ticket says;
    * the **Markdown body**, the `## Discussion` entries and the `links:` list are read from the
      ticket file itself, because the tracker's `Issue` carries none of them. `links:` is where the
      janitor records the pull request it opened for the ticket (`Ticket.add_link/4`).

  The directory is scanned **once** per call and indexed by front-matter id and by file stem: the
  tracker reports identifiers, not paths, and a per-ticket scan would make a board of N tickets cost
  N directory listings.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Janitor.Ticket
  alias SymphonyElixir.Tracker.File, as: FileTracker

  @type ticket :: map()
  @type discussion_entry :: %{author: String.t(), at: String.t(), id: String.t(), text: String.t()}

  # `links: [{url: "https://...", title: "PR #12", kind: pr}]` -- the shape `Ticket.add_link/4` writes.
  @link_regex ~r/\{url:\s*"([^"]*)",\s*title:\s*"([^"]*)",\s*kind:\s*"?([A-Za-z_-]+)"?\}/
  # `- **author** (2026-01-01T00:00:00Z, id=local-1): text` -- the shape `Ticket.comment_line/4` writes.
  @comment_regex ~r/^-\s+\*\*(.+?)\*\*\s+\(([^)]*)\):\s*(.*)$/
  @discussion_regex ~r/^##\s*Discussion\s*$\n(.*?)(?=^##\s|\z)/ms

  @doc """
  Every ticket in the configured queue, sorted by identifier.
  """
  @spec list() :: {:ok, [ticket()]} | {:error, term()}
  def list do
    with {:ok, tickets} <- load() do
      {:ok, Enum.sort_by(tickets, & &1.identifier)}
    end
  end

  @doc """
  One ticket by identifier (its front-matter `id` also matches).
  """
  @spec fetch(String.t()) :: {:ok, ticket()} | {:error, :not_found | term()}
  def fetch(identifier) when is_binary(identifier) do
    with {:ok, tickets} <- load() do
      case Enum.find(tickets, &(&1.identifier == identifier or &1.id == identifier)) do
        nil -> {:error, :not_found}
        ticket -> {:ok, ticket}
      end
    end
  end

  @doc """
  A short, printable form of a read error, for a page that must still render.
  """
  @spec describe(term()) :: String.t()
  def describe({:ticket_read_failed, message}) when is_binary(message), do: message
  def describe({:file_tracker_path_not_found, path}), do: "the ticket directory does not exist: #{path}"
  def describe(:missing_file_tracker_path), do: "the workflow does not configure a ticket directory"
  def describe(reason), do: inspect(reason)

  defp load do
    settings = Config.settings!().tracker
    dir = provider_path(settings)

    case FileTracker.tickets(settings) do
      {:ok, issues} ->
        index = file_index(dir)
        {:ok, Enum.map(issues, &to_ticket(&1, index))}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, {:ticket_read_failed, Exception.message(error)}}
  end

  defp provider_path(%{provider: provider}) when is_map(provider) do
    case provider["path"] || provider[:path] do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _other -> nil
    end
  end

  defp provider_path(_settings), do: nil

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

  defp to_ticket(issue, index) do
    entry = Map.get(index, issue.identifier) || Map.get(index, issue.id) || %{}
    text = Map.get(entry, :text)
    links = links(text)

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
      model: Map.get(issue, :model),
      description: description(issue),
      discussion: discussion(text),
      links: links,
      pr_url: pr_url(links),
      path: Map.get(entry, :path)
    }
  end

  defp blocker(%{identifier: identifier, state: state}), do: %{identifier: identifier, state: state}
  defp blocker(other), do: %{identifier: to_string(other), state: nil}

  # The tracker's `description` is the ticket body when the front matter does not override it, and the
  # body carries the `## Discussion` section -- which the comments panel shows on its own. Cutting it
  # here is what keeps a comment from appearing twice on one page.
  defp description(issue) do
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
end
