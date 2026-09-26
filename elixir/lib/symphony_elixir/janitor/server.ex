defmodule SymphonyElixir.Janitor.Server do
  @moduledoc """
  Runs the janitor inside Symphony's supervision tree, so it restarts itself and needs no external
  wrapper.

  ## Why it belongs here

  The janitor is host-side orchestration: it keeps the ticket repository in step with GitHub,
  regenerates the boards, and publishes work the agent has finished. Symphony *is* the host, so
  running it as a supervised child means

    * a crash restarts it (`:permanent`, under the application supervisor) instead of ending it
      silently, which is what a standalone script does;
    * it shares the workflow's configuration and the structured log;
    * there is no second process for a person to remember to start.

  It stays inert until a workflow asks for it: `janitor.enabled` defaults to `false`, and
  `SymphonyElixir.Application.start_runtime/0` only adds the child when it is true.

  ## Why the round is synchronous

  `handle_info/2` runs a whole round before returning. That is deliberate, and the interesting
  question is what bounds a round: **every external command already carries its own killable
  timeout** (`SymphonyElixir.Janitor.Shell.run/3`), so a round cannot hang -- it can only be slow,
  in proportion to the number of tickets and the number of `gh` calls they need. Running the round
  in a task would add a second deadline that duplicates the first, and a linked task that dies
  would take the server with it. Keep the deadline where the blocking actually happens.

  Nothing calls into this server, so blocking its mailbox for a round costs nothing.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Janitor

  @doc "Starts the janitor server. Options are for tests: `:round`, `:options`, `:interval_ms`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    settings = Config.settings!().janitor

    if Keyword.get(opts, :enabled, settings.enabled) do
      start(opts, settings)
    else
      # `:ignore` rather than omitting the child from the list: the child list is evaluated *before*
      # `Supervisor.start_link/2` runs, so at that moment `WorkflowStore` has not started and
      # `Config.settings!/0` cannot be trusted yet. Deciding here, inside the child, is both correct
      # and the idiomatic answer.
      :ignore
    end
  end

  defp start(opts, settings) do
    state = %{
      # Injected in tests so the scheduling can be checked without touching git or GitHub.
      round: Keyword.get(opts, :round, &Janitor.run_once/1),
      options: Keyword.get(opts, :options, janitor_options(settings)),
      interval_ms: Keyword.get(opts, :interval_ms, settings.interval_ms),
      first_delay_ms: Keyword.get(opts, :first_delay_ms, 5_000),
      timer: nil
    }

    Logger.info(
      "janitor: supervised, every #{state.interval_ms}ms, tickets=#{inspect(state.options[:tickets])}"
    )

    {:ok, schedule(state, state.first_delay_ms)}
  end

  @impl true
  def handle_info(:run, state) do
    run_round(state)
    {:noreply, schedule(%{state | timer: nil}, state.interval_ms)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{timer: timer}) do
    if is_reference(timer), do: Process.cancel_timer(timer)
    :ok
  end

  # A round that crashes must not take the server with it: the server's job is to keep running
  # rounds. An unexpected exit *does* restart the whole server through the supervisor, which is the
  # backstop, not the plan.
  defp run_round(state) do
    state.round.(state.options)
  rescue
    error -> Logger.error("janitor round crashed: #{Exception.message(error)}")
  catch
    kind, reason -> Logger.error("janitor round threw #{inspect(kind)}: #{inspect(reason)}")
  end

  defp schedule(state, delay_ms) do
    %{state | timer: Process.send_after(self(), :run, delay_ms)}
  end

  # Only the keys a workflow actually set are passed on; `SymphonyElixir.Janitor.config/1` fills in
  # this machine's defaults for the rest, so the two entry points (`mix janitor` and this server)
  # cannot drift apart.
  defp janitor_options(settings) do
    [
      tickets: settings.tickets_path,
      workspace_root: settings.workspace_root,
      repo: settings.issues_repo,
      tickets_repo: settings.tickets_repo,
      state_file: settings.state_file,
      interval_seconds: div(settings.interval_ms, 1_000)
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
  end
end
