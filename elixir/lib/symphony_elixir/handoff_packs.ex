defmodule SymphonyElixir.HandoffPacks do
  @moduledoc """
  Copies a ticket's 续会话包 (handoff pack) from the recorder into the ticket file, so the **next
  agent to pick that ticket up** starts with the previous one's context.

  ## Why the ticket file

  The ticket body is exactly what the prompt template renders as `{{ issue.description }}` (see the
  body of `WORKFLOW.file.md`), so writing it there means:

    * no change to how prompts are built;
    * no cross-application call while a run is starting;
    * it survives a restart;
    * the facts about a ticket stay in one place -- the ticket.

  ## Why "every in-flight ticket", not "a session"

  Switching vendor changes **who does the work**; the context should follow the **work**. At the
  moment of a switch there may be no session running, or a dozen, so "fetch a session's pack" has
  no definition. "Give every in-flight ticket a pack for its own workspace" does: the ticket's id
  is its workspace directory name (`Workspace.create_for_issue/2`).

  ## Failure is reported, never swallowed

  A recorder that is down or misconfigured returns an error and the caller says so. The whole value
  of this action is that the next agent really does see the context; failing quietly would be worse
  than not doing it at all.
  """

  require Logger

  alias SymphonyElixir.{Config, TaskComposer}

  @section_heading "续接上下文"
  @begin_marker "<!-- symphony:handoff -->"
  @end_marker "<!-- /symphony:handoff -->"
  @default_recorder_url "http://127.0.0.1:4010"
  @http_timeout_ms 8_000
  # A `ready` ticket has not run yet, so it has no context to carry; these are the states where
  # work has actually happened.
  @in_flight_states ~w(in-progress in-review)

  @typedoc "What one ticket's attach did."
  @type attached :: %{id: String.t(), session: String.t(), bytes: pos_integer()}

  @typedoc "A ticket that was left alone, and why."
  @type skipped :: %{id: String.t(), reason: String.t()}

  @typedoc "A ticket whose attach failed."
  @type failed :: %{id: String.t(), reason: String.t()}

  @doc """
  Writes `ticket_id`'s handoff pack into its ticket file, replacing any previous one.

  The pack comes from the most recently active recorder session whose `cwd` is this ticket's
  workspace. Returns `{:ok, %{session, bytes}}` or `{:error, reason}`.
  """
  @spec attach(String.t()) :: {:ok, map()} | {:error, term()}
  def attach(ticket_id) when is_binary(ticket_id) do
    with {:ok, session} <- newest_session(ticket_id),
         {:ok, pack} <- fetch_pack(session["key"]),
         :ok <- write_into_ticket(ticket_id, pack) do
      Logger.info("handoff: #{ticket_id} <- #{session["key"]} (#{byte_size(pack)} bytes)")
      {:ok, %{session: session["key"], bytes: byte_size(pack)}}
    end
  end

  @doc """
  Attaches a pack to every in-flight ticket that has a recorder session.

  In-flight means `state` is `in-progress` or `in-review`: a `ready` ticket has not run yet, so
  there is no context to carry. Tickets with no session are reported as skipped rather than failed
  -- there is nothing wrong with a ticket whose work has not started.

  Returns `%{attached: [attached], skipped: [skipped], failed: [failed]}`.
  """
  @spec attach_in_flight() :: %{attached: [attached()], skipped: [skipped()], failed: [failed()]}
  def attach_in_flight do
    tickets = in_flight_tickets()

    Enum.reduce(tickets, %{attached: [], skipped: [], failed: []}, fn ticket, acc ->
      case attach(ticket.id) do
        {:ok, %{session: session, bytes: bytes}} ->
          %{acc | attached: acc.attached ++ [%{id: ticket.id, session: session, bytes: bytes}]}

        {:error, :no_session} ->
          %{acc | skipped: acc.skipped ++ [%{id: ticket.id, reason: "recorder 里没有它的会话"}]}

        {:error, reason} ->
          %{acc | failed: acc.failed ++ [%{id: ticket.id, reason: describe(reason)}]}
      end
    end)
  end

  @doc "The `acp` / `agent` keys whose change means a different agent will do the work."
  @spec vendor_keys() :: [[String.t()]]
  def vendor_keys, do: [["acp", "adapter"], ["acp", "model"], ["agent", "backend"]]

  @doc """
  The sentence a caller shows after a vendor switch, including everything that did not work.

  Here rather than in the LiveView so it can be asserted: this text is the only place a person
  learns that a ticket was skipped or a fetch failed, and "the next agent really does see the
  context" is the whole point of the action.
  """
  @spec summary(map()) :: String.t()
  def summary(%{attached: attached, skipped: skipped, failed: failed}) do
    # `fn entry -> "…" end`, not `&"#{&1.id} …"`: the capture-with-interpolation form makes credo's
    # `Credo.Check.Readability.StringSigils` raise inside `parse_string_literal/4`, and the whole
    # lint run then exits 1 with a stack trace instead of a finding. Reported as a credo bug rather
    # than worked around silently -- but the workaround is free, so the text stays identical.
    lines =
      []
      |> add_line(
        attached != [],
        "续接上下文已写入：" <>
          Enum.map_join(attached, "、", fn entry -> "#{entry.id} — #{entry.bytes} 字节" end)
      )
      |> add_line(
        skipped != [],
        "跳过（recorder 里没有它们的会话）：" <> Enum.map_join(skipped, "、", & &1.id)
      )
      |> add_line(
        failed != [],
        "⚠️ 续接上下文失败：" <>
          Enum.map_join(failed, "、", fn entry -> "#{entry.id} — #{entry.reason}" end)
      )

    case lines do
      [] -> "\n\n换的是谁来干 —— 但没有在飞的票，所以没有上下文要带。"
      present -> "\n\n" <> Enum.join(present, "\n")
    end
  end

  defp add_line(lines, true, line), do: lines ++ [line]
  defp add_line(lines, false, _line), do: lines

  @doc """
  Sets the marked handoff section in a document, replacing an existing one.

  ## Why markers instead of "up to the next `##`"

  A handoff pack is multi-line markdown that **contains its own `## ` headings** (`## 目标`,
  `## 已定决策`, …). A section-scoped rule of the form "from `## heading` to the next `## `" therefore
  stops at the pack's *first* sub-heading and removes only a sliver of the previous one -- measured:
  the ticket grew by ~521 bytes on every attach, forever.

  So the section is fenced by HTML comments, which is the same technique the janitor already uses for
  its once-per-issue comment (`<!-- symphony:how-to -->`): the boundary is explicit, and no content
  the pack happens to contain can forge it.
  """
  @spec put_section(String.t(), String.t(), String.t()) :: String.t()
  def put_section(text, heading, content) when is_binary(text) do
    stripped =
      Regex.replace(
        ~r/\n?#{@begin_marker}.*?#{@end_marker}\n?/s,
        text,
        "\n"
      )

    String.trim_trailing(stripped) <>
      "\n\n#{@begin_marker}\n## #{heading}\n\n" <>
      String.trim(content) <> "\n" <> @end_marker <> "\n"
  end

  @doc "True when a session's `cwd` is the workspace of `ticket_id`."
  @spec workspace_of?(String.t() | nil, String.t()) :: boolean()
  def workspace_of?(cwd, ticket_id) when is_binary(cwd) and is_binary(ticket_id) do
    cwd
    |> String.replace("\\", "/")
    |> String.downcase()
    |> String.ends_with?("/" <> String.downcase(ticket_id))
  end

  def workspace_of?(_cwd, _ticket_id), do: false

  # ── recorder ─────────────────────────────────────────────────────────────────

  @doc "The recorder's base URL. `config :symphony_elixir, :recorder_upstream` to move it."
  @spec recorder_url() :: String.t()
  def recorder_url do
    Application.get_env(:symphony_elixir, :recorder_upstream, @default_recorder_url)
  end

  defp newest_session(ticket_id) do
    with {:ok, sessions} <- fetch_sessions() do
      sessions
      |> Enum.filter(&workspace_of?(&1["cwd"], ticket_id))
      |> Enum.sort_by(&(&1["lastTime"] || 0), :desc)
      |> List.first()
      |> case do
        nil -> {:error, :no_session}
        session -> {:ok, session}
      end
    end
  end

  defp fetch_sessions do
    case Req.get(recorder_url() <> "/api/sessions", receive_timeout: @http_timeout_ms) do
      {:ok, %{status: 200, body: %{"sessions" => sessions}}} when is_list(sessions) ->
        {:ok, sessions}

      {:ok, %{status: status}} ->
        {:error, {:recorder_http, status}}

      {:error, reason} ->
        {:error, {:recorder_unreachable, reason}}
    end
  rescue
    error -> {:error, {:recorder_unreachable, Exception.message(error)}}
  end

  defp fetch_pack(session_key) do
    url = recorder_url() <> "/api/sessions/" <> URI.encode_www_form(session_key) <> "/handoff"

    case Req.get(url, receive_timeout: @http_timeout_ms) do
      {:ok, %{status: 200, body: body}} when is_binary(body) and body != "" -> {:ok, body}
      {:ok, %{status: 200}} -> {:error, :empty_pack}
      {:ok, %{status: status}} -> {:error, {:recorder_http, status}}
      {:error, reason} -> {:error, {:recorder_unreachable, reason}}
    end
  rescue
    error -> {:error, {:recorder_unreachable, Exception.message(error)}}
  end

  # ── ticket file ──────────────────────────────────────────────────────────────

  defp in_flight_tickets do
    case TaskComposer.list_tickets() do
      {:ok, tickets} -> Enum.filter(tickets, &(&1.state in @in_flight_states))
      {:error, _reason} -> []
    end
  end

  defp write_into_ticket(ticket_id, pack) do
    path = Path.join(tickets_path(), "#{ticket_id}.md")

    case File.read(path) do
      {:ok, text} -> File.write(path, put_section(text, @section_heading, pack))
      {:error, reason} -> {:error, {:ticket_unreadable, ticket_id, reason}}
    end
  end

  defp tickets_path do
    settings = Config.settings!().janitor
    present(settings.tickets_path) || SymphonyElixir.Janitor.config().tickets
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value), do: value

  # `:no_session` is not here on purpose: `attach_in_flight/0` handles it as a skip (a ticket whose
  # work has not started is not a failure), so it never reaches the error path.
  defp describe(:empty_pack), do: "recorder 返回了空包"
  defp describe({:ticket_unreadable, id, reason}), do: "#{id} 的票据文件读不了（#{inspect(reason)}）"
  defp describe({:recorder_http, status}), do: "recorder 回了 HTTP #{status}"
  defp describe({:recorder_unreachable, reason}), do: "recorder 连不上（#{inspect(reason)}）"
  defp describe(other), do: inspect(other)
end
