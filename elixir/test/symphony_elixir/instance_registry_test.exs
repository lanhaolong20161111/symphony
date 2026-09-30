defmodule SymphonyElixir.InstanceRegistryTest do
  # async: false -- these tests move `:projects_dir`, `:instances_file` and `:instance_logs_root`,
  # which are global, and they write a state file.
  use ExUnit.Case, async: false

  alias SymphonyElixir.{CLI, InstanceRegistry}

  setup do
    dir = Path.join(System.tmp_dir!(), "instance-registry-#{System.unique_integer([:positive])}")
    registry = Path.join(dir, "registry")
    File.mkdir_p!(registry)

    previous = %{
      projects_dir: Application.get_env(:symphony_elixir, :projects_dir),
      instances_file: Application.get_env(:symphony_elixir, :instances_file),
      logs_root: Application.get_env(:symphony_elixir, :instance_logs_root)
    }

    Application.put_env(:symphony_elixir, :projects_dir, registry)
    Application.put_env(:symphony_elixir, :instances_file, Path.join(dir, "instances.json"))
    Application.put_env(:symphony_elixir, :instance_logs_root, Path.join(dir, "logs"))

    on_exit(fn ->
      restore(:projects_dir, previous.projects_dir)
      restore(:instances_file, previous.instances_file)
      restore(:instance_logs_root, previous.logs_root)
      File.rm_rf(dir)
    end)

    {:ok, dir: dir, registry: registry}
  end

  # ── port allocation: a pure decision over an injected "is it held" ───────────

  describe "allocate/1" do
    test "a declared port nothing holds is the port, even outside the hub's range" do
      assert InstanceRegistry.allocate(declared: 4321, taken: [], held?: never_held()) == {:ok, 4321}

      assert InstanceRegistry.allocate(declared: 4321, taken: [4001, 4002], held?: held_on([4001])) ==
               {:ok, 4321}
    end

    test "a declared port that is held gives way to the first free one from 4001" do
      assert InstanceRegistry.allocate(declared: 4101, taken: [], held?: held_on([4101])) == {:ok, 4001}
    end

    test "a declared port the hub itself already holds gives way too" do
      assert InstanceRegistry.allocate(declared: 4002, taken: [4002], held?: never_held()) == {:ok, 4001}
    end

    test "the range is scanned upward, skipping everything held" do
      assert InstanceRegistry.allocate(held?: held_on([4001, 4002, 4004])) == {:ok, 4003}
      assert InstanceRegistry.allocate(taken: [4001, 4003], held?: held_on([4002])) == {:ok, 4004}
    end

    test "a project that declares no port gets the first free one from 4001" do
      assert InstanceRegistry.allocate(declared: nil, held?: never_held()) == {:ok, 4001}
    end

    test "a range with nothing left is a refusal, not a guess" do
      taken = Enum.to_list(4001..4099)

      assert InstanceRegistry.allocate(taken: taken, held?: never_held()) == {:error, :no_free_port}
    end

    test "the declared port is asked about, not assumed" do
      test_pid = self()

      held? = fn port ->
        send(test_pid, {:asked, port})
        false
      end

      assert {:ok, 4101} = InstanceRegistry.allocate(declared: 4101, held?: held?)
      assert_receive {:asked, 4101}
      # Nothing else was asked about: a declared port that is free costs exactly one check.
      refute_receive {:asked, _port}
    end

    test "a nonsense declared port is not honoured" do
      for nonsense <- [0, -1, 70_000, "4001", nil] do
        assert InstanceRegistry.allocate(declared: nonsense, held?: never_held()) == {:ok, 4001}
      end
    end
  end

  # ── start ────────────────────────────────────────────────────────────────────

  describe "start_instance/2" do
    test "hands the launcher the registry's own file, the assigned port and this instance's logs root",
         %{registry: registry} do
      write_project(registry, "alpha", 4101)
      test_pid = self()

      launcher = fn spec ->
        send(test_pid, {:launched, spec})
        {:ok, 4242}
      end

      assert {:ok, record} =
               InstanceRegistry.start_instance("alpha",
                 launcher: launcher,
                 held?: never_held(),
                 alive?: alive_none()
               )

      assert record.pid == 4242
      assert record.port == 4101
      assert Path.expand(record.workflow) == Path.expand(Path.join(registry, "alpha.md"))
      assert Path.expand(record.logs_root) == Path.expand(InstanceRegistry.logs_root("alpha"))
      assert record.started_at =~ "T"

      assert_receive {:launched, spec}
      assert spec.port == 4101
      assert Path.expand(spec.workflow) == Path.expand(Path.join(registry, "alpha.md"))
      assert Path.expand(spec.logs_root) == Path.expand(InstanceRegistry.logs_root("alpha"))

      assert %{"alpha" => stored} = InstanceRegistry.records()
      assert stored.pid == 4242
      assert stored.port == 4101
    end

    test "a declared port that is held gets the hub's own assignment instead", %{registry: registry} do
      write_project(registry, "alpha", 4101)
      write_project(registry, "beta", 4001)

      assert {:ok, record} =
               InstanceRegistry.start_instance("beta",
                 launcher: fn _spec -> {:ok, 4242} end,
                 held?: held_on([4001]),
                 alive?: alive_none()
               )

      assert record.port == 4002
    end

    test "the argv is the one the CLI documents, switch included" do
      spec = %{project: "alpha", workflow: "C:/registry/alpha.md", port: 4003, logs_root: "C:/logs/alpha"}

      {executable, args} =
        InstanceRegistry.command(spec, escript: "escript", script: "C:/build/bin/symphony")

      assert executable == "escript"

      assert args == [
               "C:/build/bin/symphony",
               "C:/registry/alpha.md",
               "--i-understand-that-this-will-be-running-without-the-usual-guardrails",
               "--logs-root",
               "C:/logs/alpha",
               "--port",
               "4003"
             ]

      # The acknowledgement is the CLI's own string rather than a copy of it: one character out and
      # every instance would refuse to start.
      assert CLI.acknowledgement_switch() in args
    end

    test "refuses a name the registry does not list", %{registry: registry} do
      write_project(registry, "alpha", 4101)

      assert {:error, reason} = start("elsewhere")

      assert reason =~ "no project named elsewhere"
      assert reason =~ "in the registry"
      assert reason =~ "never a path handed to it"
    end

    test "refuses a workflow path handed in where a name belongs", %{registry: registry, dir: dir} do
      outside = Path.join(dir, "outside.md")
      write_project(registry, "alpha", 4101)
      File.write!(outside, File.read!(Path.join(registry, "alpha.md")))

      # The file exists and validates; it is still refused, because the registry is the only source
      # of a workflow file and a caller -- a browser event included -- names a project, not a path.
      assert {:error, reason} = start(outside)

      assert reason =~ "no project named"
    end

    test "refuses a workflow that does not validate", %{registry: registry} do
      File.write!(Path.join(registry, "broken.md"), """
      ---
      server:
        host: 127.0.0.1
        port: not-a-number
      tracker:
        kind: file
        provider:
          path: C:/q/broken
      workspace:
        root: C:/ws/broken
      agent:
        backend: codex
      ---

      Work on broken.
      """)

      assert {:error, reason} = start("broken")

      assert reason =~ "does not validate"
      assert reason =~ "broken.md"
    end

    test "refuses a workflow with no prompt body", %{registry: registry} do
      File.write!(Path.join(registry, "silent.md"), project_body("silent", 4105, ""))

      assert {:error, reason} = start("silent")

      assert reason =~ "prompt body is empty"
    end

    test "refuses a workflow whose prompt kept an unrendered variable", %{registry: registry} do
      File.write!(
        Path.join(registry, "braces.md"),
        project_body("braces", 4106, "Work on {{ issue.identifier }} but never close")
      )

      assert {:error, reason} = start("braces")

      assert reason =~ "unrendered"
    end

    test "refuses a project that would listen outside loopback", %{registry: registry} do
      write_project(registry, "wide", 4107, host: "0.0.0.0")

      assert {:error, reason} = start("wide")

      assert reason =~ "server.host"
      assert reason =~ "loopback"
    end

    test "refuses a project the hub is already running", %{registry: registry} do
      write_project(registry, "alpha", 4101)
      seed(%{"alpha" => record("alpha", 4101, 4242)})

      assert {:error, reason} =
               InstanceRegistry.start_instance("alpha",
                 launcher: no_launch(),
                 held?: never_held(),
                 alive?: alive_all()
               )

      assert reason =~ "already running under this hub's control"
      assert reason =~ "4242"
      refute_receive {:launched, _spec}
    end

    test "a stale record is dropped and the start goes ahead", %{registry: registry} do
      write_project(registry, "alpha", 4101)
      seed(%{"alpha" => record("alpha", 4101, 4242)})

      assert {:ok, record} =
               InstanceRegistry.start_instance("alpha",
                 launcher: fn _spec -> {:ok, 5555} end,
                 held?: never_held(),
                 alive?: alive_none()
               )

      assert record.pid == 5555
      assert %{"alpha" => stored} = InstanceRegistry.records()
      assert stored.pid == 5555
    end

    test "refuses when no port can be found", %{registry: registry} do
      write_project(registry, "alpha", 4101)

      assert {:error, reason} =
               InstanceRegistry.start_instance("alpha",
                 launcher: no_launch(),
                 held?: fn _port -> true end,
                 alive?: alive_none()
               )

      assert reason =~ "no free port"
      assert reason =~ "4101"
      refute_receive {:launched, _spec}
    end

    test "a launcher that fails is reported and records nothing", %{registry: registry} do
      write_project(registry, "alpha", 4101)

      assert {:error, reason} =
               InstanceRegistry.start_instance("alpha",
                 launcher: fn _spec -> {:error, {:launch_raised, "escript not found"}} end,
                 held?: never_held(),
                 alive?: alive_none()
               )

      assert reason =~ "could not start alpha"
      assert reason =~ "escript not found"
      assert InstanceRegistry.records() == %{}
    end

    test "a launcher that answers something else is refused rather than recorded", %{registry: registry} do
      write_project(registry, "alpha", 4101)

      assert {:error, reason} =
               InstanceRegistry.start_instance("alpha",
                 launcher: fn _spec -> :started_ok end,
                 held?: never_held(),
                 alive?: alive_none()
               )

      assert reason =~ "instead of a pid"
      assert InstanceRegistry.records() == %{}
    end

    test "a process that cannot be recorded is stopped again", %{registry: registry, dir: dir} do
      write_project(registry, "alpha", 4101)

      # A state file whose parent is a *file*: the record cannot be written at all.
      blocked = Path.join(dir, "blocked")
      File.write!(blocked, "not a directory")
      Application.put_env(:symphony_elixir, :instances_file, Path.join(blocked, "instances.json"))

      test_pid = self()

      kill = fn pid ->
        send(test_pid, {:killed, pid})
        :ok
      end

      assert {:error, reason} =
               InstanceRegistry.start_instance("alpha",
                 launcher: fn _spec -> {:ok, 4242} end,
                 held?: never_held(),
                 alive?: alive_none(),
                 kill: kill
               )

      assert reason =~ "could not be recorded"
      assert reason =~ "stopped again"
      assert_receive {:killed, 4242}
    end
  end

  # ── stop ─────────────────────────────────────────────────────────────────────

  describe "stop_instance/2" do
    test "refuses the instance this hub is running in, by port" do
      seed(%{"self" => record("self", 4001, 111)})

      assert {:error, reason} =
               InstanceRegistry.stop_instance("self",
                 own_port: 4001,
                 own_pid: 999,
                 kill: no_kill(),
                 alive?: alive_all()
               )

      assert reason =~ "serving this page"
      assert reason =~ "never stops the instance it is running in"
      refute_receive {:killed, _pid}
      assert Map.has_key?(InstanceRegistry.records(), "self")
    end

    test "refuses the instance this hub is running in, by pid" do
      seed(%{"self" => record("self", 4002, 111)})

      assert {:error, reason} =
               InstanceRegistry.stop_instance("self",
                 own_port: 4001,
                 own_pid: 111,
                 kill: no_kill(),
                 alive?: alive_all()
               )

      assert reason =~ "this hub's own process"
      refute_receive {:killed, _pid}
    end

    test "refuses a pid it did not start" do
      seed(%{"mine" => record("mine", 4002, 222)})

      assert {:error, reason} =
               InstanceRegistry.stop_instance("foreign",
                 own_port: 4001,
                 own_pid: 999,
                 kill: no_kill(),
                 alive?: alive_all()
               )

      assert reason =~ "no record of starting this project"
      assert reason =~ "no pid to stop"
      refute_receive {:killed, _pid}
    end

    test "kills exactly the recorded pid, and only the recorded pid" do
      seed(%{"alpha" => record("alpha", 4101, 4242), "beta" => record("beta", 4102, 5252)})
      test_pid = self()

      kill = fn pid ->
        send(test_pid, {:killed, pid})
        :ok
      end

      assert :ok =
               InstanceRegistry.stop_instance("alpha",
                 own_port: 4001,
                 own_pid: 999,
                 kill: kill,
                 alive?: alive_all()
               )

      assert_receive {:killed, 4242}
      refute_receive {:killed, 5252}

      # The record is gone; the other project's is not.
      assert Map.keys(InstanceRegistry.records()) == ["beta"]
    end

    test "a pid that is already gone drops the stale record and kills nothing" do
      seed(%{"alpha" => record("alpha", 4101, 4242)})

      assert {:error, reason} =
               InstanceRegistry.stop_instance("alpha",
                 own_port: 4001,
                 own_pid: 999,
                 kill: no_kill(),
                 alive?: alive_none()
               )

      assert reason =~ "not running any more"
      assert reason =~ "stale record was dropped"
      refute_receive {:killed, _pid}
      assert InstanceRegistry.records() == %{}
    end

    test "a kill that fails keeps the record: the process may still be there" do
      seed(%{"alpha" => record("alpha", 4101, 4242)})

      kill = fn _pid -> {:error, {:kill_exit, 128, "ERROR: The process not found."}} end

      assert {:error, reason} =
               InstanceRegistry.stop_instance("alpha",
                 own_port: 4001,
                 own_pid: 999,
                 kill: kill,
                 alive?: alive_all()
               )

      assert reason =~ "stopping alpha (pid 4242) failed"
      assert Map.has_key?(InstanceRegistry.records(), "alpha")
    end

    test "refuses a record that carries no pid at all" do
      assert {:error, reason} = InstanceRegistry.stoppable?(%{project: "alpha", port: 4101, pid: nil})

      assert reason =~ "carries no pid"
    end
  end

  # ── boot ─────────────────────────────────────────────────────────────────────

  describe "reconcile/1" do
    test "drops a record whose pid is gone and keeps one whose pid is alive" do
      seed(%{"alive" => record("alive", 4101, 111), "stale" => record("stale", 4102, 222)})

      assert %{kept: ["alive"], dropped: ["stale"]} =
               InstanceRegistry.reconcile(own_port: 4001, alive?: fn pid -> pid == 111 end)

      # Written back: the file no longer mentions the stale one.
      assert Map.keys(InstanceRegistry.records()) == ["alive"]
      assert %{"alive" => %{pid: 111}} = InstanceRegistry.records()
    end

    test "the state file is left alone when nothing was dropped" do
      assert %{kept: [], dropped: []} = InstanceRegistry.reconcile(own_port: 4001, alive?: alive_all())
      refute File.exists?(InstanceRegistry.file())

      seed(%{"alpha" => record("alpha", 4101, 111)})
      before = File.read!(InstanceRegistry.file())

      assert %{kept: ["alpha"], dropped: []} =
               InstanceRegistry.reconcile(own_port: 4001, alive?: fn _pid -> true end)

      assert File.read!(InstanceRegistry.file()) == before
    end

    test "never raises, whatever the state file holds" do
      File.mkdir_p!(Path.dirname(InstanceRegistry.file()))
      File.write!(InstanceRegistry.file(), "{ this is not json")

      assert %{kept: [], dropped: []} = InstanceRegistry.reconcile(own_port: 4001, alive?: alive_all())
    end

    test "a record with no pid or no port is not a record" do
      File.mkdir_p!(Path.dirname(InstanceRegistry.file()))

      File.write!(InstanceRegistry.file(), """
      {"version": 1, "instances": [
        {"project": "nopid", "workflow": "C:/registry/nopid.md", "port": 4101, "logs_root": "C:/logs"},
        {"project": "ok", "workflow": "C:/registry/ok.md", "port": 4102, "pid": 12, "logs_root": "C:/logs"},
        "not even an object"
      ]}
      """)

      assert Map.keys(InstanceRegistry.records()) == ["ok"]
    end
  end

  # ── what the page asks ───────────────────────────────────────────────────────

  describe "action/1" do
    test "the instance this page is served by never offers a stop" do
      row = %{name: "self", own?: true, hub: %{pid: 1, port: 4001}, status: %{state: :up}}

      assert InstanceRegistry.action(row) == :own
    end

    test "a recorded project answering on its assigned port offers a stop" do
      row = %{name: "alpha", own?: false, hub: %{pid: 4242, port: 4101}, status: %{state: :up}}

      assert InstanceRegistry.action(row) == :stop
    end

    test "something answering that the hub did not start is not the hub's to stop" do
      for state <- [:up, :unreachable] do
        row = %{name: "alpha", own?: false, hub: nil, status: %{state: state}}
        assert InstanceRegistry.action(row) == :observe
      end
    end

    test "nothing answering offers a start, stale record or not" do
      for state <- [:down, :no_port] do
        assert InstanceRegistry.action(%{name: "a", own?: false, hub: nil, status: %{state: state}}) == :start

        assert InstanceRegistry.action(%{
                 name: "a",
                 own?: false,
                 hub: %{pid: 1, port: 4001},
                 status: %{state: state}
               }) == :start
      end
    end

    test "a row with no state at all is a start, not a guess" do
      assert InstanceRegistry.action(%{name: "a", own?: false, hub: nil}) == :start
    end
  end

  describe "overlay/2" do
    test "a recorded project is probed on the port the hub assigned, and the declared one is kept" do
      rows = [%{name: "alpha", port: 4001, url: "http://127.0.0.1:4001", own?: false}]
      records = %{"alpha" => record("alpha", 4002, 4242)}

      assert [row] = InstanceRegistry.overlay(rows, records)

      assert row.port == 4002
      assert row.url == "http://127.0.0.1:4002"
      assert row.declared_port == 4001

      assert row.hub == %{
               pid: 4242,
               port: 4002,
               logs_root: "C:/logs/alpha",
               started_at: "2026-05-01T09:12:44Z"
             }
    end

    test "a project the hub never started is left exactly where its file says" do
      rows = [%{name: "alpha", port: 4001, url: "http://127.0.0.1:4001", own?: false}]

      assert [row] = InstanceRegistry.overlay(rows, %{})

      assert row.port == 4001
      assert row.declared_port == 4001
      assert row.hub == nil
    end
  end

  describe "the state file" do
    test "round-trips, sorted by project" do
      records = %{"zeta" => record("zeta", 4102, 22), "alpha" => record("alpha", 4101, 11)}

      assert :ok = InstanceRegistry.write(records, InstanceRegistry.file())

      assert File.read!(InstanceRegistry.file()) =~ ~s("project":"alpha")
      assert InstanceRegistry.records() == records
    end

    test "a missing file is an empty table, not an error" do
      refute File.exists?(InstanceRegistry.file())
      assert InstanceRegistry.records() == %{}
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────────
  #
  # No test in this file spawns a process, opens a socket or kills anything: the launcher, the
  # "is it held" check, the "is it alive" check and the kill are all injected. The single exception
  # is the test of `held?/1` itself, which is the function under test there.

  defp start(name) do
    InstanceRegistry.start_instance(name,
      launcher: no_launch(),
      held?: never_held(),
      alive?: alive_none()
    )
  end

  defp no_launch, do: fn spec -> send(self(), {:launched, spec}) end
  defp no_kill, do: fn pid -> send(self(), {:killed, pid}) end

  defp never_held, do: fn _port -> false end
  defp held_on(ports), do: fn port -> port in ports end
  defp alive_all, do: fn _pid -> true end
  defp alive_none, do: fn _pid -> false end

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

  defp write_project(dir, name, port, opts \\ []) do
    File.write!(Path.join(dir, "#{name}.md"), project_body(name, port, "Work on #{name}.", opts))
  end

  defp project_body(name, port, prompt, opts \\ []) do
    """
    ---
    server:
      host: #{Keyword.get(opts, :host, "127.0.0.1")}
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

    #{prompt}
    """
  end
end
