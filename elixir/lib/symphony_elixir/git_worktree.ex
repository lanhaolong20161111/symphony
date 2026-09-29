defmodule SymphonyElixir.GitWorktree do
  @moduledoc """
  A thin binding to `git worktree` -- shaped after herdr (`list` / `create` / `open` / `remove`),
  but bound to **git itself**.

  ## Coverage: every subcommand git 2.55.0 has

  Checked line by line against `git worktree -h`, not from memory:

  | `git worktree` | here | notes |
  |---|---|---|
  | `add` | `create/3` | `-b` `:branch` · `-B` `:reset_branch` · `<base>` `:base` · `--detach` · `--force` · `--orphan` · `--no-checkout` · `--lock [--reason]` |
  | `list` | `list/2` | `--porcelain`, and `-z` with `:nul` |
  | `lock` | `lock/3` | `--reason` |
  | `unlock` | `unlock/2` | |
  | `move` | `move/4` | reads the result back out of `list/2` |
  | `prune` | `prune/2` | `-n` with `:dry_run`, `-v` with `:verbose`, `--expire` with `:expire` |
  | `remove` | `remove/3` | `-f` with `:force` |
  | `repair` | `repair/3` | no paths repairs the current worktree, paths repair those |

  `open` is deliberately absent: git has no such verb (it is herdr's, and it opens a pane), and a
  caller already holds the path from `list/2` or `create/3`. Nothing else is absent -- but if git
  adds a subcommand, this table is the thing to update, and `git worktree -h` is the thing to check
  it against.

  ## Why not call herdr (three reasons, all checked)

  1. `herdr worktree create` reads "Create **and open** a Git worktree" -- it opens a pane. An
     orchestrator wants a *path*.
  2. herdr goes through a **socket API**, so its server must be running
     (`AiBeekeeper.Orchestration.WorkspacePrep` records this). That would make an external daemon a
     dependency of the orchestrator.
  3. The base of an isolation strategy should not be a *terminal* manager.

  ## Where the thinness is (this is the whole design)

  * **No stored list.** `git worktree list` is the only truth; `.git/worktrees/` belongs to git.
  * **No invented state.** The state is git's: normal / `detached` / `bare` / `locked` / `prunable`.
  * **No renamed concepts.** `path` / `head` / `branch`, not "workspace id".
  * **No translated errors.** If git says `already checked out`, that is what comes back.
  * **Nothing git does not have**, in verbs or in flags.

  ## Why this deserves its own module

  `.git` inside a worktree is a **file** (`gitdir: <main>/.git/worktrees/<name>`), not a directory.
  Every place that answers "is this a checkout?" from the filesystem answers it **wrongly and
  silently** -- `Janitor.publish_ticket/2` used `File.dir?(Path.join(workspace, ".git"))`, so a
  worktree workspace would leave its ticket in `in-review` forever with nothing saying why.

  So the judgement is `inside_work_tree?/1`: **ask git, not the filesystem.**

  `repair/3` is the other half of that story: a plain `mv` of a worktree -- or of the main checkout
  a whole directory of worktrees hangs off -- leaves the `gitdir` links pointing at the old place
  and every one of them stops working. `move/4` is the way to relocate one; `repair/3` is the way
  back if something already moved it the wrong way.
  """

  alias SymphonyElixir.Shell

  @default_timeout 60_000

  @typedoc "One `git worktree list --porcelain` block, in git's own vocabulary."
  @type worktree :: %{
          path: String.t(),
          head: String.t() | nil,
          branch: String.t() | nil,
          detached?: boolean(),
          bare?: boolean(),
          locked: String.t() | nil,
          prunable: String.t() | nil
        }

  @doc """
  `git worktree list --porcelain` in `repo`, parsed.

  Porcelain rather than the padded human output: porcelain is documented as stable, the column
  alignment of the human output is not.

  `:nul` adds `-z`, which separates fields with NUL instead of newline -- the difference that matters
  for a path containing a newline, which a line-based parse cannot represent. The structure is the
  same either way (fields, then an empty record separator), so it is one parser with two separators.

  `path` is **git's spelling** of the path, which can differ from the one you passed (separators,
  and case on Windows). Compare like paths, not like strings -- `create/3` does exactly that when it
  reads its result back.
  """
  @spec list(Path.t(), keyword()) :: {:ok, [worktree()]} | {:error, term()}
  def list(repo, opts \\ []) do
    args = ["worktree", "list", "--porcelain"] ++ if(Keyword.get(opts, :nul, false), do: ["-z"], else: [])

    case git(repo, args, opts) do
      {:ok, output, 0} -> {:ok, parse_list(output, separator(opts))}
      {:ok, output, status} -> {:error, {:git_exit, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  `git worktree add` -- creates a checkout of `repo` at `path`.

  Options mirror the command: `:branch` (`-b`, create), `:reset_branch` (`-B`, create or reset),
  `:base` (the commit-ish), `:detach`, `:force`, `:orphan`, `:checkout` (`false` for
  `--no-checkout`), `:lock` with `:lock_reason`, `:timeout`.

  The result is read back out of `list/2` rather than assembled from the arguments, so what comes
  back is what git says exists, not what was asked for.
  """
  @spec create(Path.t(), Path.t(), keyword()) :: {:ok, worktree()} | {:error, term()}
  def create(repo, path, opts \\ []) do
    args = ["worktree", "add"] ++ add_flags(opts) ++ [path] ++ base_args(opts)

    with {:ok, _output, 0} <- git(repo, args, opts),
         {:ok, worktrees} <- list(repo, opts),
         %{} = created <- Enum.find(worktrees, &same_path?(&1.path, path)) do
      {:ok, created}
    else
      {:ok, output, status} -> {:error, {:git_exit, status, output}}
      {:error, reason} -> {:error, reason}
      nil -> {:error, {:not_in_list, path}}
    end
  end

  @doc """
  `git worktree lock` -- protects the worktree from `prune`.

  `:reason` is passed as `--reason`. This is the write half of the `locked` field `list/2` reads;
  without it a locked worktree could be observed but not created.
  """
  @spec lock(Path.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def lock(repo, path, opts \\ []) do
    action(repo, ["worktree", "lock"] ++ reason_flag(Keyword.get(opts, :reason)) ++ [path], opts)
  end

  @doc "`git worktree unlock`."
  @spec unlock(Path.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def unlock(repo, path, opts \\ []), do: action(repo, ["worktree", "unlock", path], opts)

  @doc """
  `git worktree move` -- relocates a worktree **and** its administrative files.

  This is the way to move one. `mv` leaves the `gitdir` link pointing at the old location and the
  worktree stops working, which is what `repair/3` then exists to fix.

  The result is read back out of `list/2`, so the returned `path` is git's, not the argument's.
  """
  @spec move(Path.t(), Path.t(), Path.t(), keyword()) :: {:ok, worktree()} | {:error, term()}
  def move(repo, path, new_path, opts \\ []) do
    with :ok <- action(repo, ["worktree", "move", path, new_path], opts),
         {:ok, worktrees} <- list(repo, opts),
         %{} = moved <- Enum.find(worktrees, &same_path?(&1.path, new_path)) do
      {:ok, moved}
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, {:not_in_list, new_path}}
    end
  end

  @doc """
  `git worktree remove` -- removes the checkout at `path`.

  `:force` is passed through and git's refusal without it is left intact (a worktree with
  modifications comes back as `{:error, {:git_exit, …}}` carrying git's own message). Run
  `prune/2` afterwards to drop the administrative entry under `.git`.
  """
  @spec remove(Path.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def remove(repo, path, opts \\ []) do
    args = ["worktree", "remove"] ++ force_flag(opts) ++ [path]
    action(repo, args, opts)
  end

  @doc """
  `git worktree prune` -- drops administrative entries whose checkout is already gone.

  Returns `{:ok, output}`, not `:ok`: the dry run's entire value is git's answer about what would
  go, and git writes that to stdout. A normal run usually returns `""`.

  Options: `:dry_run` (`-n`), `:verbose` (`-v`), `:expire` (`--expire <expire>`).
  """
  @spec prune(Path.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def prune(repo, opts \\ []) do
    args =
      ["worktree", "prune"] ++
        if(Keyword.get(opts, :dry_run, false), do: ["-n"], else: []) ++
        if(Keyword.get(opts, :verbose, false), do: ["-v"], else: []) ++
        expire_flag(Keyword.get(opts, :expire))

    case git(repo, args, opts) do
      {:ok, output, 0} -> {:ok, output}
      {:ok, output, status} -> {:error, {:git_exit, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  `git worktree repair` -- re-links a worktree and its repository after one of them moved.

  With no paths it repairs the current worktree's links; with paths, those. This is the way back
  from a plain `mv` of a worktree, or of the directory the main checkouts live in -- every worktree
  underneath stops working, and nothing else in git fixes it.
  """
  @spec repair(Path.t(), [Path.t()], keyword()) :: :ok | {:error, term()}
  def repair(repo, paths \\ [], opts \\ []), do: action(repo, ["worktree", "repair"] ++ paths, opts)

  @doc """
  Whether `path` is inside a git work tree -- **asked of git**, not of the filesystem.

  This is the question `File.dir?(Path.join(path, ".git"))` answers wrongly: in a worktree `.git` is
  a file, so that test says "no" and its caller silently skips the work the ticket was waiting for.
  """
  @spec inside_work_tree?(Path.t(), keyword()) :: boolean()
  def inside_work_tree?(path, opts \\ []) do
    case git(path, ["rev-parse", "--is-inside-work-tree"], opts) do
      {:ok, output, 0} -> String.trim(output) == "true"
      _ -> false
    end
  end

  @doc """
  The directories git itself treats as this checkout's metadata: its git dir and its common dir.

  Asked of git rather than assumed, for the same reason as `inside_work_tree?/1`. A plain clone has one
  `.git` directory; a linked worktree has a `.git` **file** pointing at
  `<main>/.git/worktrees/<name>` and shares `<main>/.git` with its siblings, so the two answers differ
  and both matter. Measured: in a worktree `--absolute-git-dir` and `--git-common-dir` both come back
  absolute, while in a clone the common dir is the relative string `.git` -- so a relative line is joined
  onto the checkout before it is returned.

  **The text is passed through as it came, deliberately.** These paths go into a sandbox policy, and
  codex matches a policy entry against the path it derives from the session's working directory by plain
  string comparison. `Path.expand/2` would normalise a Windows drive letter to lower case (`c:/...`),
  which is *not* equal to the `C:/...` codex derives -- so the entry would not suppress the
  metadata carveout, and the same `.git` would end up both writable and read-only, read-only winning.
  Measured on SYM-54: `Path.expand` in this function, `"c:/…/SYM-54/.git"` in the policy, and a session
  whose `git commit` failed with `index.lock: Permission denied` while the permission profile listed
  `<workspace>/.git` as both `write` and `read`.
  """
  @spec metadata_paths(Path.t(), keyword()) :: {:ok, [Path.t()]} | {:error, term()}
  def metadata_paths(path, opts \\ []) do
    case git(path, ["rev-parse", "--absolute-git-dir", "--git-common-dir"], opts) do
      {:ok, output, 0} ->
        case output |> String.split("\n", trim: true) |> Enum.map(&join_against(&1, path)) do
          [] ->
            {:error, :not_a_work_tree}

          from_git ->
            # The checkout's own `.git` comes first, spelled with the same base string the session is
            # given -- that is the entry codex will match, because it derives its carveout from the
            # session's working directory. git's own answers follow, for the worktree case where the
            # metadata lives outside the checkout, and duplicates are dropped by spelling rather than
            # by string: `Path.expand/2` lower-cases a Windows drive letter, and `c:/...` is not
            # `C:/...` to a textual comparison.
            [Path.join(path, ".git") | from_git] |> Enum.uniq_by(&spelling/1) |> then(&{:ok, &1})
        end

      {:ok, _output, _status} ->
        {:error, :not_a_work_tree}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp join_against(line, path) do
    case String.trim(line) do
      "" -> path
      value -> if absolute_path?(value), do: value, else: Path.join(path, value)
    end
  end

  # `Path.join/2` keeps the first argument's form, which is the point: a relative `.git` becomes
  # `<checkout>/.git` with the checkout's own drive-letter case and separators, exactly as codex will
  # derive it from the session's cwd.
  defp absolute_path?(value) do
    Regex.match?(~r{^[A-Za-z]:[\\/]}, value) or String.starts_with?(value, ["/", "\\\\"])
  end

  # Two spellings of one directory: separators and letter case are all that may differ.
  defp spelling(value) do
    value |> String.replace("\\", "/") |> String.downcase() |> String.trim_trailing("/")
  end

  @doc """
  Parses `git worktree list --porcelain`, with `separator` as the field terminator (`"\\n"` by
  default, `"\\0"` for `-z`).

  Fields are `key value`, except the flags `detached` / `bare` / `locked` / `prunable`, which stand
  alone or carry a reason. A `locked` or `prunable` with no reason is `""`; `nil` means the flag was
  absent -- the two are different facts.

  Records are separated by an empty field (`\\n\\n`, or `\\0\\0` with `-z`) -- measured, not assumed:
  `-z` terminates every field with NUL and leaves the same empty separator between records.

  Unknown keys are ignored rather than rejected, so a newer git that adds a field does not make this
  raise.
  """
  @spec parse_list(String.t(), String.t()) :: [worktree()]
  def parse_list(output, separator \\ "\n") when is_binary(output) do
    normalized = if separator == "\n", do: String.replace(output, "\r\n", "\n"), else: output

    normalized
    |> String.split(separator <> separator, trim: true)
    |> Enum.flat_map(fn record ->
      record
      |> String.split(separator, trim: true)
      |> Enum.reduce(blank(), &apply_line/2)
      |> case do
        %{path: nil} -> []
        worktree -> [worktree]
      end
    end)
  end

  defp separator(opts), do: if(Keyword.get(opts, :nul, false), do: "\0", else: "\n")

  defp blank do
    %{path: nil, head: nil, branch: nil, detached?: false, bare?: false, locked: nil, prunable: nil}
  end

  # The porcelain keys git documents, one clause each. `parts: 2` keeps a reason with spaces intact,
  # and a `| rest` tail matches both the bare flag and the reasoned one, so there is one clause per
  # key rather than two.
  defp apply_line(line, acc) do
    case String.split(line, " ", parts: 2) do
      ["worktree", path] -> %{acc | path: path}
      ["HEAD", sha] -> %{acc | head: sha}
      ["branch", ref] -> %{acc | branch: String.replace_prefix(ref, "refs/heads/", "")}
      ["detached" | _] -> %{acc | detached?: true}
      ["bare" | _] -> %{acc | bare?: true}
      ["locked" | rest] -> %{acc | locked: flag_reason(rest)}
      ["prunable" | rest] -> %{acc | prunable: flag_reason(rest)}
      _unknown -> acc
    end
  end

  # A flag with a reason carries it; a bare flag is `""`, which is a different fact from `nil`
  # (the flag was absent).
  defp flag_reason([]), do: ""
  defp flag_reason([reason]), do: reason

  # One flag per option, in the order `git worktree add -h` lists them.
  defp add_flags(opts) do
    if(branch = Keyword.get(opts, :branch), do: ["-b", branch], else: []) ++
      if(branch = Keyword.get(opts, :reset_branch), do: ["-B", branch], else: []) ++
      if(Keyword.get(opts, :detach, false), do: ["--detach"], else: []) ++
      force_flag(opts) ++
      if(Keyword.get(opts, :orphan, false), do: ["--orphan"], else: []) ++
      if(Keyword.get(opts, :checkout, true), do: [], else: ["--no-checkout"]) ++
      if(Keyword.get(opts, :lock, false),
        do: ["--lock"] ++ reason_flag(Keyword.get(opts, :lock_reason)),
        else: []
      )
  end

  defp force_flag(opts), do: if(Keyword.get(opts, :force, false), do: ["--force"], else: [])

  defp reason_flag(nil), do: []
  defp reason_flag(reason), do: ["--reason", reason]

  defp expire_flag(nil), do: []
  defp expire_flag(expire), do: ["--expire", to_string(expire)]

  defp base_args(opts) do
    case Keyword.get(opts, :base) do
      nil -> []
      base -> [base]
    end
  end

  defp action(repo, args, opts) do
    case git(repo, args, opts) do
      {:ok, _output, 0} -> :ok
      {:ok, output, status} -> {:error, {:git_exit, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp git(dir, args, opts) do
    Shell.run("git", ["-C", dir] ++ args, timeout: Keyword.get(opts, :timeout, @default_timeout))
  end

  # git prints the path in its own spelling; the caller passed another. Compare like paths, not
  # like strings -- Windows is case-insensitive and both separators occur.
  defp same_path?(left, right), do: normalize_path(left) == normalize_path(right)

  defp normalize_path(path) do
    normalized = path |> String.replace("\\", "/") |> String.trim_trailing("/")
    if Shell.windows?(), do: String.downcase(normalized), else: normalized
  end
end
