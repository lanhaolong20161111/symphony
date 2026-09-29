defmodule SymphonyElixirWeb.ControlLiveTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SymphonyElixirWeb.Endpoint

  # A stand-in for the orchestrator: it answers what `Presenter` asks for, and it remembers whether it
  # was paused so the page's badge is read back from the orchestrator rather than from the click.
  defmodule StubOrchestrator do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end

    def handle_call(:pause, _from, state) do
      state = put_paused(state, true)
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:resume, _from, state) do
      state = put_paused(state, false)
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    defp put_paused(state, paused) do
      Keyword.update!(state, :snapshot, &Map.put(&1, :paused, paused))
    end
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "the control page renders the hub, the runtime switch and the moved panels" do
    start_test_endpoint(orchestrator: start_orchestrator(), snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/control")

    assert html =~ "Control Plane"

    # The hub: the pages that were reachable from the dashboard's navigation before it was restored.
    assert html =~ ~s(href="/settings")
    assert html =~ ~s(href="/tasks")
    assert html =~ ~s(href="/projects/new")
    assert html =~ ~s(href="/control/tickets")
    assert html =~ ~s(href="/")

    # The moved widgets.
    assert html =~ "Agent usage (from the recorder)"
    assert html =~ "Context windows (running sessions)"
    assert html =~ ~s(phx-click="pause")
    assert html =~ ~s(phx-click="resume")
    assert html =~ "state-badge-active"

    # The backend / adapter / model route and the context window of the running session, which the
    # dashboard no longer shows.
    assert html =~ "acp / dsh / deepseek-v4"
    assert html =~ "42%"
  end

  test "pause and resume show the state the orchestrator reports" do
    start_test_endpoint(orchestrator: start_orchestrator(), snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/control")
    assert html =~ "state-badge-active"

    view |> element("button[phx-click=pause]") |> render_click()
    assert view |> element("#runtime-state") |> render() =~ "Paused"

    view |> element("button[phx-click=resume]") |> render_click()
    assert view |> element("#runtime-state") |> render() =~ "Running"
  end

  defp start_orchestrator do
    name = Module.concat(__MODULE__, :"Orchestrator#{System.unique_integer([:positive])}")
    start_supervised!({StubOrchestrator, name: name, snapshot: snapshot()})
    name
  end

  defp snapshot do
    %{
      running: [
        %{
          issue_id: "issue-1",
          identifier: "SYM-1",
          issue_url: "https://example.org/issues/1",
          state: "In Progress",
          session_id: "thread-1",
          turn_count: 3,
          last_codex_event: :notification,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          codex_input_tokens: 10,
          codex_output_tokens: 12,
          codex_total_tokens: 22,
          backend: "acp",
          adapter: "dsh",
          model: "deepseek-v4",
          context: %{used: 42_000, size: 100_000, percent: 42},
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [],
      blocked: [],
      codex_totals: %{input_tokens: 10, output_tokens: 12, total_tokens: 22, seconds_running: 5.0},
      rate_limits: %{}
    }
  end

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
