defmodule SymphonyElixir.Janitor.PublishNowTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema.Project
  alias SymphonyElixir.Janitor
  alias SymphonyElixir.Shell

  # `publish_now/2` is the host-side half the agent tool calls. Most of these tests stay on the paths
  # that refuse *before* anything is created or pushed: an identifier that could climb out of the two
  # configured roots, a ticket that does not exist, a workspace that is not a git work tree.
  #
  # The publish tests below (`describe "publish: direct"`) do push, because that is the only way to
  # tell the two publish modes apart: what separates them is *where the commit lands*. They push into
  # a scratch repository built in the temp directory whose `origin` is a bare repo on this disk --
  # no network, and `gh` is replaced by a sentinel that is loud when it is used, so "no pull request"
  # is observed rather than inferred from a missing link.

  defp tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "symphony-publish-now-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  test "refuses an identifier that is not a plain ticket name" do
    # The identifier is a path segment under both roots, and the caller is a language model.
    for id <- ["../escape", "a/b", "..", ".", "/absolute", "C:/absolute", "with space", ""] do
      assert {:error, {:invalid_ticket_id, ^id}} = Janitor.publish_now(id)
    end
  end

  test "refuses a ticket that has no file" do
    dir = tmp_dir()

    assert {:error, {:no_such_ticket, "SYM-1"}} =
             Janitor.publish_now("SYM-1", tickets: dir, workspace_root: dir)
  end

  test "refuses when there is no workspace to publish" do
    dir = tmp_dir()
    File.write!(Path.join(dir, "SYM-1.md"), "---\nid: SYM-1\nstate: in-review\n---\nbody\n")

    assert {:error, {:not_a_workspace, workspace}} =
             Janitor.publish_now("SYM-1", tickets: dir, workspace_root: dir)

    assert workspace == Path.join(dir, "SYM-1")
  end

  test "the settings mapping is the one the server and the tool share" do
    settings = %{
      tickets_path: "/tickets",
      workspace_root: "/workspaces",
      issues_repo: "me/repo",
      tickets_repo: "me/tickets",
      state_file: "/state.json",
      interval_ms: 45_000
    }

    assert Janitor.options_from_settings(settings) == [
             tickets: "/tickets",
             workspace_root: "/workspaces",
             repo: "me/repo",
             tickets_repo: "me/tickets",
             state_file: "/state.json",
             interval_seconds: 45
           ]

    # A workflow that sets nothing must not produce empty options: `config/1` fills those with this
    # machine's defaults, so an empty string here would be a wrong path rather than an absent one.
    assert Janitor.options_from_settings(%{}) == []
  end

  test "an undeclared repository is not guessed" do
    # The two paths have defaults because they are this machine's own directories. A repository does
    # not: it is a name somebody else owns, so "not declared" has to mean "do not guess" rather than
    # reaching for a built-in one -- which is what an undeclared deployment used to mirror into and
    # open pull requests against.
    config = Janitor.config([])

    assert config.repo == nil
    assert config.tickets_repo == nil
    assert is_binary(config.tickets)
    assert is_binary(config.workspace_root)
  end

  test "a ticket link is dropped, not invented, when no tickets repository is declared" do
    config = Janitor.config(tickets_repo: nil)

    assert Janitor.ticket_url("SYM-1", config) == nil
    assert Janitor.ticket_url("SYM-1", %{config | tickets_repo: "me/tickets"}) =~ "me/tickets/blob/master/SYM-1.md"
  end

  test "publishing one ticket fails closed when no issues repository is declared" do
    # Without the guard this reaches `gh pr list --repo nil`, which is how a guess becomes a call
    # against a repository nobody named.
    dir = tmp_dir()
    File.write!(Path.join(dir, "SYM-1.md"), "---\nid: SYM-1\nstate: in-review\n---\nbody\n")

    workspace = Path.join(dir, "SYM-1")
    File.mkdir_p!(workspace)
    {_, 0} = System.cmd("git", ["init", "-q", workspace])

    assert {:error, :no_issues_repo} =
             Janitor.publish_now("SYM-1", tickets: dir, workspace_root: dir, tickets_repo: "me/tickets")
  end

  # ── the two publish modes ─────────────────────────────────────────────────────

  describe "publish: direct" do
    test "commits on the project's own branch, pushes it, and never asks gh about a pull request" do
      repo = scratch_repo()

      # The ticket names a branch from an earlier `pull_request` round. Under `direct` that branch is
      # one this mode never creates, so the ticket has to be corrected rather than left pointing at
      # it. No `repo:` is passed: `direct` calls no `gh`, so it needs no issues repository.
      ticket = write_ticket!(repo, "branch_name: symphony/SYM-1")
      File.write!(Path.join(repo.workspace, "work.txt"), "work\n")

      with_mined_gh(fn ->
        assert_gh_is_a_mine()

        {result, log} =
          with_log(fn -> Janitor.publish_now("SYM-1", janitor_opts(repo, publish: "direct")) end)

        assert {:ok, published} = result

        assert published == %{
                 branch: "main",
                 committed: true,
                 moved_to_branch: false,
                 pushed: true,
                 pull_request: nil
               }

        # The commit is on the project's own branch...
        assert head_subject(repo.origin, "main") == "symphony/SYM-1: automated change (direct)"
        # ...and the branch the pull-request path would have created is not on the remote at all.
        assert remote_branches(repo.origin) == ["main"]

        # No `gh` was reached, and the sentinel here is a *mine*: the assertion above that it raises
        # when it is run is what makes surviving this call mean something. `has_pull_request?/2` fails
        # quietly, so a log-based check would not have noticed it at all.
        refute log =~ "cannot list pull requests"
      end)

      text = File.read!(ticket)
      assert text =~ "branch_name: main"
      refute text =~ "symphony/SYM-1"
      # The ticket records where the work went -- a branch -- and carries no pull-request link.
      refute text =~ "links:"
      refute text =~ "/pull/"
    end

    test "pull_request is unchanged: it pushes a ticket branch and asks gh" do
      repo = scratch_repo()
      ticket = write_ticket!(repo, nil)
      File.write!(Path.join(repo.workspace, "work.txt"), "work\n")

      with_sentinel_gh(fn ->
        {result, log} =
          with_log(fn ->
            Janitor.publish_now("SYM-1", janitor_opts(repo, publish: "pull_request", repo: "me/repo"))
          end)

        assert {:ok, published} = result
        assert published.branch == "symphony/SYM-1"
        assert published.committed
        assert published.pushed
        # The sentinel answered something that is not a pull request, and a `gh` failure is not
        # treated as "there is one": no link is invented.
        assert published.pull_request == nil

        # The ticket's own branch is on the remote and the project's own branch was not touched.
        assert remote_branches(repo.origin) == ["main", "symphony/SYM-1"]
        assert head_subject(repo.origin, "main") == "seed"
        # The positive control for the `refute` above: with this same sentinel on `PATH`, the
        # pull-request path does reach `gh` and says so.
        assert log =~ "cannot list pull requests for symphony/SYM-1"
      end)

      text = File.read!(ticket)
      assert text =~ "branch_name: symphony/SYM-1"
      refute text =~ "links:"
    end

    test "a project that says nothing publishes pull_request" do
      # The default has to reproduce today's behaviour exactly, and every workflow that exists today
      # says nothing: the test support's workflow file has no `project:` block at all.
      assert Config.settings!().project.publish == "pull_request"

      assert {:ok, parsed} = Config.Schema.parse(%{})
      assert parsed.project.publish == "pull_request"

      assert Janitor.config([]).publish == "pull_request"

      # `direct` is the opt-in, and it is the only other value.
      assert Project.publishes() == ["pull_request", "direct"]

      assert {:ok, settings} = Config.Schema.parse(%{"project" => %{"publish" => "direct"}})
      assert settings.project.publish == "direct"

      assert {:error, {:invalid_workflow_config, message}} =
               Config.Schema.parse(%{"project" => %{"publish" => "directly"}})

      assert message =~ "project.publish"

      assert Janitor.config(publish: "direct").publish == "direct"
    end

    test "a trunk that has moved on is reported, never force-pushed" do
      repo = scratch_repo()
      ticket = write_ticket!(repo, nil)
      advance_origin(repo)
      File.write!(Path.join(repo.workspace, "work.txt"), "work\n")

      with_mined_gh(fn ->
        assert_gh_is_a_mine()

        {result, log} =
          with_log(fn -> Janitor.publish_now("SYM-1", janitor_opts(repo, publish: "direct")) end)

        assert {:ok, %{pushed: false, committed: true, pull_request: nil}} = result

        # Somebody else's commit is still the trunk: a rejected push is not a rewritten remote.
        assert head_subject(repo.origin, "main") == "someone else"
        # The refusal is on the record, in the janitor's own words.
        assert log =~ "direct push to main exited"
      end)

      # And nothing was thrown away by the refusal -- the commit is still in the workspace, it just
      # did not land.
      assert head_subject(repo.workspace, "main") == "symphony/SYM-1: automated change (direct)"
      assert File.read!(ticket) =~ "branch_name: main"
    end
  end

  # ── a scratch repository with a real remote ───────────────────────────────────

  # The workspace is a clone of the project's repository, which is what `janitor.workspace_root`
  # holds in a `per_ticket` deployment: one directory per ticket, named after the ticket. `origin` is
  # a bare repo on this disk, so a push here is a real push to a real remote -- with no network in
  # the test.
  defp scratch_repo do
    root = tmp_dir()
    origin = Path.join(root, "origin.git")
    seed = Path.join(root, "seed")
    workspaces = Path.join(root, "workspaces")
    workspace = Path.join(workspaces, "SYM-1")

    File.mkdir_p!(workspaces)
    git!(["init", "--bare", "-q", "-b", "main", origin], root)
    git!(["init", "-q", "-b", "main", seed], root)
    File.write!(Path.join(seed, "README.md"), "# seed\n")
    git!(["-c", "user.name=seed", "-c", "user.email=seed@local", "add", "-A"], seed)
    git!(["-c", "user.name=seed", "-c", "user.email=seed@local", "commit", "-q", "-m", "seed"], seed)
    git!(["remote", "add", "origin", origin], seed)
    git!(["push", "-q", "-u", "origin", "main"], seed)
    git!(["clone", "-q", origin, workspace], root)

    %{
      root: root,
      origin: origin,
      seed: seed,
      workspaces: workspaces,
      workspace: workspace,
      tickets: Path.join(root, "tickets")
    }
  end

  defp write_ticket!(repo, extra_line) do
    File.mkdir_p!(repo.tickets)
    path = Path.join(repo.tickets, "SYM-1.md")

    File.write!(
      path,
      ["---", "id: SYM-1", "state: in-review", extra_line, "---", "", "body", ""]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
    )

    path
  end

  # `repo:` (the issues repository) is deliberately absent unless a test passes one: `direct` never
  # calls `gh`, so a deployment with no issues repository declared publishes with it.
  defp janitor_opts(repo, extra) do
    Keyword.merge([tickets: repo.tickets, workspace_root: repo.workspaces, tickets_repo: "me/tickets"], extra)
  end

  # The trunk moves on under the workspace's feet, the way it does when somebody else pushes.
  defp advance_origin(repo) do
    File.write!(Path.join(repo.seed, "README.md"), "# seed\n\nsomebody else got there first\n")
    git!(["add", "-A"], repo.seed)
    git!(["-c", "user.name=seed", "-c", "user.email=seed@local", "commit", "-q", "-m", "someone else"], repo.seed)
    git!(["push", "-q", "origin", "main"], repo.seed)
  end

  defp git!(args, cd) do
    {output, status} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)

    if status != 0 do
      flunk("git #{Enum.join(args, " ")} failed with #{status} in #{cd}:\n#{output}")
    end

    String.trim(output)
  end

  defp remote_branches(origin) do
    ["branch", "--list", "--format=%(refname:short)"]
    |> git!(origin)
    |> String.split("\n", trim: true)
  end

  defp head_subject(repo, branch), do: git!(["log", "-1", "--format=%s", branch], repo)

  # ── the injected gh ───────────────────────────────────────────────────────────

  # `Janitor` runs `gh` through `Shell.run/3`, which resolves the name with `System.find_executable/1`
  # -- so a directory in front of `PATH` is the seam, the same one the mix-task tests use.
  #
  # Two shapes of stand-in, because the interesting question is different in each place:
  #
  #   * `with_mined_gh/1` puts a `gh` that *resolves but cannot be spawned* on `PATH`. Any code path
  #     that runs `gh` at all raises there, so "the direct path never invokes gh" is observed directly
  #     rather than inferred -- which matters, because `has_pull_request?/2` fails quietly and would
  #     not show up in a log assertion at all. On Windows that is a `.cmd`, which `Port.open/2` cannot
  #     spawn (measured: `:eacces`); on POSIX a 0755 file whose interpreter does not exist.
  #   * `with_sentinel_gh/1` puts a `gh` that runs and answers with something that is not the JSON
  #     `gh` was asked for, so a publish that expects to finish can still finish while being watched.
  defp with_mined_gh(fun) do
    with_gh_on_path(
      fn dir ->
        if Shell.windows?() do
          path = Path.join(dir, "gh.cmd")
          File.write!(path, "@echo off\r\nrem symphony test: resolves, cannot be spawned\r\n")
          path
        else
          path = Path.join(dir, "gh")
          File.write!(path, "#!/nonexistent/symphony-test-interpreter\n")
          File.chmod!(path, 0o755)
          path
        end
      end,
      fun
    )
  end

  # Spawning this one raises; that is the whole point of it. Asserted in the tests that use it, so the
  # assertions after it cannot pass for the wrong reason.
  defp assert_gh_is_a_mine do
    assert_raise ErlangError, fn -> Shell.run("gh", ["pr", "list"]) end
  end

  defp with_sentinel_gh(fun) do
    with_gh_on_path(
      fn dir ->
        if Shell.windows?() do
          # A copy of `where.exe`: the cheapest real executable Windows is guaranteed to have, and it
          # answers with file names rather than JSON.
          path = Path.join(dir, "gh.exe")
          File.cp!(System.find_executable("where"), path)
          path
        else
          path = Path.join(dir, "gh")
          File.write!(path, "#!/bin/sh\nexit 1\n")
          File.chmod!(path, 0o755)
          path
        end
      end,
      fun
    )
  end

  defp with_gh_on_path(write, fun) do
    dir = tmp_dir()
    previous = System.get_env("PATH") || ""
    separator = if Shell.windows?(), do: ";", else: ":"

    System.put_env("PATH", Enum.join([dir, previous], separator))

    try do
      gh = write.(dir)
      # If this is not the `gh` the code would find, every assertion about it is vacuous.
      assert same_path?(System.find_executable("gh"), gh)
      fun.()
    after
      System.put_env("PATH", previous)
    end
  end

  defp same_path?(left, right) when is_binary(left) and is_binary(right) do
    normalize = fn path -> path |> Path.expand() |> String.replace("\\", "/") |> String.downcase() end
    normalize.(left) == normalize.(right)
  end

  defp same_path?(_left, _right), do: false
end
