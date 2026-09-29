defmodule SymphonyElixir.CodexGitMetadataTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitWorktree
  alias SymphonyElixir.Workflow

  # Codex's workspace-write sandbox makes a checkout's git metadata read-only by path, so an agent can
  # edit every source file and still be unable to commit or branch -- measured in this deployment, and
  # tracked upstream as openai/codex#14338. `codex.git_metadata_writable` adds the workspace's
  # **resolved** git dir and common dir to the session's `writableRoots`, and "resolved" is the whole
  # point: a linked worktree keeps its metadata somewhere else entirely.

  setup do
    root = Path.join(System.tmp_dir!(), "codex-git-metadata-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  defp init_repo(path) do
    File.mkdir_p!(path)
    {_, 0} = System.cmd("git", ["init", "-q", path], stderr_to_stdout: true)
    path
  end

  defp commit_allow_empty(repo) do
    {_, 0} =
      System.cmd(
        "git",
        ["-C", repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"],
        stderr_to_stdout: true
      )
  end

  defp pin_policy(extra) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          codex_turn_sandbox_policy: %{
            "type" => "workspaceWrite",
            "writableRoots" => ["C:/pinned/root"]
          }
        ],
        extra
      )
    )
  end

  describe "GitWorktree.metadata_paths/1" do
    test "a plain clone reports one metadata directory", %{root: root} do
      repo = init_repo(Path.join(root, "clone"))

      assert {:ok, [metadata]} = GitWorktree.metadata_paths(repo)
      assert Path.basename(metadata) == ".git"
      assert metadata == Path.join(repo, ".git")
    end

    test "the path's own spelling survives, because a sandbox entry is matched as text",
         %{root: root} do
      # The bug this pins: codex matches a policy entry against the path it derives from the session's
      # cwd by string comparison, and `Path.expand/2` lower-cases a Windows drive letter. `c:/...` is not
      # `C:/...`, so the entry stopped suppressing the metadata carveout, and the same `.git` came out
      # both writable and read-only -- with read-only winning. Measured on SYM-54.
      repo = init_repo(Path.join(root, "case"))

      assert {:ok, [metadata]} = GitWorktree.metadata_paths(repo)
      assert metadata == Path.join(repo, ".git")
      # Same string the caller passed, character for character -- that is what makes it match.
      assert String.starts_with?(metadata, repo)
    end

    test "a linked worktree reports its own git dir and the shared common dir", %{root: root} do
      main = init_repo(Path.join(root, "main"))
      commit_allow_empty(main)
      worktree = Path.join(root, "wt")

      {_, 0} =
        System.cmd("git", ["-C", main, "worktree", "add", "-q", worktree, "-b", "probe"],
          stderr_to_stdout: true
        )

      assert {:ok, paths} = GitWorktree.metadata_paths(worktree)
      # The checkout's own `.git` (a file here), its git dir, and the shared common dir.
      assert length(paths) == 3

      # In a worktree `.git` is a file, and the metadata that has to be writable lives outside it.
      refute File.dir?(Path.join(worktree, ".git"))
      assert Path.join(worktree, ".git") in paths
      assert Enum.any?(paths, &String.contains?(&1, "worktrees"))
      # Same directory, possibly a different spelling: git prints its own separators and drive case.
      assert Enum.any?(paths, &(plain(&1) == plain(Path.join(main, ".git"))))
    end

    defp plain(value) do
      value |> String.replace("\\", "/") |> String.downcase() |> String.trim_trailing("/")
    end

    test "a path that is not a work tree is an error, never an empty list", %{root: root} do
      plain = Path.join(root, "plain")
      File.mkdir_p!(plain)

      assert {:error, :not_a_work_tree} = GitWorktree.metadata_paths(plain)
    end
  end

  describe "codex.git_metadata_writable" do
    test "off by default: the pinned policy comes back untouched", %{root: root} do
      repo = init_repo(Path.join(root, "repo"))
      pin_policy([])

      assert Config.codex_turn_sandbox_policy(repo)["writableRoots"] == ["C:/pinned/root"]
    end

    test "on: the workspace's git metadata joins writableRoots, keeping what was pinned",
         %{root: root} do
      repo = init_repo(Path.join(root, "repo"))
      pin_policy(codex_git_metadata_writable: true)

      roots = Config.codex_turn_sandbox_policy(repo)["writableRoots"]

      assert "C:/pinned/root" in roots
      assert Path.join(repo, ".git") in roots
    end

    test "on, but the workspace is not a work tree: the policy is left alone", %{root: root} do
      plain = Path.join(root, "plain")
      File.mkdir_p!(plain)
      pin_policy(codex_git_metadata_writable: true)

      assert Config.codex_turn_sandbox_policy(plain)["writableRoots"] == ["C:/pinned/root"]
    end

    test "on, but the policy is not workspaceWrite: nothing is added", %{root: root} do
      repo = init_repo(Path.join(root, "repo"))

      write_workflow_file!(Workflow.workflow_file_path(),
        codex_git_metadata_writable: true,
        codex_turn_sandbox_policy: %{"type" => "dangerFullAccess"}
      )

      refute Map.has_key?(Config.codex_turn_sandbox_policy(repo), "writableRoots")
    end
  end
end
