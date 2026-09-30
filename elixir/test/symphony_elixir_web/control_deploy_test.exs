defmodule SymphonyElixirWeb.ControlDeployTest do
  # async: false -- every test renders a real route, moves `:projects_dir` and `:instances_file`, and
  # writes workflow files into a temporary registry.
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SymphonyElixirWeb.Endpoint

  # The command and the directory the project's own workflow declares -- the only ones any test here
  # expects to run. Nothing injects them: they come out of the file in the temporary registry, through
  # the same parser an instance uses.
  @deploy_command "make deploy"
  @deploy_directory "C:/srv/app"
  @declared_timeout 42_000

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    registry_config = Application.get_env(:symphony_elixir, :projects_dir)
    file_config = Application.get_env(:symphony_elixir, :instances_file)

    root = Path.join(System.tmp_dir!(), "control-deploy-#{System.unique_integer([:positive])}")
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

  test "a project that declares a deploy offers the button, and one that declares none says so",
       %{registry: registry} do
    write_project(registry, "alpha", 4101, {@deploy_command, @deploy_directory, @declared_timeout})
    write_project(registry, "beta", 4102, nil)

    start_test_endpoint(
      project_status_client: client(%{4101 => :down, 4102 => :down}),
      project_status_timeout_ms: 50,
      deploy_runner: never_used()
    )

    {:ok, view, html} = live(build_conn(), "/control")

    assert has_element?(view, "button[phx-click='deploy_project'][phx-value-project='alpha']")
    refute has_element?(view, "button[phx-click='deploy_project'][phx-value-project='beta']")

    # A project that declares none is a legitimate state, and the cell says so rather than showing a
    # button whose every press would fail.
    assert html =~ "no deploy declared"

    # What a deploy is about to run is said before it runs: the declared command, and the directory it
    # belongs to. Both come from the workflow file -- this page cannot supply either.
    assert html =~ @deploy_command
    assert html =~ @deploy_directory
    assert html =~ "deploy.command"
  end

  test "nothing runs on mount or on a re-render: a deploy happens on a press and only on a press",
       %{registry: registry} do
    write_project(registry, "alpha", 4101, {@deploy_command, @deploy_directory, @declared_timeout})

    start_test_endpoint(
      project_status_client: client(%{4101 => :down}),
      project_status_timeout_ms: 50,
      deploy_runner: recording_runner({:ok, "release built", 0})
    )

    {:ok, view, _html} = live(build_conn(), "/control")

    # Mounted, rendered, and re-rendered -- and the subscribed update the page re-reads its panels on.
    refute_received {:deploy_ran, _, _, _}
    assert render(view)
    send(view.pid, :observability_updated)
    assert render(view)
    refute_received {:deploy_ran, _, _, _}

    render_click(view, "deploy_project", %{"project" => "alpha"})
    assert_received {:deploy_ran, _, _, _}
  end

  test "the declared command runs in the declared directory, and the row shows the status and the tail",
       %{registry: registry} do
    write_project(registry, "alpha", 4101, {@deploy_command, @deploy_directory, @declared_timeout})

    start_test_endpoint(
      project_status_client: client(%{4101 => :down}),
      project_status_timeout_ms: 50,
      deploy_runner: recording_runner({:ok, "release built\nuploaded 12 files", 0})
    )

    {:ok, view, _html} = live(build_conn(), "/control")

    html = render_click(view, "deploy_project", %{"project" => "alpha"})

    assert_received {:deploy_ran, _executable, args, run_opts}
    assert args == ["-lc", @deploy_command]
    assert run_opts[:cd] == @deploy_directory
    assert run_opts[:timeout] == @declared_timeout

    # The outcome lives in the row, the way a start or a stop reports its own: the exit status and the
    # tail of what the command printed.
    assert html =~ "Control Plane"
    assert html =~ "exit 0"
    assert html =~ "release built"
    assert html =~ "uploaded 12 files"
  end

  test "a crafted request cannot inject, extend or redirect the command", %{registry: registry} do
    write_project(registry, "alpha", 4101, {@deploy_command, @deploy_directory, @declared_timeout})

    start_test_endpoint(
      project_status_client: client(%{4101 => :down}),
      project_status_timeout_ms: 50,
      deploy_runner: recording_runner({:ok, "ok", 0})
    )

    {:ok, view, _html} = live(build_conn(), "/control")

    # The button is not the boundary: a browser can send any event with any values. The rule has to
    # hold in the code that runs, and it does -- the event is destructured to the project *name*, and
    # the command, the directory and the deadline come out of the workflow file.
    html =
      render_click(view, "deploy_project", %{
        "project" => "alpha",
        "command" => "echo pwned",
        "cmd" => "echo pwned",
        "working_directory" => "C:/Windows/System32",
        "cwd" => "C:/Windows/System32",
        "shell" => "cmd.exe",
        "script" => "./evil.sh",
        "argv" => ["-lc", "echo pwned"],
        "timeout_ms" => 1
      })

    assert_received {:deploy_ran, executable, args, run_opts}
    assert args == ["-lc", @deploy_command]
    assert run_opts[:cd] == @deploy_directory
    assert run_opts[:timeout] == @declared_timeout
    refute executable == "cmd.exe"
    refute html =~ "pwned"
  end

  test "a non-zero exit renders its reason in the row, and the page still renders", %{registry: registry} do
    write_project(registry, "alpha", 4101, {@deploy_command, @deploy_directory, @declared_timeout})

    start_test_endpoint(
      project_status_client: client(%{4101 => :down}),
      project_status_timeout_ms: 50,
      deploy_runner: recording_runner({:ok, "make: *** [deploy] Error 2", 2})
    )

    {:ok, view, _html} = live(build_conn(), "/control")

    html = render_click(view, "deploy_project", %{"project" => "alpha"})

    assert html =~ "Control Plane"
    assert html =~ "the deploy exited 2"
    assert html =~ "Error 2"
  end

  test "a timeout renders its reason in the row, with the deadline that kills the tree",
       %{registry: registry} do
    write_project(registry, "alpha", 4101, {@deploy_command, @deploy_directory, @declared_timeout})

    start_test_endpoint(
      project_status_client: client(%{4101 => :down}),
      project_status_timeout_ms: 50,
      deploy_runner: recording_runner({:error, :timeout})
    )

    {:ok, view, _html} = live(build_conn(), "/control")

    html = render_click(view, "deploy_project", %{"project" => "alpha"})

    assert_received {:deploy_ran, _executable, _args, run_opts}
    # The declared deadline is handed to `Shell.run/3`, whose expiry path reads the port's `:os_pid`
    # and calls `Shell.kill_tree/1` -- so the row says what the timeout did, and the tree is what died.
    assert run_opts[:timeout] == @declared_timeout

    assert html =~ "did not finish within #{@declared_timeout} ms"
    assert html =~ "killed the process tree"
  end

  test "a command that cannot start renders its reason in the row", %{registry: registry} do
    write_project(registry, "alpha", 4101, {@deploy_command, @deploy_directory, @declared_timeout})

    start_test_endpoint(
      project_status_client: client(%{4101 => :down}),
      project_status_timeout_ms: 50,
      deploy_runner: recording_runner({:error, {:not_found, "sh"}})
    )

    {:ok, view, _html} = live(build_conn(), "/control")

    html = render_click(view, "deploy_project", %{"project" => "alpha"})

    assert html =~ "Control Plane"
    assert html =~ "the deploy could not start"
    assert html =~ "sh"
  end

  test "a crafted deploy for a project the registry does not list is refused, and nothing runs",
       %{registry: registry} do
    write_project(registry, "alpha", 4101, {@deploy_command, @deploy_directory, @declared_timeout})

    start_test_endpoint(
      project_status_client: client(%{4101 => :down}),
      project_status_timeout_ms: 50,
      deploy_runner: never_used()
    )

    {:ok, view, _html} = live(build_conn(), "/control")

    # A name is looked up in the registry, never joined onto it: the same refusal a start makes, so a
    # crafted event cannot point a deploy at another file or at a project that does not exist.
    for name <- ["ghost", "../../symphony-projects/symphony", "C:/registry/alpha.md"] do
      html = render_click(view, "deploy_project", %{"project" => name})

      assert html =~ "Control Plane"
      assert html =~ "no project named"
    end

    refute_received {:deploy_ran, _, _, _}
  end

  test "a workflow that does not parse offers no deploy, and the row still renders", %{registry: registry} do
    File.write!(Path.join(registry, "broken.md"), "---\ndeploy: [\n---\n\nWork on broken.\n")

    start_test_endpoint(
      project_status_client: client(%{4101 => :down}),
      project_status_timeout_ms: 50,
      deploy_runner: never_used()
    )

    {:ok, view, html} = live(build_conn(), "/control")

    assert html =~ "Control Plane"
    refute has_element?(view, "button[phx-click='deploy_project'][phx-value-project='broken']")
    refute_received {:deploy_ran, _, _, _}
  end

  # ── helpers ──────────────────────────────────────────────────────────────────
  #
  # No socket is opened and no process is started by any test here: the state read and the deploy
  # runner both arrive as endpoint configuration, exactly like `:project_status_client` in
  # `ControlInstancesTest`.

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
  defp reply({:up, running, retrying, blocked}), do: {:ok, %{"counts" => %{"running" => running, "retrying" => retrying, "blocked" => blocked}}}

  defp refused, do: {:error, {:project_unreachable, %Mint.TransportError{reason: :econnrefused}}}

  defp port_of(url) do
    case Regex.run(~r/:(\d+)\//, url) do
      [_, port] -> {:ok, String.to_integer(port)}
      _none -> :error
    end
  end

  defp recording_runner(result) do
    test_pid = self()

    fn executable, args, opts ->
      send(test_pid, {:deploy_ran, executable, args, opts})
      result
    end
  end

  defp never_used, do: recording_runner(:never_used)

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

  # The project's own workflow file, deploy block included. Paths carry forward slashes: a Windows
  # backslash is an escape character inside a YAML double-quoted scalar, and this front matter is
  # parsed by the same parser an instance uses.
  defp write_project(dir, name, port, deploy) do
    block =
      case deploy do
        nil ->
          "deploy:\n"

        {command, directory, timeout} ->
          "deploy:\n  command: \"#{command}\"\n  working_directory: \"#{directory}\"\n  timeout_ms: #{timeout}\n"
      end

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
    #{block}---

    Work on #{name}.
    """)

    path
  end
end
