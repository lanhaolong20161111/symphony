defmodule SymphonyElixir.GitWorktree do
  @moduledoc """
  A thin binding to `git worktree` -- shaped after herdr (`list` / `create` / `open` / `remove`),
  but bound to **git itself**.

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
  * **Nothing git does not have.** herdr's `open`, `--label` and `--workspace` do not appear here.

  ## Why this deserves its own module

  `.git` inside a worktree is a **file** (`gitdir: <main>/.git/worktrees/<name>`), not a directory.
  Every place that answers "is this a checkout?" from the filesystem answers it **wrongly and
  silently** -- `Janitor.publish_ticket/2` used `File.dir?(Path.join(workspace, ".git"))`, so a
  worktree workspace would leave its ticket in `in-review` forever with nothing saying why.

  So the judgement is `inside_work_tree?/1`: **ask git, not the filesystem.**
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

  `path` is **git's spelling** of the path, which can differ from the one you passed (separators,
  and case on Windows). Compare like paths, not like strings -- `create/3` does exactly that when it
  reads its result back.
  """
  @spec list(Path.t(), keyword()) :: {:ok, [worktree()]} | {:error, term()}
  def list(repo, opts \\ []) do
    case git(repo, ["worktree", "list", "--porcelain"], opts) do
      {:ok, output, 0} -> {:ok, parse_list(output)}
      {:ok, output, status} -> {:error, {:git_exit, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  `git worktree add` -- creates a checkout of `repo` at `path`.

  Options mirror the command: `:branch` (`-b`), `:base` (the commit-ish), `:detach`, `:force`,
  `:timeout`.

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
  `git worktree remove` -- removes the checkout at `path`.

  `:force` is passed through and git's refusal without it is left intact (a worktree with
  modifications comes back as `{:error, {:git_exit, …}}` carrying git's own message). Run
  `prune/2` afterwards to drop the administrative entry under `.git`.
  """
  @spec remove(Path.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def remove(repo, path, opts \\ []) do
    args =
      ["worktree", "remove"] ++ if(Keyword.get(opts, :force, false), do: ["--force"], else: []) ++ [path]

    case git(repo, args, opts) do
      {:ok, _output, 0} -> :ok
      {:ok, output, status} -> {:error, {:git_exit, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "`git worktree prune` -- drop administrative entries whose checkout is already gone."
  @spec prune(Path.t(), keyword()) :: :ok | {:error, term()}
  def prune(repo, opts \\ []) do
    case git(repo, ["worktree", "prune"], opts) do
      {:ok, _output, 0} -> :ok
      {:ok, output, status} -> {:error, {:git_exit, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

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
  Parses `git worktree list --porcelain`.

  Blocks are separated by a blank line. Each line is `key value`, except the flags `detached` /
  `bare` / `locked` / `prunable`, which stand alone or carry a reason. A `locked` or `prunable` with
  no reason is `""`; `nil` means the flag was absent -- the two are different facts.

  Unknown keys are ignored rather than rejected, so a newer git that adds a field does not make this
  raise. That is also why every field here is one git already has: there is nothing else to parse.
  """
  @spec parse_list(String.t()) :: [worktree()]
  def parse_list(output) when is_binary(output) do
    output
    |> String.split(~r/\r?\n\r?\n/, trim: true)
    |> Enum.flat_map(fn block ->
      block
      |> String.split(~r/\r?\n/, trim: true)
      |> Enum.reduce(blank(), &apply_line/2)
      |> case do
        %{path: nil} -> []
        worktree -> [worktree]
      end
    end)
  end

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

  defp add_flags(opts) do
    branch = if(branch = Keyword.get(opts, :branch), do: ["-b", branch], else: [])
    detach = if(Keyword.get(opts, :detach, false), do: ["--detach"], else: [])
    force = if(Keyword.get(opts, :force, false), do: ["--force"], else: [])

    branch ++ detach ++ force
  end

  defp base_args(opts) do
    case Keyword.get(opts, :base) do
      nil -> []
      base -> [base]
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
