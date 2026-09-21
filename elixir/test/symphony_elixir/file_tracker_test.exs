defmodule SymphonyElixir.FileTrackerTest do
  # async: true —— 适配器把 settings 当参数收（arity-2），测试不碰全局 app env / Config
  use ExUnit.Case, async: true

  alias SymphonyElixir.Tracker.File, as: FileTracker
  alias SymphonyElixir.Tracker.Issue

  setup do
    # 注意：实现的路径一律经过 Path.expand（Windows 上会小写盘符并统一分隔符），
    # 所以夹具与断言也走同一种形态，否则比较的是"路径写法"而不是行为。
    dir =
      Path.expand(Path.join(System.tmp_dir!(), "symphony-file-tracker-#{System.unique_integer([:positive])}"))

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, dir: dir}
  end

  defp settings(dir, overrides \\ %{}) do
    Map.merge(
      %{provider: %{"path" => dir}, active_states: ["open", "ready"], terminal_states: ["done"]},
      overrides
    )
  end

  defp write_ticket(dir, name, body) do
    path = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    path
  end

  defp markdown(front_matter, body) do
    "---\n" <> front_matter <> "\n---\n" <> body
  end

  describe "a directory of Markdown tickets" do
    test "front matter becomes the issue, the body becomes the description", %{dir: dir} do
      write_ticket(dir, "T-1.md", markdown("id: T-1\ntitle: Cache git roots\nstate: ready\nlabels: [perf, ux]\npriority: 2", "Cache it. Add a test.\n"))
      write_ticket(dir, "T-2.md", markdown("id: T-2\ntitle: Second\nstate: open", "Body two\n"))

      assert {:ok, [first, second]} = FileTracker.tickets(settings(dir))

      assert %Issue{} = first
      assert first.id == "T-1"
      assert first.identifier == "T-1"
      assert first.title == "Cache git roots"
      assert first.state == "ready"
      assert first.labels == ["perf", "ux"]
      assert first.priority == 2
      assert first.description == "Cache it. Add a test.\n"
      assert first.dispatchable

      assert second.id == "T-2"
      assert second.state == "open"
    end

    test "id / title / state fall back to the file name and to open", %{dir: dir} do
      write_ticket(dir, "T-9.md", markdown("title: Only a title", "Body\n"))

      assert {:ok, [issue]} = FileTracker.tickets(settings(dir))
      assert issue.id == "T-9"
      assert issue.identifier == "T-9"
      assert issue.title == "Only a title"
      assert issue.state == "open"
    end

    test "a file without front matter is not a ticket (README can live next to them)", %{dir: dir} do
      write_ticket(dir, "README.md", "# Tickets\n\nEdit `state:` to move work along.\n")
      write_ticket(dir, "T-1.md", markdown("id: T-1", "Body\n"))

      assert {:ok, issues} = FileTracker.tickets(settings(dir))
      assert Enum.map(issues, & &1.id) == ["T-1"]
    end

    test "blocked_by holds the ticket back instead of dropping it", %{dir: dir} do
      write_ticket(dir, "T-1.md", markdown("id: T-1\nstate: open\nblocked_by: [T-0]", "Body\n"))

      assert {:ok, [issue]} = FileTracker.tickets(settings(dir))
      assert issue.blocked_by == ["T-0"]
      refute issue.dispatchable
    end
  end

  describe "a single file" do
    test "a YAML file may hold a list of tickets", %{dir: dir} do
      path = Path.join(dir, "backlog.yaml")

      File.write!(path, """
      - id: A-1
        title: From YAML
        state: ready
        labels: "infra, ci"
      - id: A-2
        title: Also YAML
        state: done
      """)

      assert {:ok, [one, two]} = FileTracker.tickets(settings(path))
      assert one.id == "A-1"
      assert one.labels == ["infra", "ci"]
      assert two.state == "done"
    end

    test "a Markdown file without front matter is an error (it claimed to be a ticket)", %{dir: dir} do
      path = write_ticket(dir, "ticket.md", "no front matter here\n")

      assert {:error, {:file_tracker_missing_front_matter, ^path}} = FileTracker.tickets(settings(path))
    end
  end

  describe "fetching" do
    setup %{dir: dir} do
      write_ticket(dir, "T-1.md", markdown("id: T-1\ntitle: Ready one\nstate: ready", "b\n"))
      write_ticket(dir, "T-2.md", markdown("id: T-2\ntitle: Open one\nstate: open", "b\n"))
      write_ticket(dir, "T-3.md", markdown("id: T-3\ntitle: Done one\nstate: done", "b\n"))
      {:ok, dir: dir}
    end

    test "by state, case-insensitively", %{dir: dir} do
      assert {:ok, issues} = FileTracker.fetch_issues_by_states(["READY", " Open "], settings(dir))
      assert Enum.map(issues, & &1.id) == ["T-1", "T-2"]
    end

    test "an active state nobody uses yields an empty list, not an error", %{dir: dir} do
      assert {:ok, []} = FileTracker.fetch_issues_by_states(["nonexistent"], settings(dir))
    end

    test "by id", %{dir: dir} do
      assert {:ok, [issue]} = FileTracker.fetch_issues_by_ids(["T-2"], settings(dir))
      assert issue.title == "Open one"
    end
  end

  describe "configuration" do
    test "validate_config is ok for a real directory", %{dir: dir} do
      assert :ok = FileTracker.validate_config(settings(dir))
    end

    test "a missing path fails closed" do
      assert {:error, :missing_file_tracker_path} = FileTracker.validate_config(%{provider: %{}})
      assert {:error, :missing_file_tracker_path} = FileTracker.tickets(%{provider: %{}})
    end

    test "a path that does not exist is an error, never an empty backlog", %{dir: dir} do
      missing = Path.expand(Path.join(dir, "nope"))
      assert {:error, {:file_tracker_path_not_found, ^missing}} = FileTracker.tickets(settings(missing))
      assert {:error, {:file_tracker_path_not_found, ^missing}} = FileTracker.validate_config(settings(missing))
    end

    test "no credentials to redact, no agent tools", %{dir: dir} do
      assert FileTracker.secret_environment_names(settings(dir)) == []
      assert FileTracker.agent_tool_specs() == []
    end

    test "`~` in the path is expanded", %{dir: dir} do
      # 指向一个不存在的位置：断言错误里的路径已经被展开（不含字面量 "~"）
      assert {:error, {:file_tracker_path_not_found, expanded}} =
               FileTracker.tickets(settings("~/.symphony-does-not-exist-#{Path.basename(dir)}"))

      refute String.contains?(expanded, "~")
      assert String.starts_with?(expanded, Path.expand(System.user_home!()))
    end

    test "invalid YAML reports the file", %{dir: dir} do
      path = write_ticket(dir, "broken.yaml", "id: [unclosed\n")

      assert {:error, {:file_tracker_invalid_yaml, ^path, _reason}} = FileTracker.tickets(settings(path))
    end
  end
end
