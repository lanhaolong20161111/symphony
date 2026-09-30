defmodule SymphonyElixirWeb.TaskLiveTest do
  # async: false -- every test starts the endpoint, moves `:projects_dir` and points
  # `:workflow_file_path` at a project file it wrote, all of which are global.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SymphonyElixirWeb.Endpoint

  # The owner the fixture project already works under -- and therefore the prefix the page derives
  # the proposed repository name with.
  @owner "me"

  # Both collaborators arrive as endpoint configuration, the way `ControlLive` takes its HTTP client:
  # the creator replaces `Projects.create_repo/2`, so no test calls `gh` or opens a socket, and the
  # editor replaces `WorkflowEditor.put_scalar/3`, so a test can prove the writer was never asked to
  # produce a file. The file they are given is a temp project file -- this instance's own workflow
  # file is never touched here.
  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    registry_config = Application.get_env(:symphony_elixir, :projects_dir)
    workflow_path = Workflow.workflow_file_path()

    root = Path.join(System.tmp_dir!(), "task-live-#{System.unique_integer([:positive])}")
    registry = Path.join(root, "registry")
    File.mkdir_p!(registry)
    Application.put_env(:symphony_elixir, :projects_dir, registry)

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
      restore(:projects_dir, registry_config)
      Workflow.set_workflow_file_path(workflow_path)
      File.rm_rf(root)
    end)

    {:ok, root: root, registry: registry}
  end

  test "a project with no tickets repository offers the action and a proposed name",
       %{root: root, registry: registry} do
    workflow = write_project(registry, root, "my-app", nil)
    Workflow.set_workflow_file_path(workflow)
    test_pid = self()

    start_test_endpoint(tickets_repo_creator: creator(test_pid))
    {:ok, view, html} = live(build_conn(), "/tasks")

    # The state the action exists for: the row says the tickets repository is not declared.
    assert html =~ "（没声明 ✗）"

    # The action, with the name derived from the project and the owner its issues already live under.
    assert has_element?(view, "form[phx-submit=create_tickets_repo]")
    assert has_element?(view, ~s(input[name="repo[name]"]))
    assert html =~ ~s(value="me/my-app-tickets")
    assert html =~ "建立并采用为 tickets 仓库"

    # Private before anything happens, and nothing created by rendering the page.
    assert html =~ "私有"
    refute_received {:created, _, _}
  end

  test "a project that already declares a tickets repository is not offered the action",
       %{root: root, registry: registry} do
    workflow = write_project(registry, root, "my-app", "me/my-app-tickets")
    Workflow.set_workflow_file_path(workflow)
    test_pid = self()

    start_test_endpoint(tickets_repo_creator: creator(test_pid))
    {:ok, view, html} = live(build_conn(), "/tasks")

    assert html =~ "me/my-app-tickets"
    refute html =~ "（没声明 ✗）"
    refute has_element?(view, "form[phx-submit=create_tickets_repo]")
    refute html =~ "建立并采用为 tickets 仓库"
    refute_received {:created, _, _}
  end

  test "a submit that creates the repository writes the setting into the workflow file",
       %{root: root, registry: registry} do
    workflow = write_project(registry, root, "my-app", nil)
    Workflow.set_workflow_file_path(workflow)
    before = File.read!(workflow)
    test_pid = self()

    start_test_endpoint(tickets_repo_creator: creator(test_pid))
    {:ok, view, _html} = live(build_conn(), "/tasks")

    html = submit_repo(view, "me/my-app-tickets")

    assert_received {:created, "me/my-app-tickets", opts}
    # Private by default, which is what the page says and what it asks for.
    assert opts[:public] == false

    # The setting, in the file -- asserted as file contents, not as page copy.
    written = File.read!(workflow)
    assert written != before
    assert written =~ "janitor:"
    assert written =~ "tickets_repo: me/my-app-tickets"

    # Everything the file already had is still there: the editor edits in place, so comments,
    # ordering and the body survive the write.
    assert written =~ "issues_repo: me/my-app-issues"
    assert written =~ "active_states: [ready, in-progress]"
    assert written =~ "Work on my-app."

    # And the file the instance would read next still parses -- the same pair an instance uses --
    # so what was written is a setting the running project can actually load.
    assert {:ok, loaded} = Workflow.load(workflow)
    assert {:ok, _settings} = Schema.parse(loaded.config)

    # What the page says about it.
    assert html =~ "已创建 me/my-app-tickets"
    assert html =~ "janitor.tickets_repo"
    assert html =~ "me/my-app-tickets"
    # And the action is gone now that the project declares the repository.
    refute html =~ "建立并采用为 tickets 仓库"
  end

  test "an existing repository is adopted, says so, and the setting is still written",
       %{root: root, registry: registry} do
    workflow = write_project(registry, root, "my-app", nil)
    Workflow.set_workflow_file_path(workflow)
    test_pid = self()

    start_test_endpoint(
      tickets_repo_creator: fn repo, _opts ->
        send(test_pid, {:adopted, repo})
        :already_exists
      end
    )

    {:ok, view, _html} = live(build_conn(), "/tasks")
    html = submit_repo(view, "me/my-app-tickets")

    assert_received {:adopted, "me/my-app-tickets"}

    assert html =~ "已经存在"
    assert html =~ "一个字都没动"
    assert html =~ "直接采用"
    assert html =~ "janitor.tickets_repo"
    assert File.read!(workflow) =~ "tickets_repo: me/my-app-tickets"
  end

  test "a failed create renders the reason and leaves the workflow file byte-identical",
       %{root: root, registry: registry} do
    workflow = write_project(registry, root, "my-app", nil)
    Workflow.set_workflow_file_path(workflow)
    before = File.read!(workflow)
    test_pid = self()

    creator = fn repo, _opts ->
      send(test_pid, {:attempted, repo})
      {:error, {:gh_exit, 1, "HTTP 403: no permission to create repositories"}}
    end

    # If this seam is ever reached on this path, the test hears about it -- and the file it would
    # have written is read back below.
    start_test_endpoint(tickets_repo_creator: creator, workflow_editor: editor(test_pid))
    {:ok, view, _html} = live(build_conn(), "/tasks")

    html = submit_repo(view, "me/my-app-tickets")

    assert_received {:attempted, "me/my-app-tickets"}
    assert html =~ "建立 me/my-app-tickets 失败"
    assert html =~ "HTTP 403: no permission to create repositories"
    assert html =~ "workflow 一个字都没写"

    # Nothing was written, byte for byte, and the editor was never even asked.
    refute_received {:edited, _, _}
    assert File.read!(workflow) == before

    # Still a page, still offering the action it offered before.
    assert render(view) =~ "建立并采用为 tickets 仓库"
  end

  test "a write that fails is reported as a failed write, and the file is untouched",
       %{root: root, registry: registry} do
    workflow = write_project(registry, root, "my-app", nil)
    Workflow.set_workflow_file_path(workflow)
    before = File.read!(workflow)

    start_test_endpoint(
      tickets_repo_creator: fn _repo, _opts -> :created end,
      workflow_editor: fn _text, _path, _value -> {:error, :eacces} end
    )

    {:ok, view, _html} = live(build_conn(), "/tasks")
    html = submit_repo(view, "me/my-app-tickets")

    assert html =~ "但写 workflow 失败"
    assert html =~ "eacces"
    # The repository **was** created; the page says the write is what failed rather than claiming
    # either an unqualified success or a create that never happened.
    assert html =~ "已创建 me/my-app-tickets"
    assert File.read!(workflow) == before
    assert render(view) =~ "任务管理"
  end

  test "nothing is created or written without a submit", %{root: root, registry: registry} do
    workflow = write_project(registry, root, "my-app", nil)
    Workflow.set_workflow_file_path(workflow)
    before = File.read!(workflow)
    test_pid = self()

    start_test_endpoint(tickets_repo_creator: creator(test_pid), workflow_editor: editor(test_pid))
    {:ok, view, html} = live(build_conn(), "/tasks")

    # The proposal is there to read; it is not a creation.
    assert html =~ "me/my-app-tickets"

    # A re-render, including the page's own refresh button, is still not a submit.
    render_click(view, "refresh")

    refute_received {:created, _, _}
    refute_received {:edited, _, _}
    assert File.read!(workflow) == before
    assert render(view) =~ "建立并采用为 tickets 仓库"
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp submit_repo(view, name) do
    view
    |> form("form[phx-submit=create_tickets_repo]", repo: %{"name" => name})
    |> render_submit()
  end

  # A creator that records what it was asked for: nothing here calls `gh`, so a test can only ever
  # see the argv-shaped call the page makes through the seam.
  defp creator(test_pid) do
    fn repo, opts ->
      send(test_pid, {:created, repo, opts})
      :created
    end
  end

  defp editor(test_pid) do
    fn text, path, value ->
      send(test_pid, {:edited, path, value})
      {:ok, text}
    end
  end

  # A project file the real parser accepts (`Projects.list/1` reads it with the same
  # `Workflow.load/1` + `Schema.parse/1` pair an instance uses), with `tickets_repo` optional --
  # which is exactly the state the action exists for. The same file is pointed at as this instance's
  # own workflow, so the file the action writes is this one, under the temp directory.
  defp write_project(registry, root, name, tickets_repo) do
    queue = Path.join(root, "#{name}-queue")
    File.mkdir_p!(queue)
    path = Path.join(registry, "#{name}.md")

    janitor =
      [
        "janitor:",
        "  enabled: false",
        "  interval_ms: 30000",
        "  issues_repo: #{@owner}/#{name}-issues",
        tickets_repo && "  tickets_repo: #{tickets_repo}",
        ~s(  tickets_path: "#{slash(queue)}")
      ]
      |> Enum.reject(&is_nil/1)

    File.write!(path, """
    ---
    tracker:
      kind: file
      provider:
        path: "#{slash(queue)}"
      active_states: [ready, in-progress]
      terminal_states: [done, cancelled]
    #{Enum.join(janitor, "\n")}
    workspace:
      root: "#{slash(Path.join(root, "ws-#{name}"))}"
    agent:
      backend: codex
    ---

    Work on #{name}.
    """)

    path
  end

  defp slash(path), do: String.replace(path, "\\", "/")

  defp restore(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end
end
