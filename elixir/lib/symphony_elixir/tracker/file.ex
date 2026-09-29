defmodule SymphonyElixir.Tracker.File do
  @moduledoc """
  File/directory tracker: a ticket queue that is just files on disk.

  This adapter exists so Symphony can be run with **no account, no token and no network**.
  Point `tracker.provider.path` at a directory of tickets (or at a single ticket file) and the
  orchestrator polls it exactly like it polls Linear or GitHub.

  ## What a ticket looks like

  One file per ticket. Markdown with YAML front matter is the readable form -- the body becomes
  the issue description, so the agent gets the full task text:

      ---
      id: T-1
      title: Cache the git roots lookup
      state: ready
      labels: [perf]
      priority: 2
      ---
      `git_roots/0` walks the filesystem on every call. Cache it per run and add a test.

  A bare `.yaml`/`.yml` file is also accepted; it holds the ticket map directly (and may hold a
  list of ticket maps). Recognised keys: `id`, `identifier`, `title`, `description`, `state`,
  `labels`, `priority`, `blocked_by`, `branch_name`, `url`, `assignee_id`, `created_at`,
  `updated_at`. Unknown keys are ignored, so the file may carry your own bookkeeping.

  Defaults: `id`/`identifier` fall back to the file name, `title` to the identifier, `state` to
  `"open"`, `description` to the Markdown body.

  `priority` is an integer or `nil` (SPEC 1268). A quoted integer is accepted, since front matter is
  hand-written; a float, or a number with anything after it, is `nil` -- the same answer Linear's
  parser gives, rather than a truncation nobody asked for.

  `blocked_by` takes both shapes, and they mean the same thing:

      blocked_by: [T-1, T-2]                                     # shorthand
      blocked_by: [{id: T-1, identifier: T-1, state: done}]      # the ref shape Linear produces

  The shorthand is expanded by looking each blocker up beside this ticket, so the blocker's `state` is
  read from its own file. A blocker that cannot be found keeps a `nil` state, and a blocker whose state
  cannot be seen blocks -- the same answer Linear gives for an absent blocker state.

  ## Which tickets get dispatched

  `dispatchable` is derived, not declared, and it follows Linear's rule rather than "any blocker at
  all": a ticket is held back while a blocker is unfinished **and** the ticket is in the workflow's
  first `active_states` entry. Linear hardcodes that first state as `Todo`; here it is whatever the
  list names first, which makes the order of `active_states` load-bearing. Once work has started, an
  unfinished blocker stops gating, so it cannot freeze a ticket that is already in progress.

  The orchestrator only ever asks for tickets in the configured `active_states`, so a ticket that is
  returned but still carries blockers is deliberately held back rather than dropped -- it shows up as
  blocked instead of silently disappearing.

  Moving work along is editing one line of one file (`state: ready` -> `state: done`), which the
  agent can do itself, or a human can do in an editor. Nothing else in Symphony has to change:
  `active_states` / `terminal_states` in WORKFLOW.md decide which values mean what.

  ## Missing files are not tickets

  In a directory, a `.md` file without front matter is **skipped** (so a `README.md` can live next
  to the tickets); a `.yaml` file that fails to parse is an **error**, because a YAML file is an
  explicit claim to be a ticket. A missing `path` is an error on every fetch, never an empty
  backlog -- a silent empty tracker looks like "no work to do", which is the one failure mode that
  is genuinely hard to notice.

  The one exception is an **empty request**, which is not a fetch at all: `fetch_issues_by_states([])`
  and `fetch_issues_by_ids([])` return `{:ok, []}` before the path is even resolved, because asking
  for nothing is answered by nothing (SPEC 1199 and SPEC 1204 both make that a MUST).
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.Janitor.AgentTool
  alias SymphonyElixir.Tracker.Issue

  @ticket_extensions ~w(.md .markdown .yaml .yml)
  @yaml_extensions ~w(.yaml .yml)
  @front_matter ~r/\A---\s*\r?\n(.*?)\r?\n---\s*\r?\n?(.*)\z/s

  @doc """
  Fetch the tickets whose `state` is one of `state_names`, using the configured tracker settings.

  An empty list is answered with `{:ok, []}` before anything else runs -- SPEC 1199 asks for no
  provider request, and this adapter reads that as no settings, no path, no filesystem either.
  """
  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states([]), do: {:ok, []}

  def fetch_issues_by_states(state_names) when is_list(state_names) do
    fetch_issues_by_states(state_names, Config.settings!().tracker)
  end

  @doc """
  Same as `fetch_issues_by_states/1`, with the tracker settings passed in explicitly (tests, tools).

  The empty-list short-circuit (SPEC 1199) is at this entry point, ahead of `resolve_path/1`: a
  tracker whose `provider.path` is missing or unreadable still answers `{:ok, []}` for an empty
  request, exactly as `fetch_issues_by_states/1` does and as Linear does (`client.ex:111-113`).
  """
  @spec fetch_issues_by_states([String.t()], map()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states([], _tracker_settings), do: {:ok, []}

  def fetch_issues_by_states(state_names, tracker_settings) when is_list(state_names) do
    wanted = state_names |> Enum.map(&normalize_state/1) |> MapSet.new()

    with {:ok, issues} <- tickets(tracker_settings) do
      {:ok,
       issues
       |> Enum.filter(&MapSet.member?(wanted, normalize_state(&1.state)))
       |> sort_issues()}
    end
  end

  @doc """
  Fetch tickets by `id` (or `identifier`), using the configured tracker settings.

  An empty list is answered with `{:ok, []}` before anything else runs (SPEC 1204).
  """
  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids([]), do: {:ok, []}

  def fetch_issues_by_ids(issue_ids) when is_list(issue_ids) do
    fetch_issues_by_ids(issue_ids, Config.settings!().tracker)
  end

  @doc """
  Same as `fetch_issues_by_ids/1`, with the tracker settings passed in explicitly.

  As with `fetch_issues_by_states/2`, the empty-list short-circuit (SPEC 1204) sits ahead of
  `resolve_path/1`, so an empty request never turns into a path error (`client.ex:127-129` in Linear
  is the same shape).
  """
  @spec fetch_issues_by_ids([String.t()], map()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids([], _tracker_settings), do: {:ok, []}

  def fetch_issues_by_ids(issue_ids, tracker_settings) when is_list(issue_ids) do
    wanted = MapSet.new(issue_ids)

    with {:ok, issues} <- tickets(tracker_settings) do
      {:ok,
       issues
       |> Enum.filter(&(MapSet.member?(wanted, &1.id) or MapSet.member?(wanted, &1.identifier)))
       |> sort_issues()}
    end
  end

  @doc """
  This tracker has no credentials, so there is nothing to redact from the agent environment.
  """
  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(_tracker_settings), do: []

  @doc """
  The janitor's tool, not a provider tool.

  A file ticket is changed by editing it, so this tracker has never needed a provider API. What it
  does need is a publisher: the agent cannot commit, push or open a pull request (see
  `SymphonyElixir.Janitor`), so the janitor -- this tracker's host-side caretaker -- offers
  `symphony_publish` and the agent calls it when the work is done.
  """
  @spec agent_tool_specs() :: [map()]
  def agent_tool_specs, do: AgentTool.tool_specs()

  @doc """
  Runs one agent tool call. Only the janitor's `symphony_publish` exists for this tracker.
  """
  @spec execute_agent_tool(String.t() | nil, term(), keyword()) :: map()
  def execute_agent_tool(tool, arguments, opts), do: AgentTool.execute(tool, arguments, opts)

  @doc """
  Validate the tracker block.

  Fails closed on a missing or non-existent `path`: a misconfigured local tracker must not look
  like an empty backlog.
  """
  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(tracker_settings) when is_map(tracker_settings) do
    with {:ok, path} <- resolve_path(tracker_settings),
         true <- File.exists?(path) or {:error, {:file_tracker_path_not_found, path}},
         true <- active_states?(tracker_settings) or {:error, :missing_file_tracker_active_states} do
      :ok
    end
  end

  def validate_config(_tracker_settings), do: {:error, :invalid_file_tracker_settings}

  @doc """
  Read every ticket under the configured path. Exposed for tests and for the agent tool surface.
  """
  @spec tickets(map()) :: {:ok, [Issue.t()]} | {:error, term()}
  def tickets(tracker_settings) when is_map(tracker_settings) do
    with {:ok, path} <- resolve_path(tracker_settings),
         {:ok, issues} <- read_tickets_at(path) do
      {:ok, Enum.map(issues, &apply_dispatch_gate(&1, tracker_settings))}
    end
  end

  def tickets(_tracker_settings), do: {:error, :invalid_file_tracker_settings}

  defp read_tickets_at(path) do
    cond do
      File.dir?(path) -> read_directory(path)
      File.regular?(path) -> read_ticket_file(path)
      true -> {:error, {:file_tracker_path_not_found, path}}
    end
  end

  # Linear holds a blocked ticket back only while it sits in the workflow's **first** state -- its code
  # hardcodes `Todo` for that (`linear/client.ex:501-503`) -- and once work has started the blocker
  # stops gating, so an unfinished blocker cannot freeze a ticket that is already in progress. Here the
  # first entry of `active_states` plays that role, which makes the order of that list load-bearing. A
  # blocker whose state cannot be seen blocks, exactly as Linear treats an absent blocker state
  # (`client.ex:508-510`).
  defp apply_dispatch_gate(issue, tracker_settings) do
    blockers = issue.blocked_by || []

    blocked? =
      blockers != [] and gating_state?(issue.state, tracker_settings) and
        Enum.any?(blockers, &(not terminal_state?(&1, tracker_settings)))

    %{issue | dispatchable: not blocked?}
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

  # ── Path resolution ─────────────────────────────────────────────────────────

  defp resolve_path(tracker_settings) do
    case provider_path(tracker_settings) do
      path when is_binary(path) and path != "" -> {:ok, Path.expand(path)}
      _ -> {:error, :missing_file_tracker_path}
    end
  end

  defp provider_path(%{provider: provider}) when is_map(provider),
    do: provider["path"] || provider[:path]

  defp provider_path(_tracker_settings), do: nil

  defp active_states?(%{active_states: states}) when is_list(states), do: states != []
  defp active_states?(_tracker_settings), do: false

  # ── Reading ─────────────────────────────────────────────────────────────────

  defp read_directory(path) do
    path
    |> ticket_files()
    |> Enum.reduce_while({:ok, []}, fn file, {:ok, acc} ->
      case read_ticket_file(file, directory: true) do
        {:ok, issues} -> {:cont, {:ok, acc ++ issues}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, sort_issues(issues)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ticket_files(path) do
    path
    |> File.ls!()
    |> Enum.filter(&(Path.extname(&1) in @ticket_extensions))
    |> Enum.reject(&String.starts_with?(&1, "."))
    |> Enum.sort()
    |> Enum.map(&Path.join(path, &1))
  end

  defp read_ticket_file(path, opts \\ []) do
    directory? = Keyword.get(opts, :directory, false)

    case File.read(path) do
      {:ok, contents} -> parse_contents(path, contents, directory?)
      {:error, reason} -> {:error, {:file_tracker_read_failed, path, reason}}
    end
  end

  defp parse_contents(path, contents, directory?) do
    extension = path |> Path.extname() |> String.downcase()

    case strip_bom(contents) do
      stripped when extension in @yaml_extensions -> parse_yaml(path, stripped)
      stripped -> parse_markdown(path, stripped, directory?)
    end
  end

  # A leading UTF-8 BOM is stripped before anything looks at the text. On Windows the obvious way to
  # edit a file (`Set-Content -Encoding UTF8`) writes one, and because the front-matter regex anchors on
  # `\A---`, a BOM'd ticket used to stop being a ticket at all -- it vanished from the queue with no
  # error, which is the one failure mode this module exists to avoid. Measured on SYM-48: a run's own
  # edit to its ticket removed that ticket from the queue mid-run.
  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(contents), do: contents

  defp parse_markdown(path, contents, directory?) do
    case Regex.run(@front_matter, contents) do
      [_, yaml, body] ->
        with {:ok, decoded} <- decode_yaml(path, yaml) do
          to_issues(path, decoded, body)
        end

      nil when directory? ->
        # A directory may hold notes that are not tickets (README, plans, ...).
        {:ok, []}

      nil ->
        {:error, {:file_tracker_missing_front_matter, path}}
    end
  end

  defp parse_yaml(path, contents) do
    with {:ok, decoded} <- decode_yaml(path, contents) do
      to_issues(path, decoded, nil)
    end
  end

  defp decode_yaml(path, contents) do
    case YamlElixir.read_from_string(contents) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:file_tracker_invalid_yaml, path, reason}}
    end
  end

  # ── Decoding ────────────────────────────────────────────────────────────────

  defp to_issues(path, decoded, body) when is_list(decoded) do
    stem = file_stem(path)

    {:ok,
     decoded
     |> Enum.with_index(1)
     |> Enum.map(fn {ticket, index} -> to_issue(ticket, body, "#{stem}-#{index}", path) end)}
  end

  defp to_issues(path, decoded, body) when is_map(decoded) do
    if blank_map?(decoded) do
      {:error, {:file_tracker_empty_ticket, path}}
    else
      {:ok, [to_issue(decoded, body, file_stem(path), path)]}
    end
  end

  defp to_issues(path, _decoded, _body), do: {:error, {:file_tracker_invalid_ticket, path}}

  defp to_issue(ticket, body, fallback_identifier, path) when is_map(ticket) do
    identifier =
      to_string_value(ticket["identifier"]) ||
        to_string_value(ticket["id"]) || fallback_identifier

    blockers = blockers(ticket, Path.dirname(path))

    %Issue{
      id: to_string_value(ticket["id"]) || identifier,
      identifier: identifier,
      title: to_string_value(ticket["title"]) || identifier,
      description: to_string_value(ticket["description"]) || body,
      state: to_string_value(ticket["state"]) || "open",
      priority: to_integer(ticket["priority"]),
      labels: labels(ticket["labels"]),
      branch_name: to_string_value(ticket["branch_name"]),
      url: to_string_value(ticket["url"]),
      assignee_id: to_string_value(ticket["assignee_id"]),
      created_at: to_datetime(ticket["created_at"]),
      updated_at: to_datetime(ticket["updated_at"]),
      blocked_by: blockers,
      # Decided in `tickets/1`, where the tracker settings are in hand: whether a blocker holds this
      # ticket back depends on the configured state lists, not on the ticket alone.
      dispatchable: true,
      # Per-task agent route. Read here because the ticket file is where a person's choice is
      # written; `AgentIdentity.for_issue/2` decides how far it is allowed to go.
      adapter: to_string_value(ticket["adapter"]),
      model: to_string_value(ticket["model"])
    }
  end

  defp to_issue(_ticket, _body, _fallback_identifier, _path), do: %Issue{}

  # SPEC 187-191, and the same shape Linear produces (`linear/client.ex:626-630`): a blocker is a ref
  # -- `{id, identifier, state}` with each key nullable -- not a bare name, because the only thing the
  # dispatcher needs from it is whether it is finished. Front matter may write the shorthand
  # (`blocked_by: [SYM-1, SYM-2]`), which is expanded here by looking the blocker up beside this ticket.
  defp blockers(ticket, dir) do
    ticket
    |> Map.get("blocked_by", [])
    |> List.wrap()
    |> Enum.map(&blocker_ref(&1, dir))
    |> Enum.reject(&is_nil/1)
  end

  defp blocker_ref(value, dir) do
    case normalize_blocker(value) do
      nil ->
        nil

      %{identifier: identifier, state: stated} ->
        %{id: identifier, identifier: identifier, state: stated || blocker_state(identifier, dir)}
    end
  end

  defp normalize_blocker(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      identifier -> %{identifier: identifier, state: nil}
    end
  end

  defp normalize_blocker(%{} = value) do
    identifier = to_string_value(value["identifier"]) || to_string_value(value["id"])

    if identifier do
      %{identifier: identifier, state: to_string_value(value["state"])}
    else
      nil
    end
  end

  defp normalize_blocker(_value), do: nil

  # Reuses this module's own decoding path rather than peeking at the file, so a blocker's state means
  # exactly what a ticket's state means. `nil` when there is no such ticket: the caller blocks on that,
  # which is what Linear does with a blocker state it cannot see.
  defp blocker_state(identifier, dir) do
    path = Path.join(dir, identifier <> ".md")

    with true <- File.regular?(path),
         {:ok, issues} <- read_ticket_file(path),
         %Issue{state: state} <- List.first(issues) do
      to_string_value(state)
    else
      _ -> nil
    end
  end

  defp file_stem(path), do: Path.basename(path, Path.extname(path))

  defp blank_map?(map), do: map == %{} or Enum.all?(map, fn {_k, v} -> is_nil(v) end)

  # SPEC 1266-1267, and the same four steps Linear's adapter applies (`linear/client.ex:607-616`):
  # trim, downcase, drop blanks, uniq. Trimming alone makes `Ready` and `ready` two different labels to
  # everything downstream that compares them, which is why the spec asks for the whole rule and not
  # part of it. Both front-matter shapes feed the same normalizer, so a list and a comma string cannot
  # disagree.
  defp labels(nil), do: []

  defp labels(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> normalize_labels()
  end

  defp labels(value) when is_list(value) do
    value |> Enum.map(&to_string/1) |> normalize_labels()
  end

  defp labels(_value), do: []

  defp normalize_labels(values) do
    values
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp to_string_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp to_string_value(value) when is_integer(value), do: Integer.to_string(value)
  defp to_string_value(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp to_string_value(_value), do: nil

  # SPEC 1268 says `integer or null`, and this gives the same answer Linear's parser gives: a float is
  # not an integer, so `2.5` becomes nil rather than being truncated to 2. The one affordance this
  # tracker adds is a quoted integer -- `priority: "2"` -- because front matter is written by hand. The
  # parse must consume the whole string: `"2.5"` and `"2abc"` are not integers, and prefix-parsing them
  # into 2 would invent a priority nobody wrote.
  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp to_integer(_value), do: nil

  defp to_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        datetime

      {:error, _reason} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
          {:error, _reason} -> nil
        end
    end
  end

  defp to_datetime(_value), do: nil

  # ── Shared helpers ──────────────────────────────────────────────────────────

  defp sort_issues(issues), do: Enum.sort_by(issues, &{&1.identifier, &1.id})

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: ""
end
