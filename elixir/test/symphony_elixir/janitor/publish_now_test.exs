defmodule SymphonyElixir.Janitor.PublishNowTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Janitor

  # `publish_now/2` is the host-side half the agent tool calls. These tests stay on the paths that
  # refuse *before* anything is created or pushed: an identifier that could climb out of the two
  # configured roots, a ticket that does not exist, a workspace that is not a git work tree. The
  # publish itself needs a remote, and a unit test that pushes to one would be worse than no test.

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
end
