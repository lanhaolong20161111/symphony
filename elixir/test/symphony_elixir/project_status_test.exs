defmodule SymphonyElixir.ProjectStatusTest do
  # async: false -- two tests move `:projects_dir` and `:workflow_file_path`, which are global.
  use ExUnit.Case, async: false

  alias SymphonyElixir.ProjectStatus

  @state_ok %{"counts" => %{"running" => 2, "retrying" => 1, "blocked" => 3}}

  describe "attach/2" do
    test "an instance that answered with counts is up, and the counts are its own" do
      [row] = ProjectStatus.attach([project("alpha", 4101)], client: fn _url -> {:ok, @state_ok} end)

      assert row.status.state == :up
      assert row.status.counts == %{running: 2, retrying: 1, blocked: 3}
      assert row.status.detail == nil
    end

    test "asks the declared port's own state route, and nothing else" do
      test_pid = self()

      client = fn url ->
        send(test_pid, {:asked, url})
        {:ok, @state_ok}
      end

      ProjectStatus.attach([project("alpha", 4101), project("beta", 4102)], client: client)

      assert_receive {:asked, "http://127.0.0.1:4101/api/v1/state"}
      assert_receive {:asked, "http://127.0.0.1:4102/api/v1/state"}
      refute_receive {:asked, _other}
    end

    test "a port with no URL from the registry is still asked at loopback" do
      test_pid = self()

      client = fn url ->
        send(test_pid, {:asked, url})
        {:ok, @state_ok}
      end

      [row] = ProjectStatus.attach([%{project("alpha", 4101) | url: nil}], client: client)

      assert_receive {:asked, "http://127.0.0.1:4101/api/v1/state"}
      assert row.status.state == :up
    end

    test "a refused connection is down -- nothing is listening on that port" do
      client = fn _url -> {:error, {:project_unreachable, %Mint.TransportError{reason: :econnrefused}}} end

      [row] = ProjectStatus.attach([project("alpha", 4101)], client: client)

      assert row.status.state == :down
      assert row.status.counts == nil
      assert row.status.detail =~ "econnrefused"
    end

    test "the same refusal classified from a plain reason, not a Mint struct" do
      client = fn _url -> {:error, {:project_unreachable, %{reason: :econnrefused}}} end

      [row] = ProjectStatus.attach([project("alpha", 4101)], client: client)

      assert row.status.state == :down
    end

    test "an instance that answers with an error status is unreachable, not down" do
      client = fn _url -> {:error, {:project_http, 503}} end

      [row] = ProjectStatus.attach([project("alpha", 4101)], client: client)

      assert row.status.state == :unreachable
      assert row.status.detail =~ "503"
    end

    test "a timeout is unreachable: something is there and did not answer" do
      client = fn _url -> {:error, {:project_unreachable, %{reason: :timeout}}} end

      [row] = ProjectStatus.attach([project("alpha", 4101)], client: client)

      assert row.status.state == :unreachable
      assert row.status.counts == nil
    end

    test "an instance that answered without counts is up, and no zeroes are invented" do
      client = fn _url -> {:ok, %{"error" => %{"code" => "snapshot_timeout"}}} end

      [row] = ProjectStatus.attach([project("alpha", 4101)], client: client)

      assert row.status.state == :up
      assert row.status.counts == nil
      assert row.status.detail == "snapshot_timeout"
    end

    test "a project that declares no port is not asked at all" do
      test_pid = self()

      client = fn url ->
        send(test_pid, {:asked, url})
        {:ok, @state_ok}
      end

      [row] = ProjectStatus.attach([project("noport", nil)], client: client)

      assert row.status.state == :no_port
      assert row.status.counts == nil
      refute_receive {:asked, _url}, 50
    end

    test "a client that raises does not raise the table" do
      client = fn _url -> raise "the stub exploded" end

      [row] = ProjectStatus.attach([project("alpha", 4101)], client: client)

      assert row.status.state == :unreachable
      assert row.status.detail =~ "the stub exploded"
    end

    test "a slow instance is cut off at the timeout instead of holding the table" do
      client = fn _url ->
        Process.sleep(300)
        {:ok, @state_ok}
      end

      [row] = ProjectStatus.attach([project("alpha", 4101)], client: client, timeout: 50)

      assert row.status.state == :unreachable
      assert row.status.detail == "no answer in time"
    end

    test "the rows are asked at once, not one after another" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      # Every probe blocks until all three have arrived. Asked one after another, the first would
      # wait for the other two forever and be killed at the timeout -- so this fails rather than
      # merely being slow, which is the property the page depends on.
      client = fn _url ->
        Agent.update(counter, &(&1 + 1))
        rendezvous(counter, 3)
        {:ok, @state_ok}
      end

      rows = [project("a", 4101), project("b", 4102), project("c", 4103)]
      result = ProjectStatus.attach(rows, client: client, timeout: 2_000)

      assert Enum.map(result, & &1.status.state) == [:up, :up, :up]
      assert Enum.map(result, & &1.name) == ["a", "b", "c"]
    end
  end

  describe "list/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "project-status-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      previous_dir = Application.get_env(:symphony_elixir, :projects_dir)
      previous_workflow = Application.get_env(:symphony_elixir, :workflow_file_path)
      Application.put_env(:symphony_elixir, :projects_dir, dir)

      on_exit(fn ->
        restore(:projects_dir, previous_dir)
        restore(:workflow_file_path, previous_workflow)
        File.rm_rf(dir)
      end)

      {:ok, dir: dir}
    end

    test "the row whose workflow file this instance was started with is marked as this instance",
         %{dir: dir} do
      path = write_project(dir, "alpha", 4111)
      Application.put_env(:symphony_elixir, :workflow_file_path, path)

      [row] = ProjectStatus.list(client: fn _url -> {:ok, @state_ok} end)

      assert row.name == "alpha"
      # The wildcard the registry reads through hands back forward slashes on Windows; `own?` is the
      # comparison that has to hold, not the string.
      assert Path.expand(row.path) == Path.expand(path)
      assert row.port == 4111
      assert row.own?
      assert row.status.state == :up
    end

    test "another project's row is not this instance", %{dir: dir} do
      write_project(dir, "alpha", 4111)

      [row] = ProjectStatus.list(client: fn _url -> {:ok, @state_ok} end)

      refute row.own?
    end

    test "an empty registry is an empty table, not an error" do
      assert ProjectStatus.attach([], client: fn _url -> {:ok, @state_ok} end) == []
      assert ProjectStatus.list() == []
    end
  end

  # All probes wait here until the last one arrives.
  defp rendezvous(counter, expected) do
    if Agent.get(counter, & &1) < expected do
      Process.sleep(5)
      rendezvous(counter, expected)
    end
  end

  defp restore(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp project(name, port) do
    %{
      name: name,
      path: "C:/registry/#{name}.md",
      port: port,
      url: if(is_integer(port), do: "http://127.0.0.1:#{port}")
    }
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
