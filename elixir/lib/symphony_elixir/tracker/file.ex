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

  ## Which tickets get dispatched

  `dispatchable` is derived, not declared: a ticket is dispatchable when it has no `blocked_by`
  entries. The orchestrator only ever asks for tickets in the configured `active_states`, so a
  ticket that is returned but still carries blockers is deliberately held back rather than
  dropped -- it shows up as blocked instead of silently disappearing.

  Moving work along is editing one line of one file (`state: ready` -> `state: done`), which the
  agent can do itself, or a human can do in an editor. Nothing else in Symphony has to change:
  `active_states` / `terminal_states` in WORKFLOW.md decide which values mean what.

  ## Missing files are not tickets

  In a directory, a `.md` file without front matter is **skipped** (so a `README.md` can live next
  to the tickets); a `.yaml` file that fails to parse is an **error**, because a YAML file is an
  explicit claim to be a ticket. A missing `path` is an error on every fetch, never an empty
  backlog -- a silent empty tracker looks like "no work to do", which is the one failure mode that
  is genuinely hard to notice.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @ticket_extensions ~w(.md .markdown .yaml .yml)
  @yaml_extensions ~w(.yaml .yml)
  @front_matter ~r/\A---\s*\r?\n(.*?)\r?\n---\s*\r?\n?(.*)\z/s

  @doc """
  Fetch the tickets whose `state` is one of `state_names`, using the configured tracker settings.
  """
  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    fetch_issues_by_states(state_names, Config.settings!().tracker)
  end

  @doc """
  Same as `fetch_issues_by_states/1`, with the tracker settings passed in explicitly (tests, tools).
  """
  @spec fetch_issues_by_states([String.t()], map()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names, tracker_settings) when is_list(state_names) do
    wanted = state_names |> Enum.map(&normalize_state/1) |> MapSet.new()

    with {:ok, issues} <- tickets(tracker_settings) do
      {:ok,
       issues
       |> Enum.filter(&MapSet.member?(wanted, normalize_state(&1.state)))
       |> sort_issues()}
    end
  end

  @doc "Fetch tickets by `id` (or `identifier`), using the configured tracker settings."
  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) when is_list(issue_ids) do
    fetch_issues_by_ids(issue_ids, Config.settings!().tracker)
  end

  @doc "Same as `fetch_issues_by_ids/1`, with the tracker settings passed in explicitly."
  @spec fetch_issues_by_ids([String.t()], map()) :: {:ok, [Issue.t()]} | {:error, term()}
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
  No provider-native tools: the ticket *is* a file, so an agent that wants to change it just
  edits it.
  """
  @spec agent_tool_specs() :: [map()]
  def agent_tool_specs, do: []

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
    with {:ok, path} <- resolve_path(tracker_settings) do
      cond do
        File.dir?(path) -> read_directory(path)
        File.regular?(path) -> read_ticket_file(path)
        true -> {:error, {:file_tracker_path_not_found, path}}
      end
    end
  end

  def tickets(_tracker_settings), do: {:error, :invalid_file_tracker_settings}

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

    if extension in @yaml_extensions do
      parse_yaml(path, contents)
    else
      parse_markdown(path, contents, directory?)
    end
  end

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
     |> Enum.map(fn {ticket, index} -> to_issue(ticket, body, "#{stem}-#{index}") end)}
  end

  defp to_issues(path, decoded, body) when is_map(decoded) do
    if blank_map?(decoded) do
      {:error, {:file_tracker_empty_ticket, path}}
    else
      {:ok, [to_issue(decoded, body, file_stem(path))]}
    end
  end

  defp to_issues(path, _decoded, _body), do: {:error, {:file_tracker_invalid_ticket, path}}

  defp to_issue(ticket, body, fallback_identifier) when is_map(ticket) do
    identifier =
      to_string_value(ticket["identifier"]) ||
        to_string_value(ticket["id"]) || fallback_identifier

    blockers =
      ticket
      |> Map.get("blocked_by", [])
      |> List.wrap()
      |> Enum.map(&to_string/1)

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
      dispatchable: blockers == []
    }
  end

  defp to_issue(_ticket, _body, _fallback_identifier), do: %Issue{}

  defp file_stem(path), do: Path.basename(path, Path.extname(path))

  defp blank_map?(map), do: map == %{} or Enum.all?(map, fn {_k, v} -> is_nil(v) end)

  defp labels(nil), do: []

  defp labels(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp labels(value) when is_list(value), do: value |> Enum.map(&to_string/1) |> Enum.map(&String.trim/1)

  defp labels(_value), do: []

  defp to_string_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp to_string_value(value) when is_integer(value), do: Integer.to_string(value)
  defp to_string_value(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp to_string_value(_value), do: nil

  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(value) when is_float(value), do: trunc(value)

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _rest} -> parsed
      :error -> nil
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
