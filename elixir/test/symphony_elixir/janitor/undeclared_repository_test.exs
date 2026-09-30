defmodule SymphonyElixir.Janitor.UndeclaredRepositoryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Janitor

  # The janitor's defaults are this machine's *paths*, and those stay: a tickets directory, a
  # workspace root, a state file. A repository is a different kind of thing -- a name somebody else
  # owns -- so `Janitor.config/1` supplies none, and every round has to decide what to do with a
  # repository it was never given. These tests pin that decision: the two `gh`-shaped steps skip and
  # say why, and everything that only needs the local paths still happens.
  #
  # The alternative -- reaching for a built-in name -- is not hypothetical: it is what an undeclared
  # deployment did until the default was removed, mirroring into, linking to and opening pull
  # requests against a repository it never named.

  defp tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "symphony-janitor-undeclared-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    # A repository of its own, so this round's `git add -A` can only ever touch a scratch directory.
    # Without it, a temp directory that happened to sit under some other checkout would have the
    # whole of that checkout staged and committed.
    {_, 0} = System.cmd("git", ["init", "-q", dir])
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  test "a round with no issues repository skips both gh-shaped steps, and names the reason" do
    dir = tmp_dir()

    log =
      capture_log(fn ->
        assert :ok = Janitor.run_once(tickets: dir, workspace_root: dir)
      end)

    # Named separately: "nothing happened" is the failure mode this whole system fears, so a skip
    # has to be legible in the log rather than silent.
    assert log =~ "no issues repository declared (janitor.issues_repo)"
    assert log =~ "skipping receive and mirror"
    assert log =~ "skipping the publish sweep"
  end

  test "the local half of a round still runs, and no repository is guessed into the board" do
    dir = tmp_dir()

    capture_log(fn ->
      assert :ok = Janitor.run_once(tickets: dir, workspace_root: dir)
    end)

    # The boards need the tickets directory, not a repository. Someone who never opens GitHub still
    # gets a page that says what is queued...
    readme = File.read!(Path.join(dir, "README.md"))
    assert File.exists?(Path.join(dir, "BOARD-ready.md"))
    assert readme =~ "fill-in-the-blank form"

    # ...and that page does not point at a repository nobody named. Before the default was removed
    # the issues repository was always present here, so this line was unreachable; now it is the
    # difference between a note and `https://github.com//issues` committed into the ticket repo.
    refute readme =~ "github.com"
  end
end
