defmodule SymphonyElixir.ProjectsTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Projects

  describe "queue_conflicts/1" do
    test "reports a queue claimed by more than one project" do
      projects = [
        project("a", "C:/q/shared"),
        project("b", "C:/q/shared"),
        project("c", "C:/q/own")
      ]

      assert Projects.queue_conflicts(projects) == %{"C:/q/shared" => ["a", "b"]}
    end

    test "one project per queue is the healthy answer" do
      assert Projects.queue_conflicts([project("a", "C:/q/a"), project("b", "C:/q/b")]) == %{}
      assert Projects.queue_conflicts([project("a", "C:/q/a")]) == %{}
      assert Projects.queue_conflicts([]) == %{}
    end

    test "a project whose file did not parse is not counted as claiming anything" do
      broken = %{project("a", "C:/q/shared") | error: "boom"}
      assert Projects.queue_conflicts([broken, project("b", "C:/q/shared")]) == %{}
    end

    test "a project with no queue is not a conflict with another with no queue" do
      assert Projects.queue_conflicts([project("a", nil), project("b", nil)]) == %{}
    end
  end

  describe "registry_dir/0" do
    setup do
      previous = Application.get_env(:symphony_elixir, :projects_dir)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:symphony_elixir, :projects_dir, previous),
          else: Application.delete_env(:symphony_elixir, :projects_dir)
      end)

      :ok
    end

    test "defaults to ~/code/symphony-projects, expanded" do
      Application.delete_env(:symphony_elixir, :projects_dir)

      assert Projects.registry_dir() == Path.expand("~/code/symphony-projects")
    end

    test "is configurable, and expanded so a `~` path works on Windows too" do
      Application.put_env(:symphony_elixir, :projects_dir, "~/somewhere-else")

      assert Projects.registry_dir() == Path.expand("~/somewhere-else")
    end
  end

  describe "list/0 against a real directory" do
    setup do
      dir = Path.join(System.tmp_dir!(), "projects-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      previous = Application.get_env(:symphony_elixir, :projects_dir)
      Application.put_env(:symphony_elixir, :projects_dir, dir)

      on_exit(fn ->
        File.rm_rf(dir)

        if previous,
          do: Application.put_env(:symphony_elixir, :projects_dir, previous),
          else: Application.delete_env(:symphony_elixir, :projects_dir)
      end)

      {:ok, dir: dir}
    end

    test "reads each project's queue, repositories, agent and workspace", %{dir: dir} do
      write_project(dir, "alpha", port: 4101, queue: "C:/q/alpha", backend: "codex")
      write_project(dir, "beta", port: 4102, queue: "C:/q/beta", backend: "acp")

      projects = Projects.list()
      assert Enum.map(projects, & &1.name) == ["alpha", "beta"]

      alpha = Enum.find(projects, &(&1.name == "alpha"))
      assert alpha.error == nil
      assert alpha.port == 4101
      assert alpha.queue == "C:/q/alpha"
      assert alpha.issues_repo == "owner/alpha"
      # Nothing is running on those ports, so unreachable is the honest answer rather than an error.
      assert alpha.reachable? == false
      assert alpha.backend == "codex"
      # The repositories come out of the hook's `git clone`, which is the only place they are written.
      assert alpha.repos == ["https://github.com/owner/alpha"]

      beta = Enum.find(projects, &(&1.name == "beta"))
      assert beta.backend == "acp"
      assert beta.adapter == "workbuddy"
      assert beta.model == "auto"
    end

    test "a file that does not parse is reported, not shown half-filled", %{dir: dir} do
      write_project(dir, "good", port: 4103, queue: "C:/q/good", backend: "codex")
      File.write!(Path.join(dir, "broken.md"), "---\ntracker: [this is not a mapping\n---\n\nBody.\n")

      projects = Projects.list()
      assert Enum.map(projects, & &1.name) == ["broken", "good"]

      broken = Enum.find(projects, &(&1.name == "broken"))
      assert is_binary(broken.error)
      assert broken.queue == nil
      assert broken.repos == []
      # Same keys as a healthy project, so a caller never has to ask which one it got.
      assert Map.keys(broken) |> Enum.sort() == Map.keys(Enum.find(projects, &(&1.name == "good"))) |> Enum.sort()
    end

    test "README.md is not a project", %{dir: dir} do
      write_project(dir, "only", port: 4104, queue: "C:/q/only", backend: "codex")
      File.write!(Path.join(dir, "README.md"), "# the registry\n")

      assert Enum.map(Projects.list(), & &1.name) == ["only"]
    end

    test "an empty (or missing) registry is no projects, not an error" do
      assert Projects.list() == []

      Application.put_env(:symphony_elixir, :projects_dir, Path.join(System.tmp_dir!(), "does-not-exist-#{System.unique_integer([:positive])}"))
      assert Projects.list() == []
      refute Projects.present?()
    end

    test "find/1 is a lookup by file name", %{dir: dir} do
      write_project(dir, "alpha", port: 4105, queue: "C:/q/alpha", backend: "codex")

      assert {:ok, %{name: "alpha"}} = Projects.find("alpha")
      assert :error = Projects.find("nope")
    end

    test "the two halves of a queue are both reported, so a disagreement is visible", %{dir: dir} do
      path = write_project(dir, "split", port: 4106, queue: "C:/q/tracker-side", backend: "codex")
      text = File.read!(path)
      File.write!(path, String.replace(text, "tickets_path: C:/q/tracker-side", "tickets_path: C:/q/mirror-side"))

      project = Projects.list() |> List.first()
      assert project.queue == "C:/q/tracker-side"
      assert project.mirror_path == "C:/q/mirror-side"
    end
  end

  defp project(name, queue) do
    %{
      name: name,
      path: "C:/registry/#{name}.md",
      host: "127.0.0.1",
      port: 4001,
      url: nil,
      queue: queue,
      mirror_path: queue,
      issues_repo: "owner/#{name}",
      tickets_repo: "owner/tickets",
      workspace_root: "C:/ws/#{name}",
      backend: "codex",
      adapter: nil,
      model: nil,
      repos: [],
      reachable?: false,
      queue_present?: true,
      error: nil
    }
  end

  defp write_project(dir, name, opts) do
    path = Path.join(dir, "#{name}.md")

    acp =
      if opts[:backend] == "acp" do
        "\nacp:\n  adapter: workbuddy\n  model: auto\n"
      else
        ""
      end

    File.write!(path, """
    ---
    server:
      host: 127.0.0.1
      port: #{opts[:port]}
    tracker:
      kind: file
      provider:
        path: #{opts[:queue]}
      active_states:
        - ready
    janitor:
      enabled: false
      interval_ms: 30000
      issues_repo: owner/#{name}
      tickets_repo: owner/tickets
      tickets_path: #{opts[:queue]}
    workspace:
      root: C:/ws/#{name}
    agent:
      backend: #{opts[:backend]}
    #{String.trim_trailing(acp)}
    hooks:
      after_create: |
        if ! git -C . rev-parse --is-inside-work-tree >/dev/null 2>&1; then git clone --depth 1 https://github.com/owner/#{name} .; fi
    ---

    Work on #{name}.
    """)

    path
  end
end
