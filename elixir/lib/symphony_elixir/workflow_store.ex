defmodule SymphonyElixir.WorkflowStore do
  @moduledoc """
  Caches the last known good workflow and reloads it when `WORKFLOW.md` changes.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @poll_interval_ms 1_000

  defmodule State do
    @moduledoc false

    defstruct [:path, :stamp, :workflow, :settings, :endpoint_identity]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec current() :: {:ok, Workflow.loaded_workflow()} | {:error, term()}
  def current do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, :current)

      _ ->
        Workflow.load()
    end
  end

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, :settings)

      _ ->
        case load_state(Workflow.workflow_file_path()) do
          {:ok, %State{settings: settings}} -> {:ok, settings}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec force_reload() :: :ok | {:error, term()}
  def force_reload do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, :force_reload)

      _ ->
        case load_state(Workflow.workflow_file_path()) do
          {:ok, _state} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @impl true
  def init(_opts) do
    case load_state(Workflow.workflow_file_path()) do
      {:ok, state} ->
        schedule_poll()
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:current, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, {:ok, new_state.workflow}, new_state}

      {:error, _reason, new_state} ->
        {:reply, {:ok, new_state.workflow}, new_state}
    end
  end

  def handle_call(:force_reload, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call(:settings, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, {:ok, new_state.settings}, new_state}

      {:error, _reason, new_state} ->
        {:reply, {:ok, new_state.settings}, new_state}
    end
  end

  @impl true
  def handle_info(:poll, %State{} = state) do
    schedule_poll()

    case reload_state(state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _reason, new_state} -> {:noreply, new_state}
    end
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  defp reload_state(%State{} = state) do
    path = Workflow.workflow_file_path()

    if path != state.path do
      reload_path(path, state)
    else
      reload_current_path(path, state)
    end
  end

  defp reload_path(path, state) do
    case load_state(path) do
      {:ok, new_state} ->
        maybe_restart_endpoint(state, new_state)
        {:ok, new_state}

      {:error, reason} ->
        log_reload_error(path, reason)
        {:error, reason, state}
    end
  end

  defp reload_current_path(path, state) do
    case current_stamp(path) do
      {:ok, stamp} when stamp == state.stamp ->
        {:ok, state}

      {:ok, _stamp} ->
        reload_path(path, state)

      {:error, reason} ->
        log_reload_error(path, reason)
        {:error, reason, state}
    end
  end

  defp load_state(path) do
    with {:ok, workflow} <- Workflow.load(path),
         {:ok, settings} <- Schema.parse(workflow.config),
         :ok <- Config.validate_settings(settings),
         {:ok, stamp} <- current_stamp(path) do
      {:ok,
       %State{
         path: path,
         stamp: stamp,
         workflow: workflow,
         settings: settings,
         endpoint_identity: endpoint_identity(settings)
       }}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp current_stamp(path) when is_binary(path) do
    with {:ok, stat} <- File.stat(path, time: :posix),
         {:ok, content} <- File.read(path) do
      {:ok, {stat.mtime, stat.size, :erlang.phash2(content)}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp log_reload_error(path, reason) do
    Logger.error("Failed to reload workflow path=#{path} reason=#{inspect(reason)}; keeping last known good configuration")
  end

  # The endpoint reads `server.host` / `server.port` once, when HttpServer starts it, so a workflow
  # reload used to change nothing and say nothing -- the last runtime setting that could not be
  # reached without restarting the application. Bounce the endpoint instead: terminate_child plus
  # restart_child is the pair that works (measured: the port goes down and comes back), and the
  # restart re-reads the workflow.
  #
  # In a Task, not inline: terminate_child/2 is a synchronous call to the supervisor that kills a
  # sibling, so doing it here would block this store and race its own restart.
  defp maybe_restart_endpoint(%State{} = old, %State{} = new) do
    enabled? = Application.get_env(:symphony_elixir, :restart_endpoint_on_workflow_change, true)

    if enabled? and old.endpoint_identity != new.endpoint_identity do
      Logger.info(
        "Observability endpoint settings changed " <>
          "#{inspect(old.endpoint_identity)} -> #{inspect(new.endpoint_identity)}; restarting it"
      )

      _ = Task.start(&restart_endpoint/0)
    end

    :ok
  end

  # Everything the endpoint reads exactly once: the workflow's server block, the port override an
  # embedding application may set, and the mount path from the environment.
  defp endpoint_identity(settings) do
    {
      settings.server.port,
      settings.server.host,
      Application.get_env(:symphony_elixir, :server_port_override),
      SymphonyElixir.HttpServer.mount_path()
    }
  end

  # Extracted so the Task body stays flat, and so the two supervisor calls live together. "Not
  # found" (the endpoint is disabled now, or was never started) and "already running" both mean
  # the configuration just loaded is not the one being served; the caller logged the values.
  defp restart_endpoint do
    _ = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.HttpServer)

    case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.HttpServer) do
      {:ok, _pid} -> :ok
      {:error, :not_found} -> :ok
      {:error, :running} -> :ok
      other -> Logger.error("Observability endpoint restart failed: #{inspect(other)}")
    end
  end
end
