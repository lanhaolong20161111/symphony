defmodule SymphonyElixirWeb.TaskApiController do
  @moduledoc """
  JSON API for task management: creating tasks (which become GitHub issues +
  ticket files), listing tickets, and updating ticket state.

  Sits on top of `SymphonyElixir.TaskComposer`, which is the middleware that
  converts form input into GitHub issues and ticket files. Like the rest of
  Symphony's API, this is loopback-only with no auth.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.TaskComposer

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, _params) do
    case TaskComposer.list_tickets() do
      {:ok, tickets} ->
        json(conn, %{tickets: tickets})

      {:error, reason} ->
        error_response(conn, 500, "list_failed", "Cannot list tickets: #{inspect(reason)}")
    end
  end

  @spec create(Conn.t(), map()) :: Conn.t()
  def create(conn, params) do
    attrs = %{
      title: params["title"],
      description: params["description"],
      validation: params["validation"],
      blocked_by: params["blocked_by"],
      priority: params["priority"]
    }

    attrs = clean_attrs(attrs)

    case TaskComposer.create_task(attrs) do
      {:ok, result} ->
        conn
        |> put_status(201)
        |> json(result)

      {:error, :missing_title} ->
        error_response(conn, 400, "missing_title", "Title is required")

      {:error, reason} ->
        error_response(conn, 500, "create_failed", "Cannot create task: #{inspect(reason)}")
    end
  end

  @spec update(Conn.t(), map()) :: Conn.t()
  def update(conn, %{"id" => ticket_id, "state" => new_state}) do
    case TaskComposer.update_state(ticket_id, new_state) do
      {:ok, ticket} ->
        json(conn, ticket)

      {:error, reason} ->
        error_response(conn, 500, "update_failed", "Cannot update ticket: #{inspect(reason)}")
    end
  end

  def update(conn, %{"id" => _ticket_id}) do
    error_response(conn, 400, "missing_state", "State is required")
  end

  defp clean_attrs(attrs) do
    attrs
    |> Map.update!(:title, &trim_or_nil/1)
    |> Map.update!(:description, &trim_or_nil/1)
    |> Map.update!(:validation, &trim_or_nil/1)
    |> Map.update!(:blocked_by, &normalize_blocked_by/1)
    |> Map.update!(:priority, &trim_or_nil/1)
  end

  defp trim_or_nil(nil), do: nil
  defp trim_or_nil(value) when is_binary(value), do: String.trim(value)
  defp trim_or_nil(value), do: to_string(value) |> String.trim()

  defp normalize_blocked_by(nil), do: []
  defp normalize_blocked_by(value) when is_list(value), do: Enum.map(value, &to_string/1) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  defp normalize_blocked_by(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_blocked_by(_), do: []

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
