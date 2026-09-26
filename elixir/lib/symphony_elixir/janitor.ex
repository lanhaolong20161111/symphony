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

  alias SymphonyElixir.Janitor.{Board, Labels, Shell, Ticket}

  @task_label "agent-task"
  @managed_label "symphony"
  @command_timeout 120_000
  @terminal_states ~w(done cancelled)

  @typedoc "Everything the janitor needs to know about where things live."
  @type config :: %{
          tickets: String.t(),
          workspace_root: String.t(),
          repo: String.t(),
          tickets_repo: String.t(),
          state_file: String.t(),
          interval_seconds: pos_integer()
        }

  @doc """
  Builds the configuration, filling in this machine's defaults.

  Options: `:tickets`, `:workspace_root`, `:repo`, `:tickets_repo`, `:state_file`,
  `:interval_seconds`.
  """
  @spec config(keyword()) :: config()
  def config(opts \\ []) do
    home = System.user_home!()

    %{
      tickets: Keyword.get(opts, :tickets, Path.join([home, "code", "symphony-tickets"])),
      workspace_root:
        Keyword.get(opts, :workspace_root, Path.join([home, "code", "symphony-file-workspaces"])),
      repo: Keyword.get(opts, :repo, "lanhaolong20161111/beekeeper"),
      tickets_repo: Keyword.get(opts, :tickets_repo, "lanhaolong20161111/beekeeper-tickets"),
      state_file: Keyword.get(opts, :state_file, Path.join([home, "code", "symphony-janitor-state.json"])),
      interval_seconds: Keyword.get(opts, :interval_seconds, 30)
    }
  end

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
      if skip_mirror do
        rows
      else
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
    Logger.info("janitor started tickets=#{cfg.tickets} repo=#{cfg.repo}")
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

    :ok
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
    what = section(body, "要做什么") || String.trim(body)
    done = section(body, "怎么算做完了")

    text =
      Ticket.build(id, to_string(issue["title"] || id), number, what) <>
        if done in [nil, "", "_No response_", "No response"], do: "", else: "\n## Validation\n\n#{done}\n"

    path = Path.join(cfg.tickets, "#{id}.md")
    File.write!(path, text)
    Logger.info("janitor: created #{id}.md from issue ##{number}")
  end

  # GitHub renders a form answer as "### <label>\n<answer>", up to the next "###".
  defp section(body, label) do
    case Regex.run(~r/###\s*#{Regex.escape(label)}\s*\r?\n(.*?)(?=\r?\n###|\z)/s, body) do
      [_, answer] -> String.trim(answer)
      _ -> nil
    end
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

  defp sync_issue(%{issue: ""} = row, state, cfg), do: adopt_issue(row, state, cfg)

  defp sync_issue(row, state, cfg) do
    entry = Map.get(state, row.id, %{"label" => "", "comment" => 0})

    with {:ok, issue} <- gh_json(["issue", "view", row.issue, "--repo", cfg.repo,
                                       "--json", "state,labels,assignees,comments"]) do
      labels = Enum.map(issue["labels"] || [], & &1["name"])

      # Each step returns the row it may have changed. Dropping the updated row is how a closed
      # issue would get its "waiting for you" label written straight back on.
      {row, entry} = pull_closed(row, issue, entry)
      {row, entry} = pull_label(row, Labels.state_from_labels(labels), entry)
      row = pull_assignee(row, issue)
      entry = pull_comments(row, issue, entry)
      entry = push_label(row, labels, entry, cfg)

      {:ok, Map.put(state, row.id, entry)}
    end
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
            {:ok, Map.put(state, row.id, %{"label" => row.state_label, "comment" => 0})}

          _ ->
            {:error, {:unexpected_output, output}}
        end

      {:ok, output, status} ->
        {:error, {:exit, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp body_for_issue(row, cfg) do
    "Ticket file: https://github.com/#{cfg.tickets_repo}/blob/master/#{row.id}.md\n\n#{row.body}"
  end

  defp pull_closed(row, issue, entry) do
    cond do
      issue["state"] != "CLOSED" ->
        {row, entry}

      row.state in @terminal_states ->
        {row, entry}

      true ->
        write_state_key(row, "state", "done")
        Logger.info("janitor: #{row.id} state <- issue closed")
        {%{row | state: "done", state_label: Labels.friendly("done")}, Map.put(entry, "label", Labels.friendly("done"))}
    end
  end

  # Human write surface: the state label. The test is "not the label we last wrote", otherwise the
  # two sides overwrite each other every round.
  defp pull_label(row, claimed, entry) do
    last = entry["label"]

    cond do
      claimed == nil or claimed == last -> {row, entry}
      claimed == row.state -> {row, Map.put(entry, "label", claimed)}
      true ->
        write_state_key(row, "state", claimed)
        Logger.info("janitor: #{row.id} state <- issue label (#{Labels.friendly(claimed)})")
        {%{row | state: claimed, state_label: Labels.friendly(claimed)}, Map.put(entry, "label", claimed)}
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

  defp append_discussion(row, comments) do
    text = File.read!(row.path)

    block =
      Enum.map_join(comments, "\n", fn comment ->
        who = get_in(comment, ["author", "login"]) || "unknown"
        body = (comment["body"] || "") |> String.replace(~r/\r?\n/, " ") |> String.trim()
        "- **#{who}** (#{comment["createdAt"]}): #{body}"
      end)

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

        Map.put(entry, "label", desired)
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
  defp publish_sweep(cfg) do
    case File.ls(cfg.workspace_root) do
      {:ok, entries} -> Enum.each(entries, &publish_ticket(&1, cfg))
      {:error, reason} -> Logger.warning("janitor: no workspace root: #{inspect(reason)}")
    end
  end

  defp publish_ticket(id, cfg) do
    workspace = Path.join(cfg.workspace_root, id)
    ticket_path = Path.join(cfg.tickets, "#{id}.md")

    with true <- File.dir?(Path.join(workspace, ".git")),
         true <- File.exists?(ticket_path),
         true <- File.read!(ticket_path) =~ ~r/^state:\s*in-review\s*$/m,
         branch = "symphony/#{id}",
         dirty = git(workspace, ["status", "--porcelain"]),
         true <- dirty != {:ok, "", 0} or not has_pull_request?(branch, cfg) do
      publish(id, workspace, ticket_path, branch, cfg)
    else
      _ -> :ok
    end
  end

  defp publish(id, workspace, ticket_path, branch, cfg) do
    if git(workspace, ["status", "--porcelain"]) != {:ok, "", 0} do
      git(workspace, ["checkout", "-B", branch])
      git(workspace, ["add", "-A"])
      git(workspace, ["-c", "user.name=symphony", "-c", "user.email=symphony@local",
                      "commit", "-q", "-m", "symphony/#{id}: automated change"])
      Logger.info("janitor: #{id} committed on #{branch}")
    end

    unless remote_branch?(workspace, branch) do
      git(workspace, ["push", "-u", "origin", branch])
      Logger.info("janitor: #{id} pushed #{branch}")
    end

    unless has_pull_request?(branch, cfg) do
      create_pull_request(id, workspace, ticket_path, branch, cfg)
    end

    :ok
  end

  # `gh` must run with the workspace as its cwd: `--fill` would ask git for `main...branch`, and the
  # janitor's own cwd is the tickets repository, which has neither. An explicit title and body
  # removes the dependency on git context entirely.
  defp create_pull_request(id, workspace, ticket_path, branch, cfg) do
    body = "Automated by symphony for ticket #{id}.\n\nSee the ticket: #{ticket_url(id, cfg)}"

    args = ["pr", "create", "--repo", cfg.repo, "--head", branch, "--base", "main",
            "--label", @managed_label, "--title", "symphony/#{id}: automated change", "--body", body]

    case Shell.run("gh", args, cd: workspace, timeout: @command_timeout) do
      {:ok, output, 0} ->
        Logger.info("janitor: #{id} PR #{String.trim(output)}")
        comment_pr_link(id, ticket_path, output, cfg)

      {:ok, output, status} ->
        Logger.warning("janitor: #{id} pr create exited #{status}: #{String.trim(output)}")

      {:error, reason} ->
        Logger.warning("janitor: #{id} pr create failed: #{inspect(reason)}")
    end
  end

  # Commenting the link back is what lets a person follow progress without ever leaving the issue.
  defp comment_pr_link(id, ticket_path, output, cfg) do
    with [_, url] <- Regex.run(~r{https://\S+/pull/\d+}, output),
         [_, number] <- Regex.run(~r/^issue:\s*(\d+)/m, File.read!(ticket_path)) do
      gh(["issue", "comment", number, "--repo", cfg.repo, "--body", "干完了，改动在这里：#{url}"])
      Logger.info("janitor: #{id} PR link posted to issue ##{number}")
    else
      _ -> :ok
    end
  end

  defp has_pull_request?(branch, cfg) do
    case gh_json(["pr", "list", "--repo", cfg.repo, "--head", branch, "--state", "all",
                       "--json", "number"]) do
      {:ok, [_ | _]} -> true
      _ -> false
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
  # next to the tickets -- so only shout when the file is *named* like a ticket. A BOM is always
  # worth shouting about, because a BOM'd ticket is invisible to the tracker and nothing else in the
  # system will ever mention it.
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

  defp gh_json(args), do: Shell.json("gh", args, timeout: @command_timeout)
  defp gh(args), do: Shell.run("gh", args, timeout: @command_timeout)
  defp git(cfg_or_dir, args)

  defp git(%{tickets: tickets}, args), do: Shell.run("git", args, cd: tickets, timeout: @command_timeout)
  defp git(dir, args) when is_binary(dir), do: Shell.run("git", args, cd: dir, timeout: @command_timeout)

  @doc "The web URL of a ticket file, for linking into issues and pull requests."
  @spec ticket_url(String.t(), map()) :: String.t()
  def ticket_url(id, cfg), do: "https://github.com/#{cfg.tickets_repo}/blob/master/#{id}.md"
end
