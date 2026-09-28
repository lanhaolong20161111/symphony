defmodule SymphonyElixir.TaskComposer do
  @moduledoc """
  Middleware that converts task-management input into GitHub issues and ticket
  files.

  This is the "entry" the architecture names as the gap: `TicketSink` only
  writes tickets; nothing reads a tracker to find work. A person who wants to
  create a task had to open GitHub, fill the issue form, and hope the janitor
  picks it up. This module is the programmatic path -- a form submits here, and
  the middleware creates the GitHub issue **and** writes the ticket file in one
  step, so the janitor's next round only mirrors state rather than doing the
  create.

  ## Why both, not one

  The issue is the human surface (labels, comments, state a person reads). The
  ticket file is the machine surface (the file tracker polls it, `blocked_by`
  decides dispatchability). Writing only the issue means waiting up to one
  janitor interval before the task appears in the queue; writing only the ticket
  means the GitHub issue is missing until the janitor adopts it. Doing both
  closes the gap immediately and leaves the janitor's mirroring as the only
  remaining work.

  ## Dependency graph

  `blocked_by` is a front-matter key the file tracker already reads
  (`dispatchable: blockers == []`). This module writes it as a YAML flow sequence
  (`[SYM-1, SYM-2]`) so the tracker parses a list and the janitor's string-based
  reader strips the brackets for the board. GitHub has no native task
  dependencies, so the issue body carries a human-readable "Blocked by" note
  instead -- the ticket file is the single source of truth for dispatch.
  """

  require Logger

  alias SymphonyElixir.{Config, Janitor}
  alias SymphonyElixir.Janitor.{Labels, Shell, Ticket}

  @task_label "agent-task"
  @managed_label "symphony"
  @command_timeout 60_000

  @typedoc "Form input for creating a task."
  @type task_input :: %{
          required(:title) => String.t(),
          optional(:description) => String.t(),
          optional(:validation) => String.t(),
          optional(:blocked_by) => [String.t()],
          optional(:priority) => String.t() | integer()
        }

  @typedoc "One ticket, as the management page reads it."
  @type ticket :: %{
          id: String.t(),
          title: String.t(),
          state: String.t(),
          issue: String.t() | nil,
          issue_url: String.t() | nil,
          assignee: String.t() | nil,
          priority: String.t() | nil,
          blocked_by: [String.t()],
          body: String.t(),
          path: String.t()
        }

  # ── Pure: building the issue body ────────────────────────────────────────────

  @doc """
  Builds the GitHub issue body from form input.

  Uses the same `### <label>` headings the janitor's `form_answer/2` parses, so
  a re-receive (if the ticket file is ever lost) still extracts the right
  sections.

  The dependency block is a **convenience**, not the mechanism: the real link is
  GitHub's own `blocked by` relationship, applied by `link_dependencies/3`. It stays
  because an issue body that names what blocks it reads better than a bare list of
  linked issues, and because it survives if the relationship is dropped by hand.
  """
  @spec build_issue_body(task_input()) :: String.t()
  def build_issue_body(attrs) do
    description = Map.get(attrs, :description, "") || ""
    validation = Map.get(attrs, :validation, "") || ""
    blocked_by = Map.get(attrs, :blocked_by, []) || []

    parts = [
      "### 要做什么",
      "",
      String.trim(description),
      "",
      "### 怎么算做完了",
      "",
      if validation in ["", nil] do
        "_No response_"
      else
        String.trim(validation)
      end
    ]

    parts =
      if is_list(blocked_by) and blocked_by != [] do
        deps = Enum.map_join(blocked_by, "\n", &"- ##{&1}")
        parts ++ ["", "---", "", "**依赖（完成前不会派发）**:", "", deps]
      else
        parts
      end

    Enum.join(parts, "\n")
  end

  # ── Pure: building the ticket file text ──────────────────────────────────────

  @doc """
  Builds the ticket file text from form input and the issue number.

  Starts from `Ticket.build/4` (which produces the canonical front matter) and
  layers on `blocked_by` and the `## Validation` section, because `build/4` does
  not know about either.
  """
  @spec build_ticket_text(String.t(), task_input(), String.t()) :: String.t()
  def build_ticket_text(ticket_id, attrs, issue_number) do
    title = Map.fetch!(attrs, :title)
    description = Map.get(attrs, :description, "") || ""
    validation = Map.get(attrs, :validation, "") || ""
    blocked_by = Map.get(attrs, :blocked_by, []) || []

    text = Ticket.build(ticket_id, title, issue_number, String.trim(description))

    text =
      if validation in ["", nil] do
        text
      else
        String.trim_trailing(text) <> "\n\n## Validation\n\n#{String.trim(validation)}\n"
      end

    if is_list(blocked_by) and blocked_by != [] do
      Ticket.set_key(text, "blocked_by", format_blocked_by(blocked_by))
    else
      text
    end
  end

  @doc """
  Formats a list of ticket IDs as a YAML flow sequence for the `blocked_by`
  front-matter key.

  `[SYM-1, SYM-2]` parses as a list under both the file tracker's YAML decoder
  and the janitor's string-based reader (which strips the brackets).
  """
  @spec format_blocked_by([String.t()]) :: String.t()
  def format_blocked_by(ids) when is_list(ids) do
    "[#{Enum.join(ids, ", ")}]"
  end

  @doc """
  Parses the issue number out of `gh issue create`'s output.

  `gh issue create` prints the issue's URL on success. The janitor's
  `adopt_issue/3` uses the same regex; this is the same extraction, made public
  and tested.
  """
  @spec parse_issue_number(String.t()) :: {:ok, String.t()} | :error
  def parse_issue_number(output) when is_binary(output) do
    case Regex.run(~r{/issues/(\d+)}, output) do
      [_, number] -> {:ok, number}
      _ -> :error
    end
  end

  # ── Side-effecting: creating a task ───────────────────────────────────────────

  @doc """
  Creates a GitHub issue, writes the matching ticket file, and links the declared
  dependencies as **GitHub's own** `blocked by` relationships.

  Order matters: the issue is created first so the ticket file can carry the
  issue number from the start. If the ticket were written first (with no issue
  number), the janitor's `adopt_issue` would race and create a second issue.

  Dependencies land in **two** places, on purpose:

    * the ticket file's `blocked_by` front matter -- the file tracker reads it and
      derives `dispatchable: blockers == []`, so this is what actually holds work
      back;
    * GitHub's `blocked by` relationship -- `gh issue edit --add-blocked-by`, which
      is what a person sees on the issue itself.

  A dependency that cannot be resolved (no such ticket, or a ticket with no issue
  number) is reported in `dependency_warnings` rather than dropped: the caller
  asked for that link, so silence would be the one unacceptable outcome.

  Returns
  `{:ok, %{id, issue_number, issue_url, linked_dependencies, dependency_warnings}}`.
  """
  @spec create_task(task_input()) ::
          {:ok,
           %{
             id: String.t(),
             issue_number: String.t(),
             issue_url: String.t(),
             linked_dependencies: [String.t()],
             dependency_warnings: [String.t()]
           }}
          | {:error, term()}
  def create_task(attrs) do
    title = Map.get(attrs, :title)

    if title in [nil, ""] do
      {:error, :missing_title}
    else
      do_create_task(attrs)
    end
  end

  defp do_create_task(attrs) do
    issues_repo = issues_repo()

    with {:ok, issue_number, issue_url} <- create_github_issue(attrs, issues_repo),
         {:ok, ticket_id} <- write_ticket(attrs, issue_number) do
      Logger.info("task_composer: created #{ticket_id} from issue ##{issue_number}")

      {linked, warnings} = link_dependencies(attrs, issue_number, issues_repo)

      {:ok,
       %{
         id: ticket_id,
         issue_number: issue_number,
         issue_url: issue_url,
         linked_dependencies: linked,
         dependency_warnings: warnings
       }}
    end
  end

  defp create_github_issue(attrs, repo) do
    body = build_issue_body(attrs)
    title = Map.fetch!(attrs, :title)
    ready_label = Labels.friendly("ready")

    args = [
      "issue",
      "create",
      "--repo",
      repo,
      "--title",
      title,
      "--body",
      body,
      "--label",
      @task_label,
      "--label",
      @managed_label
    ]

    args = if ready_label, do: args ++ ["--label", ready_label], else: args

    case Shell.run("gh", args, timeout: @command_timeout) do
      {:ok, output, 0} ->
        case parse_issue_number(output) do
          {:ok, number} ->
            {:ok, number, String.trim(output)}

          :error ->
            Logger.warning("task_composer: unexpected gh output: #{output}")
            {:error, {:unexpected_output, output}}
        end

      {:ok, output, status} ->
        {:error, {:gh_exit, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_ticket(attrs, issue_number) do
    ticket_id = "SYM-#{issue_number}"
    text = build_ticket_text(ticket_id, attrs, issue_number)
    path = Path.join(tickets_path(), "#{ticket_id}.md")

    case File.write(path, text) do
      :ok -> {:ok, ticket_id}
      {:error, reason} -> {:error, {:write_failed, path, reason}}
    end
  end

  # ── GitHub-native dependencies ───────────────────────────────────────────────

  # `gh issue edit <new> --add-blocked-by <dep>`.
  #
  # Verified available rather than assumed: the CLI on this machine is 2.96.0, whose
  # `gh issue edit --help` documents `--add-blocked-by` / `--add-blocking` / `--add-sub-issue`
  # (issue dependencies shipped in 2.94.0). An earlier version of this module asserted that
  # GitHub had no native task-dependency field and wrote only a note into the issue body --
  # that was simply wrong, so the note is now a convenience and this is the mechanism.
  @spec link_dependencies(task_input(), String.t(), String.t()) :: {[String.t()], [String.t()]}
  defp link_dependencies(attrs, issue_number, repo) do
    {linked, warnings} =
      attrs
      |> Map.get(:blocked_by, [])
      |> List.wrap()
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.reduce({[], []}, fn dep, {linked, warnings} ->
        case add_blocked_by(issue_number, dep, repo) do
          :ok -> {[dep | linked], warnings}
          {:error, reason} -> {linked, [dependency_warning(dep, reason) | warnings]}
        end
      end)

    {Enum.reverse(linked), Enum.reverse(warnings)}
  end

  defp add_blocked_by(issue_number, dep_ticket_id, repo) do
    with {:ok, dep_issue_number} <- dependency_issue_number(dep_ticket_id) do
      args = [
        "issue",
        "edit",
        issue_number,
        "--repo",
        repo,
        "--add-blocked-by",
        dep_issue_number
      ]

      case Shell.run("gh", args, timeout: @command_timeout) do
        {:ok, _output, 0} ->
          Logger.info(
            "task_composer: ##{issue_number} blocked by ##{dep_issue_number} (#{dep_ticket_id})"
          )

          :ok

        {:ok, output, status} ->
          {:error, {:gh_exit, status, output}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # The form collects ticket ids (`SYM-1`); GitHub wants issue numbers. The ticket file's
  # `issue:` front-matter key is the only link between the two, so it is read from there
  # rather than guessed from the id (assuming `SYM-7` means issue 7 would be silently wrong
  # the moment a ticket is adopted or hand-written).
  defp dependency_issue_number(ticket_id) do
    path = Path.join(tickets_path(), "#{ticket_id}.md")

    case File.read(path) do
      {:ok, text} -> issue_number_in(text)
      {:error, :enoent} -> {:error, :no_such_ticket}
      {:error, reason} -> {:error, {:ticket_unreadable, reason}}
    end
  end

  defp issue_number_in(text) do
    case Ticket.split(text) do
      {:ok, %{front_matter: fm}} ->
        case presence(Ticket.get(fm, "issue")) do
          nil -> {:error, :ticket_has_no_issue_number}
          number -> {:ok, number}
        end

      :skip ->
        {:error, :ticket_has_no_front_matter}
    end
  end

  defp dependency_warning(dep, reason) do
    detail =
      case reason do
        :no_such_ticket -> "找不到这张票"
        :ticket_has_no_issue_number -> "这张票上没有 issue 号"
        :ticket_has_no_front_matter -> "这张票的文件没有 front matter"
        {:gh_exit, status, output} -> "gh 退出 #{status}：#{String.trim(output)}"
        other -> inspect(other)
      end

    "#{dep}：GitHub 依赖没连上（#{detail}）"
  end

  # ── Side-effecting: listing tickets ───────────────────────────────────────────

  @doc """
  Lists every ticket in the tickets directory, sorted by ID.

  Reads the same front matter the janitor reads, through `Ticket.split/1` and
  `Ticket.get/2`, so the management page and the janitor cannot disagree on what
  a ticket looks like.
  """
  @spec list_tickets() :: {:ok, [ticket()]} | {:error, term()}
  def list_tickets do
    path = tickets_path()

    case File.ls(path) do
      {:ok, entries} ->
        tickets =
          entries
          |> Enum.filter(&ticket_file?/1)
          |> Enum.map(&read_ticket(Path.join(path, &1)))
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(& &1.id)

        {:ok, tickets}

      {:error, reason} ->
        {:error, {:list_failed, path, reason}}
    end
  end

  defp ticket_file?(name) do
    String.ends_with?(name, ".md") and
      name != "README.md" and
      not String.starts_with?(name, "BOARD-")
  end

  defp read_ticket(path) do
    text = File.read!(path)

    case Ticket.split(text) do
      {:ok, %{front_matter: fm, body: body}} ->
        id = presence(Ticket.get(fm, "id")) || Path.rootname(Path.basename(path))

        %{
          id: id,
          title: presence(Ticket.get(fm, "title")) || id,
          state: presence(Ticket.get(fm, "state")) || "open",
          issue: presence(Ticket.get(fm, "issue")),
          issue_url: issue_url(presence(Ticket.get(fm, "issue"))),
          assignee: presence(Ticket.get(fm, "assignee_id")),
          priority: presence(Ticket.get(fm, "priority")),
          blocked_by: parse_blocked_by(Ticket.get(fm, "blocked_by")),
          body: body,
          path: path
        }

      :skip ->
        nil
    end
  end

  defp parse_blocked_by(value) when is_binary(value) do
    value
    |> String.replace(~r/[\[\]]/, "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_blocked_by(_), do: []

  defp issue_url(nil), do: nil
  defp issue_url(""), do: nil

  defp issue_url(issue_number) do
    "https://github.com/#{issues_repo()}/issues/#{issue_number}"
  end

  # ── Side-effecting: updating state ────────────────────────────────────────────

  @doc """
  Updates a ticket's `state` in its front matter.

  The janitor mirrors the new state to the GitHub issue label on its next round,
  so this is the only write needed.
  """
  @spec update_state(String.t(), String.t()) :: {:ok, ticket()} | {:error, term()}
  def update_state(ticket_id, new_state) do
    path = Path.join(tickets_path(), "#{ticket_id}.md")

    with {:ok, text} <- File.read(path),
         updated = Ticket.set_key(text, "state", new_state),
         :ok <- File.write(path, updated) do
      Logger.info("task_composer: #{ticket_id} state -> #{new_state}")
      {:ok, read_ticket(path)}
    else
      {:error, reason} -> {:error, {:update_failed, ticket_id, reason}}
    end
  end

  # ── Config resolution ─────────────────────────────────────────────────────────

  # The workflow's janitor block carries the paths; `Janitor.config/0` carries
  # this machine's defaults. Both are needed: a workflow that omits the janitor
  # block still needs a tickets directory.
  defp tickets_path do
    settings = Config.settings!().janitor
    present(settings.tickets_path) || Janitor.config().tickets
  end

  defp issues_repo do
    settings = Config.settings!().janitor
    present(settings.issues_repo) || Janitor.config().repo
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value), do: value

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value
end
