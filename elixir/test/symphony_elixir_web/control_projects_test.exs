defmodule SymphonyElixirWeb.ControlProjectsTest do
  # async: false -- every test renders a real route and moves `:projects_dir`.
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    registry_config = Application.get_env(:symphony_elixir, :projects_dir)

    registry =
      Path.join(System.tmp_dir!(), "control-projects-#{System.unique_integer([:positive])}")

    File.mkdir_p!(registry)
    Application.put_env(:symphony_elixir, :projects_dir, registry)

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)

      if registry_config,
        do: Application.put_env(:symphony_elixir, :projects_dir, registry_config),
        else: Application.delete_env(:symphony_elixir, :projects_dir)

      File.rm_rf(registry)
    end)

    {:ok, registry: registry}
  end

  test "a reachable instance shows its counts, an unreachable one shows down, the page renders",
       %{registry: registry} do
    write_project(registry, "alpha", 4111)
    write_project(registry, "beta", 4112)

    start_test_endpoint(project_status_client: client(), project_status_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/control")

    # The page is still the control page: a project that cannot be reached must not take it down.
    assert html =~ "Control Plane"

    # The row that answered: the status is up, with the counts that instance reported.
    assert html =~ ~s(state-badge-active">up)
    assert html =~ "running 2"
    assert html =~ "retrying 1"
    assert html =~ "blocked 3"

    # The row that refused the connection: down, and no counts -- a zero would be a number the
    # instance never claimed.
    assert html =~ ~s(state-badge-warning">down)
    refute html =~ "running 0"

    # The declared port and the workflow file each row is read from.
    assert html =~ "4111"
    assert html =~ "4112"
    assert html =~ "alpha.md"
    assert html =~ "beta.md"
  end

  test "a slow instance is unreachable rather than holding the page", %{registry: registry} do
    write_project(registry, "gamma", 4113)

    slow = fn _url ->
      Process.sleep(2_000)
      {:ok, %{"counts" => %{}}}
    end

    start_test_endpoint(project_status_client: slow, project_status_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/control")

    assert html =~ "Control Plane"
    assert html =~ ~s(state-badge-danger">unreachable)
    assert html =~ "no answer in time"
    refute html =~ "running 0"
  end

  test "an empty registry renders the empty state instead of a table" do
    start_test_endpoint(project_status_client: client(), project_status_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/control")

    assert html =~ ~s(id="projects-empty")
    refute html =~ "<th>workflow file</th>"
  end

  test "every registry row links to this console's ticket view with the project parameter",
       %{registry: registry} do
    write_project(registry, "alpha", 4111)
    write_project(registry, "beta", 4112)

    start_test_endpoint(project_status_client: client(), project_status_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/control")

    # alpha answers and beta refuses -- and both rows carry the link, because a project that is down
    # is exactly the one whose tickets this console now has to be able to show.
    assert html =~ ~s(state-badge-warning">down)
    assert html =~ ~s(href="/control/tickets?project=alpha")
    assert html =~ ~s(href="/control/tickets?project=beta")

    # The tickets link no longer points at the other instance's own copy of the route, which exists
    # only while that instance is up.
    refute html =~ "4111/control/tickets"
    refute html =~ "4112/control/tickets"
  end

  # No socket is opened by any test here: the client a row's state comes from is injected through the
  # endpoint config, exactly like the orchestrator the page already reads.
  defp client do
    fn url ->
      if String.contains?(url, "4111") do
        {:ok, %{"counts" => %{"running" => 2, "retrying" => 1, "blocked" => 3}}}
      else
        {:error, {:project_unreachable, %Mint.TransportError{reason: :econnrefused}}}
      end
    end
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(snapshot_timeout_ms: 50)
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp write_project(dir, name, port) do
    File.write!(Path.join(dir, "#{name}.md"), """
    ---
    server:
      host: 127.0.0.1
      port: #{port}
    tracker:
      kind: file
      provider:
        path: C:/q/#{name}
    janitor:
      enabled: false
      interval_ms: 30000
      issues_repo: owner/#{name}
      tickets_repo: owner/tickets
      tickets_path: C:/q/#{name}
    workspace:
      root: C:/ws/#{name}
    agent:
      backend: codex
    hooks:
      after_create: |
        if ! git -C . rev-parse --is-inside-work-tree >/dev/null 2>&1; then git clone --depth 1 https://github.com/owner/#{name} .; fi
    ---

    Work on #{name}.
    """)

    :ok
  end
end
