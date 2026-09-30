defmodule SymphonyElixir.SettingsTest do
  # async: false -- the write path goes through `Workflow.set_workflow_file_path/1`, which is
  # application-global (and makes the running WorkflowStore reload).
  use ExUnit.Case, async: false

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{Settings, Workflow}

  @workflow """
  ---
  tracker:
    kind: file
    provider:
      path: C:/Users/lhl20/code/symphony-tickets
    active_states:
      - ready
  janitor:
    enabled: true
    interval_ms: 30000
    issues_repo: owner/example
  agent:
    max_concurrent_agents: 1
    max_turns: 5
  ---

  Prompt body.
  """

  setup do
    path = Path.join(System.tmp_dir!(), "settings-#{System.unique_integer([:positive])}.md")
    File.write!(path, @workflow)

    # The app env, NOT `Workflow.set_workflow_file_path/1`: that one also tells the running
    # `WorkflowStore` to reload, and restoring it afterwards can leave the store holding *this* file
    # -- `WORKFLOW.md` in the test environment is a github tracker with no token, so the reload back
    # to it fails and the store keeps the last good configuration, which would then be a temp file
    # that no longer exists. Measured: it showed up as an unrelated workspace test failing only in
    # the full run.
    Application.put_env(:symphony_elixir, :workflow_file_path, path)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :workflow_file_path)
      File.rm(path)
      File.rm(path <> ".bak")
    end)

    {:ok, path: path}
  end

  describe "effective/0" do
    test "reports the running configuration, grouped for display" do
      assert {:ok, sections} = Settings.effective()

      titles = Enum.map(sections, & &1.title)
      assert "GitHub" in titles
      assert "janitor" in titles
      assert "agent" in titles
      assert "acp / codex" in titles

      github = Enum.find(sections, &(&1.title == "GitHub"))
      assert {"issues 仓库", _} = Enum.find(github.rows, fn {key, _} -> key == "issues 仓库" end)
    end

    test "every row is a two-tuple, so the page never has to know the schema's shape" do
      {:ok, sections} = Settings.effective()

      for section <- sections, row <- section.rows do
        assert {key, _value} = row
        assert is_binary(key)
      end
    end
  end

  describe "site/0 (the repositories this instance reads)" do
    test "an undeclared repository is reported as undeclared, never guessed" do
      # A repository name is somebody else's, so nothing in this system may invent one. A workflow
      # that declares none must report none -- the page then says "未声明" rather than naming a
      # repository the deployment never mentioned.
      write_workflow_without_repositories!()

      site = Settings.site()

      assert site.issues_repo == nil
      assert site.issues_url == nil
      assert site.tickets_repo == nil
      assert site.tickets_url == nil
      refute site.code.matches_issues_repo?
    end
  end

  describe "credentials/0" do
    test "reports presence and never a value" do
      credentials = Settings.credentials()

      refute credentials == []
      assert Enum.any?(credentials, &(&1.name == "CMD_API_KEY"))
      assert Enum.any?(credentials, &(&1.name == "CODEBUDDY_AUTH_TOKEN"))

      for credential <- credentials do
        assert Map.has_key?(credential, :process?)
        assert Map.has_key?(credential, :user_scope?)
        assert Map.has_key?(credential, :length)
        # The whole point: no field carries the secret, not even a masked one.
        refute Map.has_key?(credential, :value)
      end
    end

    test "length is a count, never the value itself" do
      for credential <- Settings.credentials() do
        case credential.length do
          nil -> :ok
          length -> assert is_integer(length) and length >= 0
        end
      end
    end
  end

  describe "update/2" do
    test "writes a valid value, and keeps the original beside it" do
      assert {:ok, path, _written} = Settings.update(["janitor", "issues_repo"], "owner/other")

      assert File.read!(path) =~ "issues_repo: owner/other"
      assert File.read!(path <> ".bak") =~ "issues_repo: owner/example"
    end

    test "refuses a value the schema rejects, and does NOT touch the file" do
      before = File.read!(effective_path())

      # `interval_ms` must be greater than zero; zero is the smallest thing a person is likely to
      # type by accident, and it is exactly what this guard exists for.
      assert {:error, _reason} = Settings.update(["janitor", "interval_ms"], "0")

      assert File.read!(effective_path()) == before
      refute File.exists?(effective_path() <> ".bak")
    end

    test "refuses a non-integer for an integer key" do
      assert {:error, {:not_an_integer, "soon"}} = Settings.update(["janitor", "interval_ms"], "soon")
    end

    test "refuses a non-boolean for a boolean key" do
      assert {:error, {:not_a_boolean, "maybe"}} = Settings.update(["janitor", "enabled"], "maybe")
      assert {:ok, _path, _written} = Settings.update(["janitor", "enabled"], "false")
    end

    test "refuses a key outside the curated list" do
      assert {:error, {:not_editable, ["tracker", "kind"]}} =
               Settings.update(["tracker", "kind"], "github")
    end

    test "refuses to write a section as a scalar" do
      assert {:error, _reason} = Settings.update(["janitor"], "oops")
    end
  end

  describe "linked paths (the same thing declared twice)" do
    test "linked_paths/1 returns both halves whichever half you name, and just the key otherwise" do
      pair = [["tracker", "provider", "path"], ["janitor", "tickets_path"]]

      assert Settings.linked_paths(["tracker", "provider", "path"]) == pair
      assert Settings.linked_paths(["janitor", "tickets_path"]) == pair
      assert Settings.linked_paths(["janitor", "issues_repo"]) == [["janitor", "issues_repo"]]
    end

    # Asserted through the real parser rather than the raw text: what matters is that both keys
    # *carry* the value once the workflow is loaded, not how the YAML happened to be quoted.
    test "saving the mirror half also writes the queue half" do
      queue = existing_dir!("new-queue")

      assert {:ok, path, written} = Settings.update(["janitor", "tickets_path"], queue)

      assert written == [["tracker", "provider", "path"], ["janitor", "tickets_path"]]

      settings = effective!(path)
      assert settings.janitor.tickets_path == queue
      assert settings.tracker.provider["path"] == queue
    end

    test "saving the queue half also writes the mirror half" do
      queue = existing_dir!("q2")

      assert {:ok, path, written} = Settings.update(["tracker", "provider", "path"], queue)

      assert written == [["tracker", "provider", "path"], ["janitor", "tickets_path"]]

      settings = effective!(path)
      assert settings.tracker.provider["path"] == queue
      assert settings.janitor.tickets_path == queue
    end

    test "the workspace pair is linked too" do
      root = existing_dir!("new-ws")

      assert {:ok, path, written} = Settings.update(["workspace", "root"], root)

      assert written == [["workspace", "root"], ["janitor", "workspace_root"]]

      settings = effective!(path)
      assert settings.workspace.root == root
      assert settings.janitor.workspace_root == root
    end

    test "an unlinked key writes only itself" do
      assert {:ok, _path, written} = Settings.update(["janitor", "issues_repo"], "o/r")
      assert written == [["janitor", "issues_repo"]]
    end

    test "a queue directory that does not exist is refused, and nothing is written" do
      # The file tracker would have nothing to poll, so this is a real mistake rather than a
      # preference -- and the page has to say so, not just fail.
      missing = Path.join(System.tmp_dir!(), "definitely-not-here-#{System.unique_integer([:positive])}")

      assert {:error, {:file_tracker_path_not_found, _path}} =
               Settings.update(["janitor", "tickets_path"], missing)
    end
  end

  describe "project.publish (how finished work lands)" do
    test "is in the curated list, offered as the modes the schema accepts" do
      entry = Enum.find(Settings.editable(), &(&1.path == ["project", "publish"]))

      assert entry, "project.publish must be editable, or the mode can only be changed by hand"
      assert entry.type == :enum
      assert entry.options == Schema.Project.publishes()
      assert entry.value in Schema.Project.publishes()
    end

    test "changing it rewrites the mode in place and leaves the rest of the file alone" do
      queue = existing_dir!("publish-queue")
      write_workflow_with_publish!(queue, "pull_request")
      before = File.read!(effective_path())

      assert {:ok, path, written} = Settings.update(["project", "publish"], "direct")

      assert written == [["project", "publish"]]

      text = File.read!(path)
      assert text =~ "publish: direct"
      refute text =~ "publish: pull_request"
      # In place: the block is not duplicated, and everything around the one replaced line is
      # untouched -- the comment above it, the other sections, the prompt body.
      assert length(String.split(text, "project:")) == 2
      assert text =~ "# pull_request pushes a branch and opens a pull request"
      assert text =~ "issues_repo: owner/example"
      assert text =~ "Prompt body."
      assert replace_mode(text) == replace_mode(before)
      assert effective!(path).project.publish == "direct"
    end

    test "a workflow with no project: block gains one, which is what the deployment's file needs" do
      # The fixture in `setup/0` has no `project:` block, and neither does the workflow this machine
      # runs: the schema's default applies there, so nothing has to be written into it.
      refute File.read!(effective_path()) =~ "project:"

      assert {:ok, path, _written} = Settings.update(["project", "publish"], "direct")

      text = File.read!(path)
      assert text =~ "project:\n  publish: direct"
      # Added inside the front matter, not after the body.
      assert [_, front, _] = String.split(text, "---", parts: 3)
      assert front =~ "publish: direct"
      assert effective!(path).project.publish == "direct"
    end

    test "refuses a value that is not one of the two, and does NOT touch the file" do
      before = File.read!(effective_path())

      assert {:error, {:not_one_of, "merge", ["pull_request", "direct"]}} =
               Settings.update(["project", "publish"], "merge")

      assert File.read!(effective_path()) == before
      refute File.exists?(effective_path() <> ".bak")
    end
  end

  # A workflow that already carries the mode, written the way the create form writes it -- the
  # comment included. The choice is made once, in the file, and changed afterwards from here.
  defp write_workflow_with_publish!(queue, mode) do
    File.write!(effective_path(), """
    ---
    tracker:
      kind: file
      provider:
        path: #{queue}
      active_states:
        - ready
    project:
      # pull_request pushes a branch and opens a pull request; direct commits and pushes the
      # project's own main branch, with no pull request.
      publish: #{mode}
    janitor:
      enabled: true
      interval_ms: 30000
      issues_repo: owner/example
    agent:
      max_concurrent_agents: 1
      max_turns: 5
    ---

    Prompt body.
    """)
  end

  defp replace_mode(text), do: String.replace(text, ~r/^(\s*)publish:.*$/m, "\\1publish: <mode>")

  # A workflow with no `janitor` block at all, which is what a deployment that has not named its
  # repositories looks like.
  defp write_workflow_without_repositories! do
    File.write!(effective_path(), """
    ---
    tracker:
      kind: memory
    ---

    Prompt body.
    """)
  end

  defp existing_dir!(name) do
    dir =
      Path.join(System.tmp_dir!(), "settings-#{name}-#{System.unique_integer([:positive])}")
      |> Path.expand()

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # The same load-then-parse pair `Settings.validate/1` uses, so the test asserts on what the system
  # would actually run with rather than on how the YAML happened to be quoted.
  defp effective!(workflow_path) do
    {:ok, loaded} = Workflow.load(workflow_path)
    {:ok, settings} = Schema.parse(loaded.config)
    settings
  end

  describe "loopback_peer?/1 (the whole guard on the write path)" do
    test "accepts loopback, both families" do
      assert Settings.loopback_peer?(%{address: {127, 0, 0, 1}})
      assert Settings.loopback_peer?(%{address: {127, 9, 9, 9}})
      assert Settings.loopback_peer?(%{address: {0, 0, 0, 0, 0, 0, 0, 1}})
    end

    test "refuses anything else -- a LAN address, a tailnet address, a malformed peer" do
      refute Settings.loopback_peer?(%{address: {192, 168, 1, 5}})
      refute Settings.loopback_peer?(%{address: {100, 64, 0, 1}})
      refute Settings.loopback_peer?(%{address: {10, 0, 0, 7}})
      refute Settings.loopback_peer?(%{address: {0, 0, 0, 0}})
      refute Settings.loopback_peer?(nil)
      refute Settings.loopback_peer?(%{})
    end
  end

  defp effective_path, do: Workflow.workflow_file_path()
end
