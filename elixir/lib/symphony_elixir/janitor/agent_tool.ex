defmodule SymphonyElixir.Janitor.AgentTool do
  @moduledoc """
  The janitor's one agent-facing tool: "publish this ticket now".

  The agent cannot publish. codex's `workspaceWrite` sandbox makes `.git/` read-only and `gh` cannot
  read its own config, which is why publishing is host-side at all (see `SymphonyElixir.Janitor`).
  The sweep in that module publishes within one interval of the ticket reaching `in-review`; this
  tool asks for the same work **in the turn that finished it**, so the run learns the branch and the
  pull-request URL instead of ending with "the PR will appear shortly, I hope". The sweep stays as
  the backstop for a run that never calls it, and both paths are idempotent.

  Advertised by the file tracker: its tickets are files, and the janitor is that tracker's host-side
  caretaker. It is not a tracker capability, which is why it lives here rather than in the adapter's
  own tool list.
  """

  alias SymphonyElixir.Janitor

  @publish_tool "symphony_publish"
  @comment_tool "ticket_comment"
  @state_tool "ticket_state"

  @publish_description """
  Commit this ticket's workspace, push its branch and open the pull request, then report the branch
  and the pull-request URL. Call it once, when the work and its validation are done, and call it
  **before** setting the ticket to `in-review`: that state change is what stops your run, so anything
  placed after it never happens. The host also publishes on its own, so a failure here is not fatal
  -- but without this call the run cannot report the pull-request URL.
  """

  @comment_description """
  Add a comment to a ticket, in its `## Discussion` section. Use it to leave something the next reader
  needs -- why you stopped, what you could not verify, an assumption you made -- instead of editing the
  ticket's body, which cannot be done without risking its structure. The host assigns the comment id
  and answers with it.
  """

  @state_description """
  Move a ticket to a new state, by rewriting one front-matter key with the host's own writer: `ready`,
  `in-progress`, `in-review`, `paused`, `blocked`, `done` or `cancelled`.

  Use this instead of editing the ticket file to change its state. A ticket is UTF-8 text and this is
  the only writer that never re-encodes it, so the body and every non-ASCII character in it survive
  exactly. A shell editor does not: on Windows, PowerShell 5.1 defaults `Get-Content` and `Set-Content`
  to the **ANSI** code page, so reading a ticket and writing it back turns multi-byte text into `?` and
  leaves a file that is no longer valid UTF-8 -- it corrupts the ticket on the very line you meant to
  edit. This tool is refused, naming the ticket, when that has already happened to it.
  """

  @publish_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "properties" => %{
      "ticket" => %{
        "type" => "string",
        "description" => "Ticket identifier to publish, for example SYM-26. Defaults to the running ticket."
      }
    }
  }

  @comment_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["body"],
    "properties" => %{
      "ticket" => %{
        "type" => "string",
        "description" => "Ticket to comment on, for example SYM-26. Defaults to the running ticket."
      },
      "body" => %{
        "type" => "string",
        "description" => "The comment. Plain text; newlines are flattened into the single discussion line."
      }
    }
  }

  @state_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["state"],
    "properties" => %{
      "ticket" => %{
        "type" => "string",
        "description" => "Ticket to move, for example SYM-26. Defaults to the running ticket."
      },
      "state" => %{
        "type" => "string",
        "description" => "The state to set, for example in-review."
      }
    }
  }

  @doc """
  The tool specs this module advertises.
  """
  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @publish_tool,
        "description" => @publish_description,
        "inputSchema" => @publish_input_schema
      },
      %{
        "name" => @comment_tool,
        "description" => @comment_description,
        "inputSchema" => @comment_input_schema
      },
      %{
        "name" => @state_tool,
        "description" => @state_description,
        "inputSchema" => @state_input_schema
      }
    ]
  end

  @doc """
  Runs one tool call.

  `opts` may carry `:issue`, the ticket this turn is running, which is used when the call does not
  name one -- on the codex path the runtime supplies it, on the MCP path the agent passes the
  identifier instead.
  """
  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @publish_tool -> publish(arguments, opts)
      @comment_tool -> comment(arguments, opts)
      @state_tool -> set_state(arguments, opts)
      other -> failure(%{"error" => unsupported_error(other)})
    end
  end

  defp publish(arguments, opts) do
    case ticket_from(arguments, opts) do
      nil ->
        failure(%{
          "error" => %{
            "message" =>
              "symphony_publish needs a ticket identifier, for example {\"ticket\": \"SYM-26\"}.",
            "supportedTools" => [@publish_tool]
          }
        })

      ticket ->
        case publish_fun(opts).(ticket) do
          {:ok, result} -> success(Map.merge(%{"ticket" => ticket}, result))
          {:error, reason} -> failure(%{"error" => %{"message" => describe(reason), "ticket" => ticket}})
        end
    end
  rescue
    # A tool call must fail as a result, never as an exception: the MCP server turns one into a
    # protocol-level error for the whole session, and a Codex turn only sees `success: false`.
    error -> failure(%{"error" => %{"message" => Exception.message(error)}})
  end

  # Injected in tests so a tool call never reaches git or GitHub, the same way the tracker adapters
  # take their client.
  defp publish_fun(opts), do: Keyword.get(opts, :publish, &Janitor.publish_now/1)

  defp comment(arguments, opts) do
    with ticket when is_binary(ticket) <- ticket_from(arguments, opts),
         body when is_binary(body) <- arguments |> arguments_map() |> Map.get("body") |> presence() do
      case comment_fun(opts).(ticket, body) do
        {:ok, result} -> success(Map.merge(%{"ticket" => ticket}, result))
        {:error, reason} -> failure(%{"error" => %{"message" => describe(reason), "ticket" => ticket}})
      end
    else
      _ ->
        failure(%{
          "error" => %{
            "message" =>
              "ticket_comment needs a body and a ticket identifier, for example " <>
                "{\"ticket\": \"SYM-26\", \"body\": \"...\"}.",
            "supportedTools" => [@comment_tool]
          }
        })
    end
  rescue
    error -> failure(%{"error" => %{"message" => Exception.message(error)}})
  end

  defp comment_fun(opts), do: Keyword.get(opts, :comment, &Janitor.comment_on_ticket/2)

  # The state change, beside the comment, for the same reason: the host owns every write to a ticket
  # file, so a run never needs a shell command that reads one and writes it back.
  defp set_state(arguments, opts) do
    with ticket when is_binary(ticket) <- ticket_from(arguments, opts),
         state when is_binary(state) <- arguments |> arguments_map() |> Map.get("state") |> presence() do
      case state_fun(opts).(ticket, state) do
        {:ok, result} -> success(Map.merge(%{"ticket" => ticket}, result))
        {:error, reason} -> failure(%{"error" => %{"message" => describe(reason), "ticket" => ticket}})
      end
    else
      _ ->
        failure(%{
          "error" => %{
            "message" =>
              "ticket_state needs a state and a ticket identifier, for example " <>
                "{\"ticket\": \"SYM-26\", \"state\": \"in-review\"}.",
            "supportedTools" => [@state_tool]
          }
        })
    end
  rescue
    error -> failure(%{"error" => %{"message" => Exception.message(error)}})
  end

  defp state_fun(opts), do: Keyword.get(opts, :set_state, &Janitor.set_ticket_state/2)

  defp ticket_from(arguments, opts) do
    from_arguments = arguments |> arguments_map() |> Map.get("ticket") |> presence()

    from_arguments || issue_identifier(Keyword.get(opts, :issue))
  end

  defp arguments_map(arguments) when is_map(arguments), do: arguments
  defp arguments_map(_arguments), do: %{}

  defp issue_identifier(%{identifier: identifier}), do: presence(identifier)
  defp issue_identifier(_issue), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  # Every failure says which ticket and why: this tool exists so a run can report what happened, and
  # "error" alone would put the run back where it started. There is no catch-all clause on purpose --
  # the compiler checks this against `Janitor.publish_now/2`'s error type and says so if that type
  # ever grows, which is a better reminder than an `inspect/1` fallback nobody reads.
  defp describe({:invalid_ticket_id, id}), do: "not a ticket identifier: #{inspect(id)}"
  defp describe({:no_such_ticket, id}), do: "no ticket file for #{id}"
  defp describe({:not_a_workspace, path}), do: "no workspace to publish at #{path}"

  # Both halves of the write are text. The first is the one that has actually happened here: a shell
  # editor re-encoded the ticket through the ANSI code page, so its bytes stopped being UTF-8.
  defp describe({:ticket_not_utf8, id}), do: "the ticket file for #{id} is not valid UTF-8; refusing to rewrite it"

  defp describe({:value_not_utf8, id}),
    do: "the text to write into #{id} is not valid UTF-8; refusing to write it"

  defp describe(:no_issues_repo),
    do: "no issues repository is declared (janitor.issues_repo), and this refuses to guess one"

  defp unsupported_error(tool) do
    %{
      "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
      "supportedTools" => [@publish_tool, @comment_tool, @state_tool]
    }
  end

  defp success(payload), do: dynamic_tool_response(true, payload)
  defp failure(payload), do: dynamic_tool_response(false, payload)

  defp dynamic_tool_response(success, payload) do
    output =
      case Jason.encode(payload, pretty: true) do
        {:ok, encoded} -> encoded
        {:error, _reason} -> inspect(payload)
      end

    %{
      "success" => success,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end
end
