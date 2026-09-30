defmodule SymphonyElixirWeb.TicketPresenter do
  @moduledoc """
  Reads the queue's tickets for the control plane's ticket view.

  Read-only on purpose: state changes and comments are made by the agent and the host (the janitor),
  not by this UI, so nothing here writes a ticket. It does answer the two questions a page that offers
  a write has to ask first -- which states the workflow declares (`declared_states/1`) and where a write
  to *this* queue has to land (`write_options/1`) -- because both answers come from the same tracker
  settings this module already resolves, and a second resolver would be a second place to disagree.

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

  ## Whose queue is read

  By default, the running instance's own tracker -- the queue configured in the workflow file this
  process was started with. A caller may instead name a **registry project** (`:project`), and that
  project's own workflow file then supplies the tracker settings through
  `SymphonyElixir.Projects.tracker_settings/1`. That is what lets the hub show a project whose
  instance is down, without that instance serving anything.

  A name that is not in the registry, and a file that cannot be read or parsed, are errors the same
  way a missing queue path is: a page renders the reason rather than an empty board, because an empty
  board reads as "no work to do".
  """

  alias SymphonyElixir.{Config, Projects}
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

  `:project` names a registry project; its own workflow file then supplies the tracker settings.
  Without it -- the default -- the queue is this instance's own.
  """
  @spec list() :: {:ok, [ticket()]} | {:error, term()}
  @spec list(keyword()) :: {:ok, [ticket()]} | {:error, term()}
  def list(opts \\ []) do
    with {:ok, tickets} <- load(opts) do
      {:ok, Enum.sort_by(tickets, & &1.identifier)}
    end
  end

  @doc """
  One ticket by identifier (its front-matter `id` also matches).

  Takes the same `:project` option as `list/1`.
  """
  @spec fetch(String.t()) :: {:ok, ticket()} | {:error, :not_found | term()}
  @spec fetch(String.t(), keyword()) :: {:ok, ticket()} | {:error, :not_found | term()}
  def fetch(identifier, opts \\ []) when is_binary(identifier) do
    with {:ok, tickets} <- load(opts) do
      case Enum.find(tickets, &(&1.identifier == identifier or &1.id == identifier)) do
        nil -> {:error, :not_found}
        ticket -> {:ok, ticket}
      end
    end
  end

  @doc """
  The states the queue's workflow declares: its `active_states`, then its `terminal_states`.

  Never a list written here. Those two lists are the scheduler's dispatch vocabulary -- the
  orchestrator only ever asks the tracker for tickets in `active_states`, and a ticket parked in a
  state nobody declared is one nothing will pick up again -- so a page that offered `ready` to a
  project whose workflow says `Todo` would be offering a state that strands the ticket. Read from the
  same resolved tracker settings as `list/1`, which is also why a project whose vocabulary is not this
  machine's is offered its own words.

  Takes the same `:project` option as `list/1`, and answers with the same errors, so a page that could
  read a ticket can also read the words it may be moved between.
  """
  @spec declared_states(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def declared_states(opts \\ []) do
    with {:ok, tracker} <- tracker_settings(opts) do
      {:ok, vocabulary(tracker)}
    end
  end

  # Active states first, in declared order: the first of them is the one that gates a blocked ticket
  # (`tracker/file.ex`), so it is the entry a person is likeliest to want. Deduplicated because a
  # workflow that lists one state in both lists should not offer it twice.
  defp vocabulary(tracker) do
    [Map.get(tracker, :active_states), Map.get(tracker, :terminal_states)]
    |> Enum.flat_map(&List.wrap/1)
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
  end

  @doc """
  Options a write to this page's queue must be handed, for `Janitor.set_ticket_state/3` and
  `Janitor.comment_on_ticket/3`.

  Empty for this instance's own queue, deliberately: the janitor's own configuration already names the
  directory the host writes tickets in, and a page must not second-guess where the host keeps them.

  A **named** project is the whole reason this exists. The janitor's default directory is *this*
  instance's queue, so a write made while reading `?project=<name>` would land in the wrong project's
  files -- editing whichever ticket happens to share an identifier, which is the one mistake this seam
  has to make impossible. The named project's own workflow declares the directory it reads tickets
  from, and that is where a write goes.

  A named project whose workflow declares no file queue is `{:error, {:no_writable_queue, name}}`
  rather than this instance's queue.
  """
  @spec write_options(keyword()) :: {:ok, keyword()} | {:error, term()}
  def write_options(opts \\ []) do
    case project_name(opts) do
      nil -> {:ok, []}
      name -> project_write_options(name, opts)
    end
  end

  defp project_write_options(name, opts) do
    with {:ok, tracker} <- tracker_settings(opts) do
      write_target(provider_path(tracker), name)
    end
  end

  # A write has a target only when the project's workflow names the directory it reads tickets from.
  defp write_target(nil, name), do: {:error, {:no_writable_queue, name}}
  defp write_target(path, _name), do: {:ok, [tickets: path]}

  defp project_name(opts) do
    case Keyword.get(opts, :project) do
      name when is_binary(name) and name != "" -> name
      _own -> nil
    end
  end

  @doc """
  A short, printable form of a read or write error, for a page that must still render.

  A write path's refusal keeps its own atom in the sentence (`ticket_not_utf8`, `no_such_ticket`, ...):
  prose alone would leave a reader with nothing to search for, and the atom is exactly what the host
  returned.
  """
  @spec describe(term()) :: String.t()
  def describe({:ticket_read_failed, message}) when is_binary(message), do: message
  def describe({:file_tracker_path_not_found, path}), do: "the ticket directory does not exist: #{path}"
  def describe(:missing_file_tracker_path), do: "the workflow does not configure a ticket directory"

  def describe({:unknown_project, name}) do
    "there is no project named #{name} in the registry (#{Projects.registry_dir()})"
  end

  def describe({:project_workflow_unreadable, name, reason}) do
    "the workflow file of project #{name} cannot be read: #{workflow_reason(reason)}"
  end

  # The host's write refusals, in the words the host used. Each one names its own reason atom, because
  # that is what the janitor returned and what a reader would have to look up to find the rule.
  def describe({:ticket_not_utf8, id}) do
    "the ticket file of #{id} is not valid UTF-8, so the host refuses to write over it (ticket_not_utf8)"
  end

  def describe({:value_not_utf8, id}) do
    "the value to write is not valid UTF-8, so the host refuses to write it (#{id}: value_not_utf8)"
  end

  def describe({:no_such_ticket, id}) do
    "there is no ticket named #{id} in the queue (no_such_ticket)"
  end

  def describe({:invalid_ticket_id, id}) do
    "that is not a plain ticket identifier: #{inspect(id)} (invalid_ticket_id)"
  end

  def describe({:no_writable_queue, name}) do
    "the workflow file of project #{name} declares no ticket directory a write could go to (no_writable_queue)"
  end

  # Not a refusal the host returned but a raise from inside it -- a file another writer holds open, a
  # workflow file that vanished between the read and the submit. Named apart from the refusals so a
  # reader can tell "the host said no" from "the host could not answer".
  def describe({:write_raised, message}) when is_binary(message) do
    "the write failed: #{message} (write_raised)"
  end

  def describe(reason), do: inspect(reason)

  defp workflow_reason({:missing_workflow_file, path, reason}) do
    "#{path} (#{inspect(reason)})"
  end

  defp workflow_reason({:workflow_parse_error, reason}) do
    "its front matter does not parse (#{inspect(reason)})"
  end

  defp workflow_reason({:invalid_workflow_config, message}) when is_binary(message), do: message

  defp workflow_reason(:workflow_front_matter_not_a_map), do: "its front matter is not a map"
  defp workflow_reason(reason), do: inspect(reason)

  # Which queue to read: a registry project's own workflow when the caller named one, this instance's
  # otherwise. Resolved here rather than in the page so both ticket pages answer "and which queue is
  # that?" identically -- and so an unknown or unreadable project arrives as the same `{:error, _}`
  # the pages already render.
  defp tracker_settings(opts) do
    case Keyword.get(opts, :project) do
      name when is_binary(name) and name != "" -> Projects.tracker_settings(name)
      _own -> {:ok, Config.settings!().tracker}
    end
  end

  defp load(opts) do
    with {:ok, tracker} <- tracker_settings(opts) do
      case FileTracker.tickets(tracker) do
        {:ok, issues} ->
          index = file_index(provider_path(tracker))
          {:ok, Enum.map(issues, &to_ticket(&1, index))}

        {:error, reason} ->
          {:error, reason}
      end
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
