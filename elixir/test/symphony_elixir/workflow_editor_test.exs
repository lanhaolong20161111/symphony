defmodule SymphonyElixir.WorkflowEditorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.WorkflowEditor

  # Mirrors the real `WORKFLOW.file*.md`: comments above settings, two levels of nesting, a list,
  # and a prompt body. The comments are the point of this module, so the fixture has them.
  @workflow """
  ---
  # File tracker (tickets = markdown files). Front matter MUST stay ASCII.
  tracker:
    kind: file
    provider:
      # The queue: one .md per ticket.
      path: C:/Users/lhl20/code/symphony-tickets
    active_states:
      - ready
      - in-progress
  janitor:
    # Host-side caretaker, supervised by this application.
    enabled: true
    interval_ms: 30000
    tickets_path: C:/Users/lhl20/code/symphony-tickets
    issues_repo: owner/example
  agent:
    # One ticket on the first run: keep it small.
    max_concurrent_agents: 1
    max_turns: 5
  acp:
    adapter: workbuddy
    model: auto
  ---

  You are working on ticket `{{ issue.identifier }}`.
  """

  defp put!(text, path, value) do
    {:ok, updated} = WorkflowEditor.put_scalar(text, path, value)
    updated
  end

  # The assertion that matters: the edited text is still a workflow the real parser accepts, and
  # the schema reports the value we set. Everything else here could pass while producing a file
  # that no longer loads.
  defp settings_from!(text) do
    path = Path.join(System.tmp_dir!(), "workflow-editor-#{System.unique_integer([:positive])}.md")
    File.write!(path, text)

    try do
      {:ok, loaded} = Workflow.load(path)
      {:ok, settings} = Schema.parse(loaded.config)
      settings
    after
      File.rm(path)
    end
  end

  describe "replacing an existing scalar" do
    test "changes only that value" do
      updated = put!(@workflow, ["janitor", "issues_repo"], "someone/else")

      assert updated =~ "issues_repo: someone/else"
      refute updated =~ "issues_repo: owner/example"
    end

    test "keeps every comment" do
      updated = put!(@workflow, ["janitor", "issues_repo"], "someone/else")

      assert updated =~ "# File tracker (tickets = markdown files). Front matter MUST stay ASCII."
      assert updated =~ "# The queue: one .md per ticket."
      assert updated =~ "# Host-side caretaker, supervised by this application."
      assert updated =~ "# One ticket on the first run: keep it small."
    end

    test "keeps the prompt body and the surrounding structure" do
      updated = put!(@workflow, ["agent", "max_turns"], 9)

      assert updated =~ "You are working on ticket `{{ issue.identifier }}`."
      assert updated =~ "    - ready\n    - in-progress"
      assert updated =~ "  adapter: workbuddy"
    end

    test "writes an integer unquoted and a string plainly" do
      updated = put!(@workflow, ["janitor", "interval_ms"], 60_000)
      assert updated =~ "interval_ms: 60000"
      refute updated =~ "interval_ms: \"60000\""
    end

    test "writes a boolean as a YAML boolean" do
      updated = put!(@workflow, ["janitor", "enabled"], false)
      assert updated =~ "enabled: false"
    end
  end

  describe "nested sections" do
    test "walks two levels down (tracker.provider.path)" do
      updated = put!(@workflow, ["tracker", "provider", "path"], "D:/tickets")

      assert updated =~ "    path: D:/tickets"
      refute updated =~ "C:/Users/lhl20/code/symphony-tickets\n  active_states"
      # The sibling list under `tracker` is untouched.
      assert updated =~ "  active_states:\n    - ready\n    - in-progress"
    end
  end

  describe "keys and sections that do not exist yet" do
    test "inserts a new key under its existing section" do
      updated = put!(@workflow, ["janitor", "workspace_root"], "C:/ws")

      assert updated =~ "workspace_root: C:/ws"
      # Inserted inside `janitor:` -- directly under its header, indented two spaces.
      assert updated =~ "janitor:\n  workspace_root: C:/ws\n"
      # And not at the end of the file, or outside the section.
      refute updated =~ "workspace_root: C:/ws\nagent:"
    end

    test "creates a missing section rather than refusing" do
      updated = put!(@workflow, ["server", "port"], 4001)

      assert updated =~ "server:"
      assert updated =~ "  port: 4001"
    end
  end

  describe "refusals" do
    test "will not turn a section into a scalar" do
      assert {:error, {:would_overwrite_section, "tracker"}} =
               WorkflowEditor.put_scalar(@workflow, ["tracker"], "oops")
    end

    test "will not touch a file without front matter" do
      assert {:error, :missing_front_matter} =
               WorkflowEditor.put_scalar("just prose\n", ["a"], "b")
    end

    test "rejects an empty path segment" do
      assert {:error, {:invalid_path, ["a", ""]}} =
               WorkflowEditor.put_scalar(@workflow, ["a", ""], "b")
    end
  end

  describe "quoting" do
    test "quotes a value that would otherwise break YAML" do
      updated = put!(@workflow, ["janitor", "issues_repo"], "owner/repo: with colon")

      assert updated =~ ~s(issues_repo: "owner/repo: with colon")
      # ...and the file still loads, which is the only reason the quoting exists.
      assert settings_from!(updated).janitor.issues_repo == "owner/repo: with colon"
    end

    test "quotes an empty value so it does not become a section" do
      updated = put!(@workflow, ["acp", "model"], "")
      assert updated =~ ~s(model: "")
    end
  end

  describe "the edited file is still a workflow the real parser accepts" do
    test "the schema sees the value that was written" do
      updated =
        @workflow
        |> put!(["janitor", "issues_repo"], "newowner/newrepo")
        |> put!(["janitor", "interval_ms"], 45_000)
        |> put!(["agent", "max_concurrent_agents"], 3)
        |> put!(["acp", "model"], "auto-2")

      settings = settings_from!(updated)

      assert settings.janitor.issues_repo == "newowner/newrepo"
      assert settings.janitor.interval_ms == 45_000
      assert settings.agent.max_concurrent_agents == 3
      assert settings.acp.model == "auto-2"
      # Untouched values are still what they were.
      assert settings.agent.max_turns == 5
      assert settings.tracker.kind == "file"
    end

    test "setting the same value twice is stable (no duplicated key)" do
      once = put!(@workflow, ["janitor", "issues_repo"], "owner/repo")
      twice = put!(once, ["janitor", "issues_repo"], "owner/repo")

      assert once == twice
      assert length(String.split(twice, "issues_repo:")) == 2
    end
  end
end
