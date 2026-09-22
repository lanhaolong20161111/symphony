defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Tracker
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec pause(Conn.t(), map()) :: Conn.t()
  def pause(conn, _params), do: control(conn, :pause)

  @spec resume(Conn.t(), map()) :: Conn.t()
  def resume(conn, _params), do: control(conn, :resume)

  defp control(conn, action) do
    case apply(orchestrator(), action, [orchestrator()]) do
      :unavailable ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")

      payload ->
        conn
        |> put_status(202)
        |> json(payload)
    end
  end

  # The mediated tool route. The request body is the tool's arguments.
  #
  # Closed unless the workflow turns it on: this hands an agent the tracker's provider-native tools,
  # which is a decision rather than a default. The tools run here, with Symphony's own credentials --
  # the caller sends a name and arguments and never sees the tracker token.
  @spec tool(Conn.t(), map()) :: Conn.t()
  def tool(conn, %{"tool" => tool}) do
    if tracker_tools_enabled?() do
      run_tool(conn, tool, conn.body_params)
    else
      error_response(conn, 404, "tracker_tools_disabled", "Tracker tools are not enabled")
    end
  end

  defp run_tool(conn, tool, arguments) when is_map(arguments) do
    case Tracker.bind_agent_tools() do
      %{tool_specs: []} ->
        error_response(conn, 404, "no_agent_tools", "The configured tracker exposes no agent tools")

      binding ->
        json(conn, Tracker.execute_bound_agent_tool(binding, tool, arguments, []))
    end
  rescue
    error -> error_response(conn, 400, "tool_failed", Exception.message(error))
  end

  defp run_tool(conn, _tool, _arguments) do
    error_response(
      conn,
      400,
      "invalid_arguments",
      "The request body must be a JSON object of tool arguments"
    )
  end

  # Fail closed: a configuration that cannot be read leaves the tools off, and says so.
  defp tracker_tools_enabled? do
    SymphonyElixir.Config.settings!().server.tracker_tools == true
  rescue
    _error -> false
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
