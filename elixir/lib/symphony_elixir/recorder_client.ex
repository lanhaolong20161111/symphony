defmodule SymphonyElixir.RecorderClient do
  @moduledoc """
  Read-only access to the standalone recorder (loopback, port 4010 by default).

  Two features need the same thing -- "what sessions exist" -- so the HTTP call lives here rather
  than in each: the handoff packs (which session belongs to a ticket) and the usage panel.

  ## Why a usage panel reads the recorder at all

  It is the only place these numbers exist for ACP agents. ACP's `usage_update` notification carries
  a context-window `used`/`size` pair and nothing else, so Symphony's own token totals are **always
  zero** for `backend: acp` -- that is a shape to live with, not a bug to fix. The recorder reads
  each agent's own rollout files, so it has the real `tokensUsed` and context windows.
  """

  @default_url "http://127.0.0.1:4010"
  @timeout_ms 8_000

  @doc "The recorder's base URL. `config :symphony_elixir, :recorder_upstream` to move it."
  @spec base_url() :: String.t()
  def base_url, do: Application.get_env(:symphony_elixir, :recorder_upstream, @default_url)

  @spec sessions() :: {:ok, [map()]} | {:error, term()}
  def sessions do
    case Req.get(base_url() <> "/api/sessions", receive_timeout: @timeout_ms) do
      {:ok, %{status: 200, body: %{"sessions" => list}}} when is_list(list) -> {:ok, list}
      {:ok, %{status: status}} -> {:error, {:recorder_http, status}}
      {:error, reason} -> {:error, {:recorder_unreachable, reason}}
    end
  rescue
    error -> {:error, {:recorder_unreachable, Exception.message(error)}}
  end

  @spec handoff_pack(String.t()) :: {:ok, String.t()} | {:error, term()}
  def handoff_pack(session_key) when is_binary(session_key) do
    url = base_url() <> "/api/sessions/" <> URI.encode_www_form(session_key) <> "/handoff"

    case Req.get(url, receive_timeout: @timeout_ms) do
      {:ok, %{status: 200, body: body}} when is_binary(body) and body != "" -> {:ok, body}
      {:ok, %{status: 200}} -> {:error, :empty_pack}
      {:ok, %{status: status}} -> {:error, {:recorder_http, status}}
      {:error, reason} -> {:error, {:recorder_unreachable, reason}}
    end
  rescue
    error -> {:error, {:recorder_unreachable, Exception.message(error)}}
  end

  @doc """
  Token use per agent, as the recorder sees it.

  Aggregated rather than listed: the question this answers is "what has WorkBuddy cost me", and 368
  individual sessions do not answer it. `context` is the largest context window seen among that
  agent's sessions, which is the thing that explains why a session had to be handed off.
  """
  @spec usage() :: {:ok, [map()]} | {:error, term()}
  def usage do
    with {:ok, sessions} <- sessions(), do: {:ok, usage_from(sessions)}
  end

  @doc """
  Aggregates a session list by agent.

  Separate from `usage/0` so it can be asserted without a recorder running: the arithmetic is the
  part worth pinning, and it is the part that runs against whatever the recorder happens to return.
  """
  @spec usage_from([map()]) :: [map()]
  def usage_from(sessions) when is_list(sessions) do
    sessions
    |> Enum.group_by(&(&1["agent"] || "unknown"))
    |> Enum.map(fn {agent, group} ->
      %{
        agent: agent,
        sessions: length(group),
        tokens: group |> Enum.map(&number(&1["tokensUsed"])) |> Enum.sum(),
        context: group |> Enum.map(&context_window/1) |> Enum.max(fn -> 0 end)
      }
    end)
    |> Enum.sort_by(& &1.tokens, :desc)
  end

  defp number(value) when is_integer(value), do: value
  defp number(value) when is_float(value), do: trunc(value)
  defp number(_value), do: 0

  defp context_window(session) do
    case session["contextWindows"] do
      list when is_list(list) -> list |> Enum.filter(&is_integer/1) |> Enum.max(fn -> 0 end)
      _ -> 0
    end
  end
end
