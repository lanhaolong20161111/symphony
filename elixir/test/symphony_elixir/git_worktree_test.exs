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

  # A round trip against the real git, because the point of this module is what git actually says --
  # the porcelain format, the `.git`-is-a-file fact, and the branch that ends up checked out.
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

      # The main checkout is the other entry; `list` reports both, and stores nothing itself.
      assert Enum.any?(worktrees, &same_path?(&1.path, main))

      assert :ok = GitWorktree.remove(main, wt_path)
      assert :ok = GitWorktree.prune(main)
      refute File.exists?(wt_path)
    end

    defp same_path?(left, right) do
      normalize = fn path -> path |> String.replace("\\", "/") |> String.trim_trailing("/") end
      normalize.(left) == normalize.(right)
    end

    test "creating over an existing branch reports git's own refusal, untranslated",
         %{root: root, main: main} do
      wt_a = Path.join(root, "wt-a")
      wt_b = Path.join(root, "wt-b")

      assert {:ok, _} = GitWorktree.create(main, wt_a, branch: "symphony/T-2")

      # git refuses to check the same branch out twice; the message is git's, not ours.
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
  end
end
