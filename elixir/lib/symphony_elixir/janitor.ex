defmodule SymphonyElixir.Janitor do
  @moduledoc """
  The host-side caretaker for the file tracker: one round, and the loop that repeats it.

  Five jobs, in order:

    1. receive  a newly opened GitHub issue labelled `agent-task` becomes a ticket
    2. mirror   ticket <-> issue: state as a plain-language label, comments into the ticket,
                assignee into the ticket; closing the issue means the ticket is done
    3. boards   regenerate README.md and BOARD-<state>.md
    4. sync     commit ticket changes, pull, push
    5. publish  a ticket in `in-review` whose workspace is dirty (or whose branch has no PR) gets
                committed, pushed and turned into a PR, with the PR link commented back on the issue

  ## Why the host does this and not the agent

  Two measured facts, neither of which is a configuration mistake:

    * codex's `workspaceWrite` sandbox makes `.git/` read-only and `gh` cannot read its own config,
      so the agent cannot commit, push or open a PR at all.
    * the run task does not trap exits and reconcile kills it from the outside, so
      `hooks.after_run` never fires on the path where the agent sets the ticket to `in-review`.

  So the agent's job ends at "files changed, validation run, ticket set to `in-review`", and
  publishing is the host's.

  ## Why this is Elixir and not the PowerShell it replaces

  The PowerShell version worked and is kept in `elixir/scripts/janitor.ps1` for its comments, but it
  cost eleven Windows-specific traps (BOM-vs-ANSI script decoding, a static `Regex.Replace`
  overload with no count parameter, multi-line argv splitting, console-codepage stdout decoding,
  `$_` shadowing, pipe truncation, catastrophic regex backtracking, and a native call that hung a
  whole round for 62 minutes). Here arguments are lists, text is UTF-8 by construction, JSON is
  built in, every command has a killable timeout, and the pure parts have tests.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitWorktree
  alias SymphonyElixir.Janitor.{Board, Labels, Ticket}
  alias SymphonyElixir.Shell

  @task_label "agent-task"
  @managed_label "symphony"
  @command_timeout 120_000
  @terminal_states ~w(done cancelled)

  # A ticket identifier is also a path segment under two configured roots, and the caller of
  # `publish_now/2` is a language model. Anything that could climb out of those roots (a separator, a
  # leading dot, `..`, an absolute path) is refused rather than joined.
  @ticket_id ~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/

  # Marker left in the how-to comment so it is posted at most once per issue. A person who opens a
  # plain issue and sees nothing happen has no way to learn why; measured on issue #26, where the
  # answer was "there is no agent-task label" and nothing in the system said so.
  @howto_marker "<!-- symphony:how-to -->"
  @advice_window_days 7

  @typedoc "Everything the janitor needs to know about where things live."
  @type config :: %{
          tickets: String.t(),
          workspace_root: String.t(),
          repo: String.t() | nil,
          tickets_repo: String.t() | nil,
          state_file: String.t(),
          interval_seconds: pos_integer()
        }

  @doc """
  Builds the configuration, filling in this machine's defaults.

  Options: `:tickets`, `:workspace_root`, `:repo`, `:tickets_repo`, `:state_file`,
  `:interval_seconds`.

  The paths have defaults because they are this machine's own directories; **the two repositories do
  not**, because one is a name somebody else owns. A deployment that does not declare `:repo` gets
  `nil`, and every path that needs `owner/name` skips (or, for a caller that asked for one thing,
  fails closed) rather than reaching for a repository nobody named -- see `run_once/1`,
  `publish_sweep/1` and `publish_now/2`.
  """
  @spec config(keyword()) :: config()
  def config(opts \\ []) do
    home = System.user_home!()

    %{
      tickets: Keyword.get(opts, :tickets, Path.join([home, "code", "symphony-tickets"])),
      workspace_root:
        Keyword.get(opts, :workspace_root, Path.join([home, "code", "symphony-file-workspaces"])),
      # No repository default, deliberately: "not declared" means "do not guess". A built-in name
      # would make an undeclared deployment mirror into, link to and open pull requests against a
      # repository it never named -- which is what a default here did until it was removed.
      repo: Keyword.get(opts, :repo),
      tickets_repo: Keyword.get(opts, :tickets_repo),
      state_file: Keyword.get(opts, :state_file, Path.join([home, "code", "symphony-janitor-state.json"])),
      interval_seconds: Keyword.get(opts, :interval_seconds, 30)
    }
  end

  @doc """
  The janitor's options from a workflow's `janitor` settings.

  Public and next to `config/1` so the entry points cannot drift: anything that decides *where* the
  janitor works goes through here, and `config/1` fills in this machine's defaults for whatever the
  workflow left blank.
  """
  @spec options_from_settings(map()) :: keyword()
  def options_from_settings(settings) when is_map(settings) do
    [
      tickets: Map.get(settings, :tickets_path),
      workspace_root: Map.get(settings, :workspace_root),
      repo: Map.get(settings, :issues_repo),
      tickets_repo: Map.get(settings, :tickets_repo),
      state_file: Map.get(settings, :state_file),
      interval_seconds: interval_seconds(Map.get(settings, :interval_ms))
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  defp interval_seconds(ms) when is_integer(ms) and ms > 0, do: div(ms, 1_000)
  defp interval_seconds(_ms), do: nil

  @doc """
  Runs one round. Never raises: every step logs its own failure and the round continues.

  A janitor that stops because one `gh` call failed is worse than one that skips a step, because
  nothing is watching it.
  """
  @spec run_once(keyword()) :: :ok
  def run_once(opts \\ []) do
    cfg = config(opts)
    skip_mirror = Keyword.get(opts, :skip_mirror, false)

    rows = read_tickets(cfg)

    rows =
      cond do
        skip_mirror ->
          rows

        # The mirror is `gh` from end to end, so with no repository declared there is nowhere to
        # mirror to. Skipped, with the reason stated, rather than aimed at a name: this is the same
        # shape as `--skip-mirror`, which is the path that already existed for "do not talk to
        # GitHub this round".
        not repository?(cfg.repo) ->
          Logger.warning("janitor: no issues repository declared (janitor.issues_repo); skipping receive and mirror")

          rows

        true ->
          receive_issues(rows, cfg)
          rows = read_tickets(cfg)
          sync_issues(rows, cfg)
          read_tickets(cfg)
      end

    write_boards(rows, cfg)
    sync_tickets_repo(cfg)
    publish_sweep(cfg)
    :ok
  end

  @doc """
  Runs rounds forever, `interval_seconds` apart.

  Each round is wrapped so an unexpected crash cannot end the loop.
  """
  @spec run(keyword()) :: no_return()
  def run(opts \\ []) do
    cfg = config(opts)
    Logger.info("janitor started tickets=#{cfg.tickets} repo=#{inspect(cfg.repo)}")
    loop(cfg, opts)
  end

  defp loop(cfg, opts) do
    try do
      run_once(opts)
    rescue
      error -> Logger.error("janitor round crashed: #{Exception.message(error)}")
    catch
      kind, reason -> Logger.error("janitor round threw #{inspect(kind)}: #{inspect(reason)}")
    end

    Process.sleep(cfg.interval_seconds * 1_000)
    loop(cfg, opts)
  end

  # ── 1. receive ────────────────────────────────────────────────────────────────

  # Turns a new issue into a ticket. This exists so that a person who does not know git has an
  # entry point: they fill one box, and everything below is mechanical.
  #
  # The valuable conversion is the second form field. "How to tell it is done" becomes the ticket's
  # `## Validation`, because the workflow prompt requires a runnable check -- and when the field is
  # left blank the agent derives one itself and writes it down, so the person is never blocked on
  # knowing a command.
  defp receive_issues(rows, cfg) do
    args = ["issue", "list", "--repo", cfg.repo, "--label", @task_label,
            "--state", "open", "--json", "number,title,body", "--limit", "50"]

    case gh_json(args) do
      {:ok, issues} ->
        known = MapSet.new(rows, & &1.issue)
        Enum.each(issues, &receive_issue(&1, known, cfg))

      {:error, reason} ->
        Logger.warning("janitor: cannot list issues: #{inspect(reason)}")
    end

    advise_unlabelled(cfg)
    :ok
  end

  # Explains, on the issue itself, why nothing is happening.
  #
  # Silence is the worst outcome for the person this whole flow exists for: they open an issue, no
  # agent appears, and nothing anywhere says the label is the switch. This costs one comment per
  # recent unlabelled issue, ever, and it says both halves -- how to ask for work, and that a
  # question can be work too.
  defp advise_unlabelled(cfg) do
    since = Date.utc_today() |> Date.add(-@advice_window_days) |> Date.to_iso8601()

    args = ["issue", "list", "--repo", cfg.repo, "--state", "open", "--limit", "50",
            "--search", "created:>=#{since}", "--json", "number,labels,comments"]

    case gh_json(args) do
      {:ok, issues} -> Enum.each(issues, &advise_issue(&1, cfg))
      {:error, reason} -> Logger.warning("janitor: cannot scan for unlabelled issues: #{inspect(reason)}")
    end
  end

  defp advise_issue(issue, cfg) do
    if needs_advice?(issue) do
      number = to_string(issue["number"])
      gh(["issue", "comment", number, "--repo", cfg.repo, "--body", advice_text(cfg)])
      Logger.info("janitor: issue ##{number} has no #{@task_label} label; posted how-to")
    end
  end

  defp needs_advice?(issue) do
    labels = Enum.map(issue["labels"] || [], & &1["name"])

    managed =
      Enum.any?(labels, fn label ->
        label in [@task_label, @managed_label] or Labels.internal(label) != nil
      end)

    already_asked =
      Enum.any?(issue["comments"] || [], fn comment ->
        String.contains?(comment["body"] || "", @howto_marker)
      end)

    not managed and not already_asked
  end

  defp advice_text(cfg) do
    """
    这条 issue 上没有 `agent-task` 标签，所以 agent 不会处理它 —— janitor 只接收带这个标签的 issue，这样普通的 issue 不会被误当成任务。

    * **想让 agent 干活**（包括让它查东西、回答问题）：在右侧 Labels 里加上 **`agent-task`**，半分钟内它就会变成一张票并开工。
      下次也可以直接用那个表单：https://github.com/#{cfg.repo}/issues/new/choose
    * **只是随手记一下 / 纯讨论**：忽略这条评论就行，不用做任何事。

    #{@howto_marker}
    """
  end

  defp receive_issue(issue, known, cfg) do
    number = to_string(issue["number"])

    unless MapSet.member?(known, number) do
      create_ticket_from_issue(issue, number, cfg)
    end
  end

  defp create_ticket_from_issue(issue, number, cfg) do
    id = "SYM-#{number}"
    body = to_string(issue["body"] || "")
    what = Ticket.form_answer(body, "要做什么") || String.trim(body)
    done = Ticket.form_answer(body, "怎么算做完了")

    text =
      Ticket.build(id, to_string(issue["title"] || id), number, what) <>
        if done in [nil, "", "_No response_", "No response"], do: "", else: "\n## Validation\n\n#{done}\n"

    path = Path.join(cfg.tickets, "#{id}.md")
    File.write!(path, text)
    Logger.info("janitor: created #{id}.md from issue ##{number}")
  end

  # ── 2. mirror ─────────────────────────────────────────────────────────────────

  defp sync_issues(rows, cfg) do
    state = read_state(cfg)

    state =
      Enum.reduce(rows, state, fn row, acc ->
        case sync_issue(row, acc, cfg) do
          {:ok, updated} -> updated
          {:error, reason} ->
            Logger.warning("janitor: mirror failed for #{row.id}: #{inspect(reason)}")
            acc
        end
      end)

    write_state(cfg, state)
  end

  # Decides what the ticket's state should become, from what the issue says about it.
  #
  # Precedence, and why:
  #
  #   1. **A closed issue wins over any label.** Closing is deliberate and unmistakable; whatever
  #      label is left behind is just the state it had when it was closed. Reading that label back
  #      is how a ticket the person had just finished got flipped to `ready` on the very next line
  #      of the log -- and, because it happened every round, the mirror never settled.
  #   2. **A label equal to the state we last pushed means there is nothing to do.** Both sides
  #      write, so without this rule they overwrite each other every round.
  #   3. **A label equal to the ticket's own state means the agent already got there.**
  #   4. Otherwise the label is a person's instruction, and it wins.
  #
  # Everything is compared as *internal* states. Comparing an internal state against the label a
  # person sees is never equal -- that was the second half of the same bug, and it is why the
  # bookkeeping stores `state` rather than `label`.
  @doc """
  The state a ticket should take given what its issue reports, or `:keep`.

  Input keys: `:closed`, `:claimed` (internal state or `nil`), `:last` (the internal state the
  janitor last pushed) and `:current` (the ticket's own state).
  """
  @spec next_state(%{
          closed: boolean(),
          claimed: String.t() | nil,
          last: String.t() | nil,
          current: String.t()
        }) :: String.t() | :keep
  def next_state(%{closed: true, current: current}) do
    if current in @terminal_states, do: :keep, else: "done"
  end

  def next_state(%{claimed: nil}), do: :keep
  def next_state(%{claimed: claimed, last: last}) when claimed == last, do: :keep
  def next_state(%{claimed: claimed, current: current}) when claimed == current, do: :keep
  def next_state(%{claimed: claimed}), do: claimed

  # Clauses of `sync_issue/3` stay adjacent: a clause on the far side of another function is a
  # compiler warning, and `--warnings-as-errors` turns that into a gate failure.
  defp sync_issue(%{issue: ""} = row, state, cfg), do: adopt_issue(row, state, cfg)

  defp sync_issue(row, state, cfg) do
    entry = Map.get(state, row.id, %{"state" => nil, "comment" => 0})

    with {:ok, issue} <- gh_json(["issue", "view", row.issue, "--repo", cfg.repo,
                                       "--json", "state,labels,assignees,comments"]) do
      labels = Enum.map(issue["labels"] || [], & &1["name"])

      decision =
        next_state(%{
          closed: issue["state"] == "CLOSED",
          claimed: Labels.state_from_labels(labels),
          last: entry["state"],
          current: row.state
        })

      {row, entry} = apply_state(row, decision, entry)
      row = pull_assignee(row, issue)
      entry = pull_comments(row, issue, entry)
      entry = push_label(row, labels, entry, cfg)

      {:ok, Map.put(state, row.id, entry)}
    end
  end

  defp apply_state(row, :keep, entry), do: {row, entry}

  defp apply_state(row, state, entry) do
    write_state_key(row, "state", state)
    Logger.info("janitor: #{row.id} state -> #{state}")
    {%{row | state: state, state_label: Labels.friendly(state)}, Map.put(entry, "state", state)}
  end

  # A ticket with no issue (created by hand) gets one, and the number goes back into the ticket so
  # the link is stable in both directions without searching by title.
  defp adopt_issue(row, state, cfg) do
    path = Path.join(cfg.tickets, "#{row.id}.md")

    args = ["issue", "create", "--repo", cfg.repo, "--title", "[#{row.id}] #{row.title}",
            "--body", body_for_issue(row, cfg), "--label", @managed_label]

    args =
      case Labels.friendly(row.state) do
        nil -> args
        label -> args ++ ["--label", label]
      end

    case Shell.run("gh", args, timeout: @command_timeout) do
      {:ok, output, 0} ->
        case Regex.run(~r{/issues/(\d+)}, output) do
          [_, number] ->
            File.write!(path, Ticket.set_key(File.read!(path), "issue", number))
            Logger.info("janitor: #{row.id} adopted into issue ##{number}")
            {:ok, Map.put(state, row.id, %{"state" => row.state, "comment" => 0})}

          _ ->
            {:error, {:unexpected_output, output}}
        end

      {:ok, output, status} ->
        {:error, {:exit, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The ticket link is dropped rather than invented when the deployment declares no ticket
  # repository: the issue body is complete without it, and a link built on a guessed repository
  # would send a reader to somebody else's file.
  defp body_for_issue(row, cfg) do
    case ticket_url(row.id, cfg) do
      nil -> row.body
      url -> "Ticket file: #{url}\n\n#{row.body}"
    end
  end

  defp pull_assignee(row, issue) do
    case issue["assignees"] do
      [%{"login" => login} | _] when login != row.assignee ->
        write_state_key(row, "assignee_id", login)
        Logger.info("janitor: #{row.id} assignee_id <- issue (#{login})")
        %{row | assignee: login}

      _ ->
        row
    end
  end

  # Human write surface: comment threads, appended to the ticket so the agent reads them next run.
  #
  # Comment ids are 64-bit -- one measured 5845913451, well past Int32 -- so they are compared as
  # integers, never cast down.
  defp pull_comments(row, issue, entry) do
    last = entry["comment"] || 0

    new =
      (issue["comments"] || [])
      |> Enum.filter(fn comment -> comment_id(comment) > last end)

    if new == [] do
      entry
    else
      append_discussion(row, new)
      Logger.info("janitor: #{row.id} += #{length(new)} comment(s)")
      Map.put(entry, "comment", new |> Enum.map(&comment_id/1) |> Enum.max())
    end
  end

  defp comment_id(comment) do
    case Regex.run(~r/#issuecomment-(\d+)/, comment["url"] || "") do
      [_, id] -> String.to_integer(id)
      _ -> 0
    end
  end

  @doc """
  One `## Discussion` entry for a GitHub comment.

  Linear's comments are addressable objects -- an id, an author, a timestamp, editable in place -- and
  a Markdown section is the closest a file ticket can get: the id GitHub gave the comment goes in the
  entry, so a later reader (or a tool) can name one and edit exactly it. `id=0` means the comment's
  URL carried no id, which is visible rather than silent.

  Newlines are flattened because a ticket's front matter and body are line-oriented: a comment whose
  body contains `---` or `## Discussion` must not be able to forge structure in the ticket.
  """
  @spec discussion_entry(map()) :: String.t()
  def discussion_entry(comment) when is_map(comment) do
    Ticket.comment_line(
      get_in(comment, ["author", "login"]) || "unknown",
      comment["createdAt"],
      comment["body"],
      comment_id(comment)
    )
  end

  defp append_discussion(row, comments) do
    text = File.read!(row.path)

    block = Enum.map_join(comments, "\n", &discussion_entry/1)

    text =
      if Regex.match?(~r/^## Discussion/m, text) do
        text
      else
        String.trim_trailing(text) <> "\n\n## Discussion\n"
      end

    File.write!(row.path, String.trim_trailing(text) <> "\n" <> block <> "\n")
  end

  # Ticket -> issue: keep the labels in step with the ticket, which is the single source of truth.
  # `row` here is the row *after* the pull steps, so a ticket the person just closed stays `done`
  # instead of having its previous label written back over it.
  defp push_label(row, labels, entry, cfg) do
    desired = Labels.friendly(row.state)
    stale = Enum.filter(labels, &(Labels.internal(&1) != nil and &1 != desired))

    cond do
      desired == nil ->
        entry

      desired in labels and stale == [] ->
        entry

      true ->
        unless desired in labels do
          gh(["issue", "edit", row.issue, "--repo", cfg.repo, "--add-label", desired])
        end

        Enum.each(stale, fn label ->
          gh(["issue", "edit", row.issue, "--repo", cfg.repo, "--remove-label", label])
        end)

        # Record the internal state we just put on the issue, so the next round's read of that same
        # label is recognised as ours rather than as a person's instruction.
        Map.put(entry, "state", row.state)
    end
  end

  # ── 3. boards ─────────────────────────────────────────────────────────────────

  defp write_boards(rows, cfg) do
    options = [repo: cfg.repo, interval_seconds: cfg.interval_seconds]

    File.write!(Path.join(cfg.tickets, "README.md"), Board.render_index(rows, options))

    for view <- Board.views() do
      path = Path.join(cfg.tickets, "BOARD-#{view.state}.md")
      File.write!(path, Board.render_view(view, rows))
    end
  end

  # ── 4. ticket repo sync ───────────────────────────────────────────────────────

  defp sync_tickets_repo(cfg) do
    git(cfg, ["add", "-A"])

    case git(cfg, ["diff", "--cached", "--name-only"]) do
      {:ok, "", _status} ->
        :ok

      {:ok, names, _status} ->
        changed = names |> String.split("\n", trim: true) |> Enum.join(", ")
        git(cfg, ["commit", "-q", "-m", "tickets: sync (#{changed})"])
        Logger.info("janitor: committed #{changed}")

      {:error, reason} ->
        Logger.warning("janitor: cannot inspect the ticket repo: #{inspect(reason)}")
    end

    git(cfg, ["pull", "--rebase", "--autostash"])
    git(cfg, ["push"])
  end

  # ── 5. publish sweep ──────────────────────────────────────────────────────────

  # Criterion: the ticket is `in-review` AND (the workspace is dirty OR the branch has no PR yet).
  #
  # The second half is not redundant: when the push succeeds and `gh pr create` fails, the workspace
  # is already clean, so a dirty-only trigger would never retry.
  #
  # The sweep decides *whether* to publish from `gh` (`has_pull_request?`), so with no repository
  # declared it is skipped whole rather than half-run: pushing a branch whose pull request can never
  # be opened is a new failure mode, and skipping is already what this function does when there is
  # no workspace root to look in.
  defp publish_sweep(cfg) do
    if repository?(cfg.repo) do
      case File.ls(cfg.workspace_root) do
        {:ok, entries} -> Enum.each(entries, &publish_ticket(&1, cfg))
        {:error, reason} -> Logger.warning("janitor: no workspace root: #{inspect(reason)}")
      end
    else
      Logger.warning("janitor: no issues repository declared (janitor.issues_repo); skipping the publish sweep")
    end
  end

  defp publish_ticket(id, cfg) do
    workspace = Path.join(cfg.workspace_root, id)
    ticket_path = Path.join(cfg.tickets, "#{id}.md")

    # `GitWorktree.inside_work_tree?/1`, not `File.dir?(Path.join(workspace, ".git"))`: in a git
    # worktree `.git` is a *file*, so the filesystem test answered "no" and this function returned
    # `:ok` -- the ticket sat in `in-review` forever and nothing anywhere said why. Ask git.
    with true <- GitWorktree.inside_work_tree?(workspace),
         true <- File.exists?(ticket_path),
         text = File.read!(ticket_path),
         true <- text =~ ~r/^state:\s*in-review\s*$/m do
      branch = ticket_branch(text, id)

      # Always: the ticket records its own branch and pull request, whether or not this sweep has
      # anything left to push. An agent that pushed and opened the PR itself leaves a clean tree and a
      # live PR -- exactly the case the old gate short-circuited, so the ticket ended up carrying
      # neither field. Measured on SYM-53.
      record_publish_metadata(ticket_path, branch, cfg)

      if git(workspace, ["status", "--porcelain"]) != {:ok, "", 0} or
           not has_pull_request?(branch, cfg) do
        publish(id, workspace, ticket_path, branch, cfg)
      else
        Logger.debug("janitor: #{id} nothing left to publish (workspace=#{workspace})")
        :ok
      end
    else
      # Every guard above is a boolean, so `false` is the only other outcome -- the compiler says so
      # when that stops being true.
      #
      # Debug, not warning: the common case is "nothing to publish", and this runs every round for
      # every in-review ticket. It exists so a judgement that goes wrong again is findable.
      false ->
        Logger.debug("janitor: #{id} not published (workspace=#{workspace})")
        :ok
    end
  end

  @doc """
  Adds a comment to a ticket: the file tracker's counterpart of Linear's `commentCreate`.

  A file ticket's mutation API is editing the file, which is why the agent's tool list has no CRUD
  surface -- but a comment is the one thing an edit cannot do safely: appending to the body by hand can
  break the ticket's structure. So the host writes it, in the reserved `## Discussion` section, and
  assigns the id (`local-1`, `local-2`, ...), because GitHub's comment ids belong to the entries the
  janitor mirrors in from the issue and the two spaces should stay distinguishable.

  Fails closed on the same things `publish_now/2` does: an `id` that is not a plain ticket name, or a
  ticket file that does not exist.
  """
  @spec comment_on_ticket(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def comment_on_ticket(id, body, opts \\ []) when is_binary(id) and is_binary(body) do
    with :ok <- validate_id(id),
         cfg = config(Keyword.merge(options_from_settings(Config.settings!().janitor), opts)),
         ticket_path = Path.join(cfg.tickets, "#{id}.md"),
         true <- File.exists?(ticket_path) or {:error, {:no_such_ticket, id}} do
      text = File.read!(ticket_path)
      comment_id = Ticket.next_local_id(text)

      File.write!(ticket_path, Ticket.append_comment(text, "agent", body, comment_id))

      {:ok, %{ticket: id, comment: %{id: comment_id, author: "agent"}}}
    end
  end

  @doc """
  Publishes one ticket now: commits its workspace, pushes its branch and opens the pull request.
  Returns what happened, so a caller can report the branch and the pull-request URL.

  `publish_sweep/1` decides *when* a ticket should be published; this is the same work without that
  decision, for a caller that has already made it -- the agent, through
  `SymphonyElixir.Janitor.AgentTool`. Both paths are idempotent, so they tolerate each other.

  Fails closed on anything it cannot identify: an `id` that is not a plain ticket name, a ticket file
  that does not exist, a workspace that is not a git work tree, or a deployment that declares no
  `janitor.issues_repo` (`publish_sweep/1` skips its unattended round in that case, but a caller that
  asked for this one ticket gets the reason instead of silence). Nothing is created or pushed in
  those cases.
  """
  @spec publish_now(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def publish_now(id, opts \\ []) when is_binary(id) do
    with :ok <- validate_id(id),
         cfg = config(Keyword.merge(options_from_settings(Config.settings!().janitor), opts)),
         workspace = Path.join(cfg.workspace_root, id),
         ticket_path = Path.join(cfg.tickets, "#{id}.md"),
         :ok <- publishable(id, workspace, ticket_path),
         :ok <- repository_declared(cfg) do
      branch = ticket_branch(File.read!(ticket_path), id)
      {:ok, publish(id, workspace, ticket_path, branch, cfg)}
    end
  end

  # Last, so a caller hears about what it actually passed first. Publishing is `gh` from end to end
  # (`pr list`, `pr create`, `issue comment`), and "no repository" is not something to guess at.
  defp repository_declared(cfg) do
    if repository?(cfg.repo), do: :ok, else: {:error, :no_issues_repo}
  end

  defp validate_id(id) do
    if Regex.match?(@ticket_id, id), do: :ok, else: {:error, {:invalid_ticket_id, id}}
  end

  defp publishable(id, workspace, ticket_path) do
    cond do
      not File.exists?(ticket_path) -> {:error, {:no_such_ticket, id}}
      not GitWorktree.inside_work_tree?(workspace) -> {:error, {:not_a_workspace, workspace}}
      true -> :ok
    end
  end

  # Recording is separated from publishing because the two now happen at different times: the agent
  # commits and pushes, and this sweep is often the first thing to notice that the pull request exists.
  # Both writes are idempotent, so a round that does publish records the same values twice and changes
  # nothing the second time.
  defp record_publish_metadata(ticket_path, branch, cfg) do
    record_branch(ticket_path, branch)

    case existing_pull_request(branch, cfg) do
      {:ok, url} -> record_pull_request(ticket_path, url)
      _ -> :ok
    end
  end

  # ── the branch this ticket publishes on ──────────────────────────────────────

  @doc """
  The branch this ticket publishes on: its own `branch_name`, or `symphony/<id>`.

  `branch_name` is the tracker-provided branch metadata the spec's normalized issue carries, and the
  file tracker already parses it. Reading it here is what makes it load-bearing rather than
  decorative. Read through `Ticket.split/1` rather than by scanning the file, for the same reason
  `issue_number/1` parses: a body line that happens to read `branch_name: something` must not decide
  where the work gets published.
  """
  @spec ticket_branch(String.t(), String.t()) :: String.t()
  def ticket_branch(ticket_text, id) when is_binary(ticket_text) and is_binary(id) do
    case Ticket.split(ticket_text) do
      {:ok, %{front_matter: front_matter}} ->
        presence(Ticket.get(front_matter, "branch_name")) || "symphony/#{id}"

      :skip ->
        "symphony/#{id}"
    end
  end

  @doc """
  Records `branch` in a ticket's front matter, unless the ticket already names one.

  The "unless" is the load-bearing part: a branch name written in the ticket is the tracker-provided
  value, so the derived default must never overwrite it.
  """
  @spec with_branch_name(String.t(), String.t()) :: String.t()
  def with_branch_name(ticket_text, branch) when is_binary(ticket_text) and is_binary(branch) do
    case Ticket.split(ticket_text) do
      {:ok, %{front_matter: front_matter}} ->
        if presence(Ticket.get(front_matter, "branch_name")) do
          ticket_text
        else
          Ticket.set_key(ticket_text, "branch_name", branch)
        end

      :skip ->
        ticket_text
    end
  end

  # Recorded on the ticket before the first push, so the name a person reads there is the name every
  # later round uses -- including when the push itself fails and the round retries.
  defp record_branch(ticket_path, branch) do
    text = File.read!(ticket_path)
    updated = with_branch_name(text, branch)

    if updated == text, do: :ok, else: File.write!(ticket_path, updated)
  end

  defp publish(id, workspace, ticket_path, branch, cfg) do
    record_branch(ticket_path, branch)

    dirty? = git(workspace, ["status", "--porcelain"]) != {:ok, "", 0}

    committed =
      if dirty? do
        git(workspace, ["checkout", "-B", branch])
        git(workspace, ["add", "-A"])
        git(workspace, ["-c", "user.name=symphony", "-c", "user.email=symphony@local",
                        "commit", "-q", "-m", "symphony/#{id}: automated change"])
        Logger.info("janitor: #{id} committed on #{branch}")
        true
      else
        false
      end

    # The branch is created whether or not there was anything to commit. An agent whose sandbox lets it
    # work makes its own commit on whatever branch the clone came with, leaving a **clean** tree -- and
    # the first version of this only created the branch in the dirty case, so the push sent the wrong
    # ref and `gh pr create` answered "No commits between main and symphony/<id>", with no PR and no
    # error anywhere the ticket could see. Measured on SYM-50, the first run with
    # `codex.git_metadata_writable: true`.
    moved = ensure_branch(workspace, branch)

    pushed = push_branch(id, workspace, branch)

    %{
      branch: branch,
      committed: committed,
      moved_to_branch: moved,
      pushed: pushed,
      pull_request: publish_pull_request(id, workspace, ticket_path, branch, cfg)
    }
  end

  # `checkout -B` on a clean tree just moves the branch to the commit that is already there, which is
  # exactly what the agent's own commit needs.
  defp ensure_branch(workspace, branch) do
    case git(workspace, ["branch", "--show-current"]) do
      {:ok, current, 0} -> String.trim(current) != branch and create_branch(workspace, branch)
      _ -> create_branch(workspace, branch)
    end
  end

  defp create_branch(workspace, branch) do
    case git(workspace, ["checkout", "-B", branch]) do
      {:ok, _output, 0} ->
        true

      other ->
        Logger.warning("janitor: cannot switch to #{branch}: #{inspect(other)}")
        false
    end
  end

  # Only says "pushed" when git agreed: the first version logged success unconditionally, so a failed
  # push read as a successful one in the log while `gh` reported a blank head sha.
  defp push_branch(id, workspace, branch) do
    if remote_branch?(workspace, branch) do
      false
    else
      case git(workspace, ["push", "-u", "origin", branch]) do
        {:ok, _output, 0} ->
          Logger.info("janitor: #{id} pushed #{branch}")
          true

        other ->
          Logger.warning("janitor: #{id} push failed for #{branch}: #{inspect(other)}")
          false
      end
    end
  end

  # An existing pull request is the answer, not a reason to make a second one. A `gh` failure is not
  # treated as "no pull request": the sweep tries again next round, and inventing a branch because
  # GitHub could not be reached is how duplicates happen.
  defp publish_pull_request(id, workspace, ticket_path, branch, cfg) do
    case existing_pull_request(branch, cfg) do
      {:ok, url} ->
        record_pull_request(ticket_path, url)
        url

      :none ->
        case create_pull_request(id, workspace, ticket_path, branch, cfg) do
          url when is_binary(url) ->
            record_pull_request(ticket_path, url)
            url

          other ->
            other
        end

      {:error, reason} ->
        Logger.warning("janitor: #{id} cannot list pull requests for #{branch}: #{inspect(reason)}")
        nil
    end
  end

  # The ticket is the tracker, so the link goes on the ticket -- the counterpart of Linear's
  # `attachmentLinkGitHubPR`, and the thing a later reader looks for. Written whether the pull request
  # was opened now or already existed, and idempotent either way.
  defp record_pull_request(ticket_path, url) do
    text = File.read!(ticket_path)
    updated = Ticket.add_link(text, url, "PR #{pull_request_number(url)}", "pr")

    if updated == text, do: :ok, else: File.write!(ticket_path, updated)
  end

  defp pull_request_number(url) do
    url |> String.split("/") |> List.last() |> to_string()
  end

  # `gh` must run with the workspace as its cwd: `--fill` would ask git for `main...branch`, and the
  # janitor's own cwd is the tickets repository, which has neither. An explicit title and body
  # removes the dependency on git context entirely.
  defp create_pull_request(id, workspace, ticket_path, branch, cfg) do
    body = "Automated by symphony for ticket #{id}." <> ticket_reference(id, cfg)

    args = ["pr", "create", "--repo", cfg.repo, "--head", branch, "--base", "main",
            "--label", @managed_label, "--title", "symphony/#{id}: automated change", "--body", body]

    case Shell.run("gh", args, cd: workspace, timeout: @command_timeout) do
      {:ok, output, 0} ->
        Logger.info("janitor: #{id} PR #{String.trim(output)}")
        comment_pr_link(id, ticket_path, output, cfg)
        pull_request_url(output)

      {:ok, output, status} ->
        Logger.warning("janitor: #{id} pr create exited #{status}: #{String.trim(output)}")
        nil

      {:error, reason} ->
        Logger.warning("janitor: #{id} pr create failed: #{inspect(reason)}")
        nil
    end
  end

  # Posts the pull request's URL onto the issue, which is what lets a person follow progress without
  # ever leaving it.
  #
  # Every path here says something. The first version used a `with` whose `else` was `_ -> :ok`, and
  # the pattern was `[_, url] <- Regex.run(~r{https://\S+/pull/\d+}, ..)`: that regex has **no capture
  # group**, so `Regex.run/2` returns a one-element list and the two-element pattern never matched.
  # The comment was therefore never posted, for any ticket, in either mode -- and because the failure
  # path was silent, nothing anywhere said so.
  defp comment_pr_link(id, ticket_path, output, cfg) do
    with url when is_binary(url) <- pull_request_url(output),
         number when is_binary(number) <- issue_number(File.read!(ticket_path)) do
      body = "干完了，改动在这里：#{url}"

      case gh(["issue", "comment", number, "--repo", cfg.repo, "--body", body]) do
        {:ok, _output, 0} ->
          Logger.info("janitor: #{id} PR link posted to issue ##{number}")

        other ->
          Logger.warning("janitor: #{id} could not comment on issue ##{number}: #{inspect(other)}")
      end
    else
      nil ->
        Logger.warning("janitor: #{id} has no PR url or issue number; cannot post the link")
    end
  end

  @doc """
  The pull request URL out of `gh pr create`'s output, or `nil`.

  Public and tested because the shape of `Regex.run/2`'s return value is exactly what went wrong
  once: a pattern without a capture group returns `[match]`, not `[match, group]`.
  """
  @spec pull_request_url(String.t()) :: String.t() | nil
  def pull_request_url(output) when is_binary(output) do
    case Regex.run(~r{https://\S+/pull/\d+}, output) do
      [url] -> url
      _ -> nil
    end
  end

  def pull_request_url(_output), do: nil

  @doc """
  The issue number recorded in a ticket file, or `nil`.

  Reads the front matter through `Ticket.split/1` rather than scanning the whole file: a ticket whose
  body happens to contain a line like `issue: 999` must not be mistaken for a link to issue 999, and
  reusing the ticket parser keeps one definition of what the front matter even is.
  """
  @spec issue_number(String.t()) :: String.t() | nil
  def issue_number(ticket_text) when is_binary(ticket_text) do
    case Ticket.split(ticket_text) do
      {:ok, %{front_matter: front_matter}} ->
        case Ticket.get(front_matter, "issue") do
          "" -> nil
          number -> number
        end

      :skip ->
        nil
    end
  end

  def issue_number(_ticket_text), do: nil

  defp has_pull_request?(branch, cfg) do
    match?({:ok, _url}, existing_pull_request(branch, cfg))
  end

  # `--state all` on purpose: a *closed* pull request for this branch still means the branch was
  # published, so neither the sweep nor the tool should open a second one for it.
  defp existing_pull_request(branch, cfg) do
    case gh_json(["pr", "list", "--repo", cfg.repo, "--head", branch, "--state", "all",
                  "--json", "url", "--limit", "1"]) do
      {:ok, [%{"url" => url} | _]} when is_binary(url) -> {:ok, url}
      {:ok, _none} -> :none
      {:error, reason} -> {:error, reason}
    end
  end

  defp remote_branch?(workspace, branch) do
    case git(workspace, ["ls-remote", "--heads", "origin", branch]) do
      {:ok, output, 0} -> String.contains?(output, branch)
      _ -> false
    end
  end

  # ── tickets on disk ───────────────────────────────────────────────────────────

  defp read_tickets(cfg) do
    case File.ls(cfg.tickets) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&ticket_file?/1)
        |> Enum.map(&read_ticket(Path.join(cfg.tickets, &1), cfg))
        |> Enum.reject(&is_nil/1)
        |> Board.sort()

      {:error, reason} ->
        Logger.warning("janitor: cannot list tickets: #{inspect(reason)}")
        []
    end
  end

  defp ticket_file?(name) do
    String.ends_with?(name, ".md") and name != "README.md" and not String.starts_with?(name, "BOARD-")
  end

  defp read_ticket(path, _cfg) do
    text = File.read!(path)
    warn_if_intended_ticket(path, text)

    case Ticket.split(text) do
      {:ok, %{front_matter: fm, body: body}} ->
        id = presence(Ticket.get(fm, "id")) || Path.rootname(Path.basename(path))
        state = presence(Ticket.get(fm, "state")) || "open"

        %{
          path: path,
          id: id,
          title: presence(Ticket.get(fm, "title")) || id,
          state: state,
          state_label: Labels.friendly(state),
          priority: Ticket.get(fm, "priority"),
          assignee: Ticket.get(fm, "assignee_id"),
          blocked_by: String.replace(Ticket.get(fm, "blocked_by"), ~r/[\[\]]/, ""),
          issue: Ticket.get(fm, "issue"),
          body: body,
          updated: updated_at(path)
        }

      :skip ->
        nil
    end
  end

  # A file with no front matter is usually just prose -- this repository keeps a guide and the boards
  # next to the tickets -- so only shout when the file is *named* like a ticket. A BOM is worth saying
  # out loud even though parsing tolerates it now: it means a tool rewrote the file, and that tool may
  # have changed more than the BOM.
  defp warn_if_intended_ticket(path, text) do
    name = Path.basename(path)
    problems = Ticket.problems(text)

    worth_warning =
      :bom in problems or
        (Enum.any?(problems, &(&1 != :no_front_matter)) and named_like_a_ticket?(name))

    if worth_warning do
      Logger.warning("janitor: #{name} looks wrong: #{inspect(problems)}")
    end

    :ok
  end

  defp named_like_a_ticket?(name), do: Regex.match?(~r/^[A-Z]+-\d+\.md$/, name)

  # `time: :local`, not the default `:universal`. Formatting a UTC timestamp into a board a person
  # reads is how every "Updated" cell came out eight hours early -- and, because the value then
  # differed from the file it had just written, the board committed itself on every single round.
  defp updated_at(path) do
    with {:ok, %File.Stat{mtime: mtime}} <- File.stat(path, time: :local),
         {:ok, naive} <- NaiveDateTime.from_erl(mtime) do
      Calendar.strftime(naive, "%m-%d %H:%M")
    else
      _ -> ""
    end
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value

  defp write_state_key(row, key, value) do
    File.write!(row.path, Ticket.set_key(File.read!(row.path), key, value))
  end

  # ── state file ────────────────────────────────────────────────────────────────

  defp read_state(cfg) do
    with true <- File.exists?(cfg.state_file),
         {:ok, text} <- File.read(cfg.state_file),
         {:ok, decoded} when is_map(decoded) <- JSON.decode(text) do
      decoded
    else
      _ -> %{}
    end
  end

  defp write_state(cfg, state) do
    File.write!(cfg.state_file, JSON.encode!(state))
  rescue
    error -> Logger.warning("janitor: cannot write state: #{Exception.message(error)}")
  end

  # ── gh / git ──────────────────────────────────────────────────────────────────

  defp gh_json(args), do: Shell.run_json("gh", args, timeout: @command_timeout)
  defp gh(args), do: Shell.run("gh", args, timeout: @command_timeout)
  defp git(cfg_or_dir, args)

  defp git(%{tickets: tickets}, args), do: Shell.run("git", args, cd: tickets, timeout: @command_timeout)
  defp git(dir, args) when is_binary(dir), do: Shell.run("git", args, cd: dir, timeout: @command_timeout)

  @doc """
  The web URL of a ticket file, for linking into issues and pull requests, or `nil` when the
  deployment declares no `janitor.tickets_repo`.

  `nil` rather than a name: a link built on a repository nobody declared sends a reader somewhere
  arbitrary, so `body_for_issue/2` and `ticket_reference/2` leave the link out instead.
  """
  @spec ticket_url(String.t(), map()) :: String.t() | nil
  def ticket_url(id, cfg) do
    case presence(cfg.tickets_repo) do
      nil -> nil
      repo -> "https://github.com/#{repo}/blob/master/#{id}.md"
    end
  end

  # The half of a message that points at the ticket file, or nothing at all when there is no
  # repository to point at -- see `ticket_url/2`. An empty string concatenates cleanly, so a caller
  # never has to branch on it.
  defp ticket_reference(id, cfg) do
    case ticket_url(id, cfg) do
      nil -> ""
      url -> "\n\nSee the ticket: #{url}"
    end
  end

  # The one test every path that needs `owner/name` goes through. `config/1` guesses no repository,
  # so anything `gh`-shaped is gated here rather than being handed a `nil`.
  defp repository?(value), do: presence(value) != nil
end
