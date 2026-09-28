defmodule SymphonyElixir.GitWorktreeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitWorktree

  describe "parse_list/1" do
    # The real shape, captured from `git worktree list --porcelain` on this machine.
    @two_worktrees """
    worktree C:/Users/lhl20/AppData/Local/Temp/probe/main
    HEAD 2517d81d5a4cd1c0b4b3e09806eafe044ef0d779
    branch refs/heads/master

    worktree C:/Users/lhl20/AppData/Local/Temp/probe/wt-test
    HEAD 2517d81d5a4cd1c0b4b3e09806eafe044ef0d779
    branch refs/heads/test-branch

    """

    test "reads path, head and branch, and strips the refs/heads prefix" do
      assert [main, wt] = GitWorktree.parse_list(@two_worktrees)

      assert main.path == "C:/Users/lhl20/AppData/Local/Temp/probe/main"
      assert main.head == "2517d81d5a4cd1c0b4b3e09806eafe044ef0d779"
      assert main.branch == "master"
      refute main.detached?

      assert wt.branch == "test-branch"
    end

    test "a detached worktree has no branch and says so" do
      assert [wt] =
               GitWorktree.parse_list("""
               worktree /tmp/wt
               HEAD abc123
               detached

               """)

      assert wt.branch == nil
      assert wt.detached?
    end

    test "locked and prunable carry a reason, and no reason is not the same as absent" do
      assert [locked, prunable, plain] =
               GitWorktree.parse_list("""
               worktree /tmp/a
               HEAD abc
               branch refs/heads/x
               locked some reason here

               worktree /tmp/b
               HEAD def
               prunable

               worktree /tmp/c
               HEAD 012

               """)

      assert locked.locked == "some reason here"
      assert prunable.prunable == ""
      assert plain.locked == nil
      assert plain.prunable == nil
    end

    test "a block with no worktree line is dropped rather than returned empty" do
      assert GitWorktree.parse_list("HEAD abc123\nbranch refs/heads/x\n") == []
      assert GitWorktree.parse_list("") == []
    end

    test "an unknown key is ignored, so a newer git does not break the parser" do
      assert [wt] =
               GitWorktree.parse_list("""
               worktree /tmp/wt
               HEAD abc
               branch refs/heads/x
               something-git-added-later with a value

               """)

      assert wt.path == "/tmp/wt"
      assert wt.branch == "x"
    end
  end

  describe "parse_list/2 with the -z separator" do
    # Measured, not assumed: `git worktree list --porcelain -z` terminates every field with NUL and
    # leaves the same empty separator between records (279 bytes, 9 NULs, 0 newlines for two
    # worktrees).
    @nul_blob "worktree /a\0HEAD 1\0branch refs/heads/x\0\0worktree /b\0HEAD 2\0locked why not\0\0"

    test "is the same structure with a NUL terminator" do
      assert [a, b] = GitWorktree.parse_list(@nul_blob, "\0")

      assert a.path == "/a"
      assert a.branch == "x"
      assert b.path == "/b"
      assert b.locked == "why not"
    end

    test "a path containing a newline survives -- which is the whole reason -z exists" do
      with_newline = "worktree /a\nb\0HEAD 1\0\0"

      assert [%{path: "/a\nb"}] = GitWorktree.parse_list(with_newline, "\0")

      # The newline-separated parse cannot represent it: the path is split in two, the second half is
      # not a key, and the record comes back with a truncated path.
      assert [%{path: "/a"}] = GitWorktree.parse_list("worktree /a\nb\nHEAD 1\n\n")
    end
  end

  # "Complete" is a claim, so it is checked rather than asserted. This reads git's own usage text and
  # fails when git grows a subcommand this module does not bind -- which is the only way the claim
  # stays true over time.
  describe "coverage against git's own usage text" do
    @bound %{
      "add" => :create,
      "list" => :list,
      "lock" => :lock,
      "unlock" => :unlock,
      "move" => :move,
      "prune" => :prune,
      "remove" => :remove,
      "repair" => :repair
    }

    test "every subcommand git documents has a function here" do
      documented = documented_subcommands()
      assert length(documented) >= 8, "expected git to document its subcommands, got #{inspect(documented)}"

      uncovered = documented -- Map.keys(@bound)

      assert uncovered == [],
             "git documents subcommands this binding does not cover: #{inspect(uncovered)} -- " <>
               "add them, then update the coverage table in the moduledoc"

      functions = GitWorktree.__info__(:functions)

      for {subcommand, fun} <- @bound do
        assert Enum.any?(functions, fn {name, _arity} -> name == fun end),
               "#{subcommand} is claimed as #{fun}, which the module does not export"
      end
    end

    test "the moduledoc's coverage table names the same subcommands git does" do
      # The source, not the compiled docs: the claim being checked is what the file tells a reader.
      source = File.read!("lib/symphony_elixir/git_worktree.ex")

      for subcommand <- documented_subcommands() do
        assert source =~ "`#{subcommand}`",
               "the coverage table does not mention `#{subcommand}`, which git documents"
      end
    end

    defp documented_subcommands do
      # `git worktree -h` exits 129 (it is a usage message), so the exit code is deliberately not
      # checked -- only the text is.
      {usage, _status} = System.cmd("git", ["worktree", "-h"], stderr_to_stdout: true)

      ~r/^\s*(?:usage: |or: )git worktree ([a-z-]+)/m
      |> Regex.scan(usage, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()
    end
  end

  # A round trip against the real git, because the point of this module is what git actually says.
  describe "against the real git" do
    setup do
      root = Path.join(System.tmp_dir!(), "git-worktree-test-#{System.unique_integer([:positive])}")
      main = Path.join(root, "main")
      File.mkdir_p!(main)

      {_, 0} = System.cmd("git", ["init", "-q", main])
      File.write!(Path.join(main, "f.txt"), "x\n")
      {_, 0} = System.cmd("git", ["-C", main, "add", "-A"])
      {_, 0} = System.cmd("git", ["-C", main, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"])

      on_exit(fn -> File.rm_rf(root) end)
      {:ok, root: root, main: main}
    end

    test "create/list/remove behave the way git says, and the workspace is detected as a work tree",
         %{root: root, main: main} do
      wt_path = Path.join(root, "wt-one")

      assert {:ok, created} = GitWorktree.create(main, wt_path, branch: "symphony/T-1")
      assert created.branch == "symphony/T-1"

      # The fact that made `File.dir?(.git)` the wrong question: in a worktree `.git` is a file.
      refute File.dir?(Path.join(wt_path, ".git"))
      assert File.regular?(Path.join(wt_path, ".git"))

      # ...and asking git gives the right answer anyway.
      assert GitWorktree.inside_work_tree?(wt_path)
      refute GitWorktree.inside_work_tree?(Path.join(root, "not-a-repo"))

      assert {:ok, worktrees} = GitWorktree.list(main)

      # `path` comes back in git's spelling (forward slashes here), so compare like paths, not like
      # strings -- which is what `create/3` does internally and what any caller must do too.
      assert Enum.any?(worktrees, &(same_path?(&1.path, wt_path) and &1.branch == "symphony/T-1"))
      assert Enum.any?(worktrees, &same_path?(&1.path, main))

      assert :ok = GitWorktree.remove(main, wt_path)
      assert {:ok, _output} = GitWorktree.prune(main)
      refute File.exists?(wt_path)
    end

    test "-z returns the same list", %{root: root, main: main} do
      wt_path = Path.join(root, "wt-z")
      assert {:ok, _} = GitWorktree.create(main, wt_path, branch: "symphony/T-Z")

      assert {:ok, plain} = GitWorktree.list(main)
      assert {:ok, nul} = GitWorktree.list(main, nul: true)

      assert Enum.map(plain, & &1.path) == Enum.map(nul, & &1.path)
      assert Enum.map(plain, & &1.branch) == Enum.map(nul, & &1.branch)
    end

    test "lock shows up in the list, and unlock takes it away", %{root: root, main: main} do
      wt_path = Path.join(root, "wt-lock")
      assert {:ok, _} = GitWorktree.create(main, wt_path, branch: "symphony/T-L")

      assert :ok = GitWorktree.lock(main, wt_path, reason: "long run")
      assert {:ok, [%{locked: "long run"}]} = GitWorktree.list(main) |> locked_only(wt_path)

      assert :ok = GitWorktree.unlock(main, wt_path)
      assert {:ok, [%{locked: nil}]} = GitWorktree.list(main) |> locked_only(wt_path)
    end

    test "create can lock and skip the checkout, the way `--lock --no-checkout` does",
         %{root: root, main: main} do
      wt_path = Path.join(root, "wt-nolock")

      assert {:ok, created} =
               GitWorktree.create(main, wt_path,
                 branch: "symphony/T-N",
                 lock: true,
                 lock_reason: "created locked",
                 checkout: false
               )

      assert created.locked == "created locked"
      # `--no-checkout` leaves the working tree empty; `f.txt` is in the commit but not on disk.
      refute File.exists?(Path.join(wt_path, "f.txt"))
    end

    test "move relocates it and the list agrees", %{root: root, main: main} do
      old_path = Path.join(root, "wt-old")
      new_path = Path.join(root, "wt-new")
      assert {:ok, _} = GitWorktree.create(main, old_path, branch: "symphony/T-M")

      assert {:ok, moved} = GitWorktree.move(main, old_path, new_path)
      assert same_path?(moved.path, new_path)
      assert moved.branch == "symphony/T-M"

      assert {:ok, worktrees} = GitWorktree.list(main)
      refute Enum.any?(worktrees, &same_path?(&1.path, old_path))
      assert Enum.any?(worktrees, &same_path?(&1.path, new_path))
    end

    test "repair is the way back from a plain mv of a worktree", %{root: root, main: main} do
      old_path = Path.join(root, "wt-mv")
      new_path = Path.join(root, "wt-mv-moved")
      assert {:ok, _} = GitWorktree.create(main, old_path, branch: "symphony/T-R")

      # The wrong way to move one. Measured: the moved worktree itself still works -- its own `.git`
      # file points at the administrative directory, which has not moved. What goes stale is the
      # *main checkout's* record of where the worktree lives, so the list keeps reporting the old
      # path and `prune` would drop the entry as if the checkout were gone.
      File.rename!(old_path, new_path)
      assert GitWorktree.inside_work_tree?(new_path)

      assert {:ok, stale} = GitWorktree.list(main)
      assert Enum.any?(stale, &same_path?(&1.path, old_path))
      refute Enum.any?(stale, &same_path?(&1.path, new_path))

      # `repair` takes the new path and re-links the record.
      assert :ok = GitWorktree.repair(main, [new_path])

      assert {:ok, repaired} = GitWorktree.list(main)
      assert Enum.any?(repaired, &same_path?(&1.path, new_path))
      refute Enum.any?(repaired, &same_path?(&1.path, old_path))
    end

    test "prune --dry-run answers without removing, and the real prune removes",
         %{root: root, main: main} do
      wt_path = Path.join(root, "wt-gone")
      assert {:ok, _} = GitWorktree.create(main, wt_path, branch: "symphony/T-P")

      # Delete the checkout behind git's back: the administrative entry becomes prunable.
      File.rm_rf!(wt_path)

      assert {:ok, output} = GitWorktree.prune(main, dry_run: true)
      assert output != ""
      # Dry run means dry: the entry is still in the list.
      assert {:ok, worktrees} = GitWorktree.list(main)
      assert Enum.any?(worktrees, &same_path?(&1.path, wt_path))

      assert {:ok, _} = GitWorktree.prune(main)
      assert {:ok, after_prune} = GitWorktree.list(main)
      refute Enum.any?(after_prune, &same_path?(&1.path, wt_path))
    end

    test "creating over an existing branch reports git's own refusal, untranslated",
         %{root: root, main: main} do
      wt_a = Path.join(root, "wt-a")
      wt_b = Path.join(root, "wt-b")

      assert {:ok, _} = GitWorktree.create(main, wt_a, branch: "symphony/T-2")

      assert {:error, {:git_exit, status, output}} =
               GitWorktree.create(main, wt_b, branch: "symphony/T-2")

      assert status != 0
      assert output =~ "T-2"
    end

    test "removing a dirty worktree is refused unless :force is given", %{root: root, main: main} do
      wt_path = Path.join(root, "wt-dirty")
      assert {:ok, _} = GitWorktree.create(main, wt_path, branch: "symphony/T-3")

      File.write!(Path.join(wt_path, "f.txt"), "modified\n")

      assert {:error, {:git_exit, _status, _output}} = GitWorktree.remove(main, wt_path)
      assert :ok = GitWorktree.remove(main, wt_path, force: true)
    end

    defp same_path?(left, right) do
      normalize = fn path -> path |> String.replace("\\", "/") |> String.trim_trailing("/") end
      normalize.(left) == normalize.(right)
    end

    # Keeps just the entry for one path, so an assertion about `locked` cannot accidentally pass by
    # matching the main checkout.
    defp locked_only({:ok, worktrees}, path) do
      {:ok, Enum.filter(worktrees, &same_path?(&1.path, path))}
    end
  end
end
