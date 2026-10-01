defmodule SymphonyElixirWeb.TicketPresenter do
  @moduledoc """
  Reads the queue's tickets for the control plane's ticket view, and answers the write seam the ticket
  page submits through.

  ## The read

  Reads are one source, so there is one answer per question: `SymphonyElixirWeb.TicketReader`, which
  reads a ticket from whichever tracker the workflow configures -- the file queue's own parse for a
  `file` tracker (the same one the dispatcher uses, so the board and the scheduler cannot disagree about
  what a ticket says), or the ticket service's deep read for a `ticket_service` tracker. That module's
  moduledoc says why the seam is there and what a tracker this console cannot read answers.

  This module keeps what is policy rather than reading: which fields a page shows, what a tracker's
  own vocabulary is, where a write to *this* queue has to land, and how a read or write error is put
  into a sentence a page can render.

  ## The write seam

  `writer/1` answers a function the ticket page submits its state change and its comment through, so the
  page never has to know which tracker it is talking to. For a **file** tracker that function is the
  host's own writer (`SymphonyElixir.Janitor`), because a ticket file's only safe writer is one that
  hands its own bytes back unchanged; for a **ticket service** tracker it is the tracker boundary
  (`SymphonyElixir.Tracker.write_state/3`, `write_comment/4`), because the service owns that row and
  there is no queue on disk for a service deployment at all. A page that asked the janitor directly used
  to work for the file kind and refuse loudly for the other; now a deployment writes through whichever
  of the two its tracker is.

  The write's answers are deliberately the shapes a page already renders: `{:ok, result}` from whatever
  wrote, or `{:error, reason}` in the same vocabulary `describe/1` turns into a sentence.

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

  alias SymphonyElixir.{Config, Janitor, Projects, Tracker}
  alias SymphonyElixirWeb.TicketReader

  @type ticket :: map()
  @type discussion_entry :: %{author: String.t(), at: String.t(), id: String.t(), text: String.t()}
  @type write_result :: {:ok, term()} | {:error, term()}
  @type writer :: (atom(), term(), keyword() -> write_result())

  @doc """
  Every ticket in the configured queue, sorted by identifier.

  `:project` names a registry project; its own workflow file then supplies the tracker settings.
  Without it -- the default -- the queue is this instance's own. `:client` replaces the ticket
  service's HTTP transport, which is how a test reads a service-backed queue without a socket.

  The list is a list read: a ticket's body and discussion are answered by `fetch/2`, which for a
  service tracker is the service's deep read.
  """
  @spec list() :: {:ok, [ticket()]} | {:error, term()}
  @spec list(keyword()) :: {:ok, [ticket()]} | {:error, term()}
  def list(opts \\ []) do
    with {:ok, tickets} <- load(opts) do
      {:ok, Enum.sort_by(tickets, & &1.identifier)}
    end
  end

  @doc """
  One ticket, with its body, its discussion and its links.

  Takes the same options as `list/1`: `:project` for whose queue this is, and `:client` for the
  ticket service's transport.
  """
  @spec fetch(String.t()) :: {:ok, ticket()} | {:error, :not_found | term()}
  @spec fetch(String.t(), keyword()) :: {:ok, ticket()} | {:error, :not_found | term()}
  def fetch(identifier, opts \\ []) when is_binary(identifier) do
    with {:ok, tracker} <- tracker_settings(opts) do
      TicketReader.fetch(tracker, identifier, reader_options(opts))
    end
  rescue
    error -> {:error, {:ticket_read_failed, Exception.message(error)}}
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
      {:ok, TicketReader.states(tracker)}
    end
  end

  @doc """
  The state a landed ticket is moved to: the first entry of the workflow's own `terminal_states`.

  From the workflow rather than from a word written here, for the same reason `declared_states/1` is:
  a state nobody declared is a state nothing reads. It is the project's declaration read in the
  project's own order, which is how `done` comes before `cancelled` in every workflow in this
  repository -- the first entry is the one a merged ticket takes.

  A workflow that declares no terminal state has nowhere to put a ticket it just merged, and answers
  `{:error, :no_terminal_state}` rather than inventing one: an invented state would strand the
  ticket where the scheduler cannot see it.

  Takes the same `:project` option as `list/1`, and answers with the same errors, so a page that
  could read a ticket can also read where a landed one belongs.
  """
  @spec terminal_state(keyword()) :: {:ok, String.t()} | {:error, term()}
  def terminal_state(opts \\ []) do
    with {:ok, tracker} <- tracker_settings(opts) do
      case TicketReader.states(tracker, :terminal) do
        [state | _rest] -> {:ok, state}
        [] -> {:error, :no_terminal_state}
      end
    end
  end

  @doc """
  The function a write to this page's queue goes through, or the reason it cannot be written at all.

  The page submits through it without knowing the tracker kind:

      {:ok, write} = TicketPresenter.writer(project: project)

      write.(:state, "in-progress", [])
      write.(:comment, "Please also cover the Windows path.", author: "operator")

  `:author` is a comment's signature and is ignored by a state write. `:client` replaces the ticket
  service's transport for the write exactly as it does for the read (`:ticket_reader_client` at the
  endpoint), which is how a page test writes to a service-backed deployment without a socket.

  Which writer answers is the tracker's own kind -- the same settings `list/1` reads -- and never a
  second configuration:

    * `file` -- the host's own writer, `SymphonyElixir.Janitor.set_ticket_state/3` and
      `comment_on_ticket/3`, handed the directory this queue's tickets live in. For this instance's own
      queue that is the janitor's own configured directory, unchanged; a **named** project's workflow
      names its own, so a write made while reading `?project=<name>` lands in that project's files --
      editing whichever ticket happens to share an identifier, which is the one mistake this seam has to
      make impossible. A named project whose workflow declares no file queue is
      `{:error, {:no_writable_queue, name}}` rather than this instance's queue;
    * `ticket_service` -- the tracker boundary, so the service's own HTTP API writes the row
      (`SymphonyElixir.Tracker.write_state/3`, `write_comment/4`);
    * anything else -- a tracker the console cannot write, `{:error, {:ticket_kind_not_writable, kind}}`.

  A settings map naming no kind raises here as it does everywhere else in this process, where the
  workflow is expected to have been validated.
  """
  @spec writer(keyword()) :: {:ok, writer()} | {:error, term()}
  def writer(opts \\ []) do
    with {:ok, tracker} <- tracker_settings(opts) do
      writer_for(tracker, opts)
    end
  rescue
    error -> {:error, {:write_raised, Exception.message(error)}}
  end

  # The file kind: the host's own writer, because a ticket file's only safe writer is one that hands its
  # own bytes back unchanged. `tickets:` is passed for every queue, this instance's own included, and its
  # value is what the workflow already declares -- the janitor's built-in default is never reached from
  # here, so a page cannot write to a directory the tracker it read from does not name.
  defp writer_for(%{kind: "file"} = tracker, opts) do
    case TicketReader.queue_path(tracker) do
      nil ->
        {:error, {:no_writable_queue, project_name(opts)}}

      tickets ->
        {:ok,
         fn
           :state, state, _write_opts ->
             Janitor.set_ticket_state(ref(opts), state, tickets: tickets)

           :comment, body, write_opts ->
             Janitor.comment_on_ticket(ref(opts), body, tickets: tickets, author: author(write_opts))
         end}
    end
  end

  # The service kind: the tracker boundary writes the row over the service's own HTTP API, which is the
  # same pair of calls the adapter's agent tools are envelopes over.
  defp writer_for(%{kind: "ticket_service"} = tracker, opts) do
    write_opts = [tracker_settings: tracker] ++ client(opts)

    {:ok,
     fn
       :state, state, _write_opts -> Tracker.write_state(ref(opts), state, write_opts)
       :comment, body, call_opts -> Tracker.write_comment(ref(opts), body, author(call_opts), write_opts)
     end}
  end

  # A tracker this console cannot write at all. The refusal is a value rather than a raise for the same
  # reason the page's read refusals are: a page renders what happened.
  defp writer_for(%{kind: kind}, _opts) do
    {:ok, fn _operation, _value, _write_opts -> {:error, {:ticket_kind_not_writable, kind}} end}
  end

  defp ref(opts), do: Keyword.fetch!(opts, :ref)
  defp author(write_opts), do: Keyword.get(write_opts, :author, "agent")

  # `:client` is the ticket service's transport, and nil is "use the real one": a page always hands in
  # whatever its endpoint config carries, and the environments that configure nothing must reach
  # `TicketService.request/3` rather than a client that is not there.
  defp client(opts) do
    opts
    |> Keyword.take([:client])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

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

  # A tracker the console can read but not write, named as the workflow names it: `describe/1` already
  # has a sentence for a kind it cannot read at all, and this is the write-side counterpart.
  def describe({:ticket_kind_not_writable, kind}) do
    "this console writes tickets to a file queue or to the ticket service, and this tracker is " <>
      "configured as #{inspect(kind)}: it declares no way to write a ticket's state or a comment " <>
      "(ticket_kind_not_writable)"
  end

  # The tracker boundary's own refusal, as a page. A kind that reaches the boundary without the write
  # callbacks is the same fact as a kind the console cannot write, and it is said the same way.
  def describe({:tracker_write_unsupported, kind, _callback}) do
    describe({:ticket_kind_not_writable, kind})
  end

  # The one read a landing needs that a read-only page never asked for: where a merged ticket goes.
  def describe(:no_terminal_state) do
    "the workflow declares no terminal state, so a landed ticket has nowhere to be moved (no_terminal_state)"
  end

  # Not a refusal the host returned but a raise from inside it -- a file another writer holds open, a
  # workflow file that vanished between the read and the submit. Named apart from the refusals so a
  # reader can tell "the host said no" from "the host could not answer".
  def describe({:write_raised, message}) when is_binary(message) do
    "the write failed: #{message} (write_raised)"
  end

  # A tracker this console cannot read at all. It is spelled out rather than left to the catch-all
  # because it is the read error a person would otherwise misread: an empty page where a ticket should
  # be looks like "this ticket has no description" and an empty board looks like "no work to do", and
  # neither is what this says.
  def describe({:ticket_kind_not_readable, kind}) do
    "this console reads tickets from a file queue or from the ticket service, and this tracker is " <>
      "configured as #{inspect(kind)}: nothing here can read a ticket's list, its body or its " <>
      "discussion from it (ticket_kind_not_readable)"
  end

  def describe(:invalid_tracker_settings) do
    "the workflow declares no tracker this console could read a ticket from (invalid_tracker_settings)"
  end

  # A service read that asked for no state would be answered with an empty list before the service
  # reads anything, and an empty list is an empty board -- which reads as "no work to do".
  def describe(:no_ticket_service_states) do
    "the workflow declares no active_states or terminal_states, so the ticket service was asked for " <>
      "no state at all; an empty board would be this console's invention rather than the service's " <>
      "answer (no_ticket_service_states)"
  end

  def describe(:missing_ticket_service_url) do
    "the workflow configures a ticket_service tracker without a provider.url, so there is no address " <>
      "to ask (missing_ticket_service_url)"
  end

  # The service's own failures, passed through with the reason it gave and rendered instead of an
  # empty ticket: a page that cannot read a ticket must say why, not show nothing.
  def describe({:ticket_service_unreachable, reason}) do
    "the ticket service did not answer: #{service_detail(reason)} (ticket_service_unreachable)"
  end

  # A write to a ticket the service does not hold. The read path turns its own 404 into `:not_found`, but
  # a write names the value the service could not read, and that value is the ticket the page was showing
  # -- so the sentence carries it rather than a bare `:not_found` that reads as "this ticket vanished".
  def describe({:ticket_service_ticket_not_found, value}) do
    "the ticket service has no ticket for #{inspect(value)}, so nothing was written " <>
      "(ticket_service_ticket_not_found)"
  end

  def describe({:ticket_service_invalid_payload, body}) do
    "the ticket service answered something that is not a ticket: #{service_detail(body)} " <>
      "(ticket_service_invalid_payload)"
  end

  def describe({:ticket_service_http, status, body}) do
    "the ticket service answered HTTP #{status}: #{service_detail(body)} (ticket_service_http)"
  end

  def describe(reason), do: inspect(reason)

  # The store's own error message when the body is one of its error envelopes, and a short inspect of
  # anything else: a body is data and can be long, and a page shows a sentence, not a document.
  defp service_detail(%{"error" => %{"message" => message}}) when is_binary(message), do: message

  defp service_detail(body) when is_map(body) do
    body |> inspect(limit: 6, printable_limit: 200) |> String.replace(~r/\s+/, " ")
  end

  defp service_detail(body) when is_binary(body) do
    body |> String.trim() |> String.slice(0, 200)
  end

  defp service_detail(other), do: inspect(other)

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
      TicketReader.list(tracker, reader_options(opts))
    end
  rescue
    error -> {:error, {:ticket_read_failed, Exception.message(error)}}
  end

  # `:client` is the ticket service's transport, and nil is "use the real one": a page always hands in
  # whatever its endpoint config carries, and the environments that configure nothing must reach
  # `TicketService.get/1` rather than a client that is not there.
  defp reader_options(opts) do
    opts
    |> Keyword.take([:client])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end
