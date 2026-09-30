defmodule SymphonyElixirWeb.ControlInstancesTest do
  # async: false -- every test renders a real route, moves `:projects_dir` and `:instances_file`, and
  # writes a state file.
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.InstanceRegistry

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    registry_config = Application.get_env(:symphony_elixir, :projects_dir)
    file_config = Application.get_env(:symphony_elixir, :instances_file)

    root = Path.join(System.tmp_dir!(), "control-instances-#{System.unique_integer([:positive])}")
    registry = Path.join(root, "registry")
    File.mkdir_p!(registry)

    Application.put_env(:symphony_elixir, :projects_dir, registry)
    Application.put_env(:symphony_elixir, :instances_file, Path.join(root, "instances.json"))

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
      restore(:projects_dir, registry_config)
      restore(:instances_file, file_config)
      File.rm_rf(root)
    end)

    {:ok, registry: registry}
  end

  test "a down project offers Start, a hub-controlled one offers Stop, this instance offers neither",
       %{registry: registry} do
    own = write_project(registry, "self", 4100)
    Application.put_env(:symphony_elixir, :workflow_file_path, own)
    write_project(registry, "alpha", 4101)
    write_project(registry, "beta", 4102)

    # The hub's memory of starting beta, with the counts its own state route reported below.
    seed(%{"beta" => record("beta", 4102, 4242)})

    start_test_endpoint(
      project_status_client: client(%{4101 => :down, 4102 => {:up, 2, 1, 3}}),
      project_status_timeout_ms: 50,
      instance_launcher: fn _spec -> {:ok, 7777} end,
      instance_port_held?: never_held(),
      instance_alive?: alive_all(),
      instance_kill: no_kill(),
      instance_own_port: 4100
    )

    {:ok, view, html} = live(build_conn(), "/control")

    assert has_element?(view, "button[phx-click='start_instance'][phx-value-project='alpha']")
    assert has_element?(view, "button[phx-click='stop_instance'][phx-value-project='beta']")

    # Nothing answering is the only row that gets a start; only a project the hub started *and* that
    # answered gets a stop; and this instance gets neither.
    refute has_element?(view, "button[phx-click='start_instance'][phx-value-project='beta']")
    refute has_element?(view, "button[phx-click='stop_instance'][phx-value-project='alpha']")
    refute has_element?(view, "button[phx-value-project='self']")

    # What a stop is about to kill, said before it happens: the pid, and the counts from the last
    # probe.
    assert html =~ "kills pid 4242"
    assert html =~ "2 running, 1 retrying, 3 blocked"
  end

  test "an instance answering that the hub did not start offers no stop", %{registry: registry} do
    write_project(registry, "manual", 4103)

    start_test_endpoint(
      project_status_client: client(%{4103 => {:up, 1, 0, 0}}),
      project_status_timeout_ms: 50,
      instance_kill: no_kill()
    )

    {:ok, view, html} = live(build_conn(), "/control")

    refute has_element?(view, "button[phx-click='stop_instance'][phx-value-project='manual']")
    assert html =~ "answering, not started by this hub"
  end

  test "the instance serving the page has no stop action, even with a record claiming otherwise",
       %{registry: registry} do
    own = write_project(registry, "self", 4100)
    Application.put_env(:symphony_elixir, :workflow_file_path, own)
    seed(%{"self" => record("self", 4100, 4242)})

    start_test_endpoint(
      project_status_client: client(%{4100 => {:up, 0, 0, 0}}),
      project_status_timeout_ms: 50,
      instance_kill: no_kill(),
      instance_alive?: alive_all(),
      instance_own_port: 4100
    )

    {:ok, view, html} = live(build_conn(), "/control")

    refute has_element?(view, "button[phx-click='stop_instance']")
    assert html =~ "the hub never stops the instance it is running in"
  end

  test "Start runs the registry's file on the port the hub assigns, and records it", %{registry: registry} do
    write_project(registry, "alpha", 4101)
    test_pid = self()

    launcher = fn spec ->
      send(test_pid, {:launched, spec})
      {:ok, 7777}
    end

    start_test_endpoint(
      project_status_client: client(%{4101 => :down}),
      project_status_timeout_ms: 50,
      instance_launcher: launcher,
      instance_port_held?: never_held(),
      instance_alive?: alive_none(),
      instance_kill: no_kill()
    )

    {:ok, view, _html} = live(build_conn(), "/control")

    html = view |> element("button[phx-click='start_instance'][phx-value-project='alpha']") |> render_click()

    assert html =~ "started pid 7777 on port 4101"
    assert_receive {:launched, spec}
    assert Path.expand(spec.workflow) == Path.expand(Path.join(registry, "alpha.md"))
    assert spec.port == 4101
    assert Path.expand(spec.logs_root) == Path.expand(InstanceRegistry.logs_root("alpha"))

    # Recorded, so the next read of the page knows this project is the hub's.
    assert %{"alpha" => record} = InstanceRegistry.records()
    assert record.pid == 7777
    assert record.port == 4101
  end

  test "a start that fails renders the reason in the row, and the page still renders", %{registry: registry} do
    write_project(registry, "alpha", 4101)

    start_test_endpoint(
      project_status_client: client(%{4101 => :down}),
      project_status_timeout_ms: 50,
      instance_launcher: fn _spec -> {:error, {:launch_raised, "escript not found"}} end,
      instance_port_held?: never_held(),
      instance_alive?: alive_none(),
      instance_kill: no_kill()
    )

    {:ok, view, _html} = live(build_conn(), "/control")

    html = view |> element("button[phx-click='start_instance'][phx-value-project='alpha']") |> render_click()

    assert html =~ "Control Plane"
    assert html =~ "could not start alpha"
    assert html =~ "escript not found"
  end

  test "a stop that fails renders the reason in the row, and the page still renders", %{registry: registry} do
    write_project(registry, "beta", 4102)
    seed(%{"beta" => record("beta", 4102, 4242)})

    start_test_endpoint(
      project_status_client: client(%{4102 => {:up, 1, 0, 0}}),
      project_status_timeout_ms: 50,
      instance_kill: fn _pid -> {:error, {:kill_exit, 128, "ERROR: The process not found."}} end,
      instance_alive?: alive_all()
    )

    {:ok, view, _html} = live(build_conn(), "/control")

    html = view |> element("button[phx-click='stop_instance'][phx-value-project='beta']") |> render_click()

    assert html =~ "Control Plane"
    assert html =~ "stopping beta (pid 4242) failed"

    # The record survives a failed kill: the process may still be there, and forgetting it would lose
    # the only handle the hub has on it.
    assert Map.has_key?(InstanceRegistry.records(), "beta")
  end

  test "a stop of a pid that is already gone drops the record and says so", %{registry: registry} do
    write_project(registry, "beta", 4102)
    seed(%{"beta" => record("beta", 4102, 4242)})

    start_test_endpoint(
      project_status_client: client(%{4102 => {:up, 1, 0, 0}}),
      project_status_timeout_ms: 50,
      instance_kill: no_kill(),
      instance_alive?: alive_none()
    )

    {:ok, view, _html} = live(build_conn(), "/control")

    html = view |> element("button[phx-click='stop_instance'][phx-value-project='beta']") |> render_click()

    assert html =~ "not running any more"
    refute_receive {:killed, _pid}
    assert InstanceRegistry.records() == %{}
  end

  test "a crafted stop for this instance is refused in the row, not carried out", %{registry: registry} do
    own = write_project(registry, "self", 4100)
    Application.put_env(:symphony_elixir, :workflow_file_path, own)
    seed(%{"self" => record("self", 4100, 4242)})

    start_test_endpoint(
      project_status_client: client(%{4100 => {:up, 0, 0, 0}}),
      project_status_timeout_ms: 50,
      instance_kill: no_kill(),
      instance_alive?: alive_all(),
      instance_own_port: 4100
    )

    {:ok, view, _html} = live(build_conn(), "/control")

    # The button is not rendered, but a browser can send the event anyway -- so the refusal has to be
    # in the registry, and this is the test that says so.
    html = render_click(view, "stop_instance", %{"project" => "self"})

    assert html =~ "the hub never stops the instance it is running in"
    refute_receive {:killed, _pid}
    assert Map.has_key?(InstanceRegistry.records(), "self")
  end

  test "a crafted start for a path rather than a name is refused in the row", %{registry: registry} do
    write_project(registry, "alpha", 4101)

    start_test_endpoint(
      project_status_client: client(%{4101 => :down}),
      project_status_timeout_ms: 50,
      instance_launcher: fn _spec -> {:ok, 7777} end,
      instance_port_held?: never_held(),
      instance_alive?: alive_none(),
      instance_kill: no_kill()
    )

    {:ok, view, _html} = live(build_conn(), "/control")

    html = render_click(view, "start_instance", %{"project" => "../../symphony-projects/symphony.md"})

    # There is no row for that name, so the refusal lands in the page's own error card rather than
    # being dropped -- and nothing was launched.
    assert html =~ "Control Plane"
    assert html =~ "no project named"
    assert html =~ "never a path handed to it"
    refute_receive {:launched, _spec}
    assert InstanceRegistry.records() == %{}
  end

  test "an empty registry renders the empty state instead of a table with controls" do
    start_test_endpoint(project_status_client: client(%{}), project_status_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/control")

    assert html =~ ~s(id="projects-empty")
    refute has_element?(view, "button[phx-click='start_instance']")
    refute has_element?(view, "button[phx-click='stop_instance']")
  end

  # ── helpers ──────────────────────────────────────────────────────────────────
  #
  # No socket is opened and no process is started by any test here: the state read, the launcher, the
  # "port is held" check, the "pid is alive" check and the kill all arrive as endpoint configuration,
  # exactly like `:project_status_client` above them.

  defp client(answers) do
    fn url -> answer(url, answers) end
  end

  defp answer(url, answers) do
    case port_of(url) do
      {:ok, port} -> answers |> Map.get(port, :down) |> reply()
      :error -> refused()
    end
  end

  defp reply(:down), do: refused()

  defp reply({:up, running, retrying, blocked}) do
    {:ok, %{"counts" => %{"running" => running, "retrying" => retrying, "blocked" => blocked}}}
  end

  # Nothing is listening: the answer `ProjectStatus` turns into `:down`, and the one a row the hub
  # does not control gets. No test here opens a socket; the URL is only ever parsed for its port.
  defp refused, do: {:error, {:project_unreachable, %Mint.TransportError{reason: :econnrefused}}}

  defp port_of(url) do
    case Regex.run(~r/:(\d+)\//, url) do
      [_, port] -> {:ok, String.to_integer(port)}
      _none -> :error
    end
  end

  defp never_held, do: fn _port -> false end
  defp alive_all, do: fn _pid -> true end
  defp alive_none, do: fn _pid -> false end
  defp no_kill, do: fn pid -> send(self(), {:killed, pid}) end

  defp seed(records), do: :ok = InstanceRegistry.write(records, InstanceRegistry.file())

  defp record(name, port, pid) do
    %{
      project: name,
      workflow: "C:/registry/#{name}.md",
      port: port,
      pid: pid,
      logs_root: "C:/logs/#{name}",
      started_at: "2026-05-01T09:12:44Z"
    }
  end

  defp restore(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore(key, value), do: Application.put_env(:symphony_elixir, key, value)

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
    path = Path.join(dir, "#{name}.md")

    File.write!(path, """
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

    path
  end
end
