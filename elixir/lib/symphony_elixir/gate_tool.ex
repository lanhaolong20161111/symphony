defmodule SymphonyElixir.GateTool do
  @moduledoc """
  The host's second agent-facing tool: "run this project's declared gate".

  It is a **host** tool, not a tracker capability and not the janitor's: it lives at the top of
  `SymphonyElixir` because it is advertised for every tracker kind, whether the project's tickets are
  files or rows in the ticket service.

  An agent's turn is sandboxed, and on this host `mix` cannot even reach compilation there:
  `Mix.Sync.PubSub` calls `Mix.Utils.detect_user_id!/0`, which stats the user profile directory, and
  that stat answers `:eacces` for the sandbox account. Measured, not suspected. So an agent can write
  code but cannot check it, and a person has to run `mix lint` / `mix test` afterwards -- which makes
  "the agent verifies its own work" impossible on this machine.

  Agent tools are not sandboxed: the tracker's tool surface runs in this process, with the host's own
  permissions. This tool is that surface pointed at the gate. It runs the command the project declared
  **on the host**, in the calling ticket's workspace, and answers with the exit code and the tail.

  It is advertised by `SymphonyElixir.Tracker.compose_agent_tool_specs/1` -- beside whatever the
  configured adapter offers, and for **every** tracker kind -- because running a gate is a property of
  the project, not of where its tickets come from. Advertising it from the file tracker's adapter is
  what left a service-backed project with no agent tools at all.

  ## The command is declared, never supplied

  A call may name a ticket. It may not name a command, an argument, a shell operator, or a script to
  run -- `gate.command` in `WORKFLOW.md` is the only command, and an argument that tries to carry one
  is refused **by name** rather than ignored (silently dropping `command` would leave the caller
  believing it had chosen what ran). That is the whole security rule of this module: a tool that runs
  what it is handed is a remote shell for anything that can write an agent prompt, and the host side
  of this one is not sandboxed at all.
  """

  alias SymphonyElixir.{Config, Shell, Workspace}

  @tool "symphony_gate"
  @ticket_argument "ticket"
  @allowed_arguments [@ticket_argument]
  @default_timeout_ms 900_000

  # Two bounds, because they fail differently: `@tail_lines` is what makes the answer a *tail* (a
  # `mix test` transcript is thousands of lines), `@max_output_bytes` is the hard one, for the single
  # enormous line that no line count bounds.
  @tail_lines 40
  @max_output_bytes 8_192

  # Anchored with \A and \z, unlike the janitor's own ^ and $ pattern: in an unanchored Elixir regex
  # `$` also matches before a trailing newline, and this string gets joined into a path.
  @ticket_id ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

  @description """
  Run the gate this project declares (`gate.command` in WORKFLOW.md) on the host, in this ticket's
  workspace, and answer with its exit code and the tail of its output.

  Use it to check your own work: the sandbox your turn runs in cannot start `mix` on this machine, so
  this is the only way the gate gets run before you hand the ticket back. It takes no command -- what
  runs is what the project declared, and no argument can change it -- and it never raises: a failing
  gate, a timeout and a launch failure all come back as a result you can read and report.
  """

  @doc """
  The tool spec, or `[]` when the project declares no gate.

  Empty rather than advertised-with-a-failure, so a project that declares nothing does not hand its
  agent a tool whose every call fails. The failure is still there for a call that arrives anyway (a
  stale binding, the HTTP tool endpoint): it says `declares no gate` and runs nothing.
  """
  @spec tool_specs() :: [map()]
  def tool_specs do
    case declared_gate() do
      :none ->
        []

      _gate ->
        [%{"name" => @tool, "description" => @description, "inputSchema" => input_schema()}]
    end
  end

  @doc """
  Whether `tool` is this module's tool, so the tracker can route it here.
  """
  @spec handles?(term()) :: boolean()
  def handles?(@tool), do: true
  def handles?(_tool), do: false

  @doc """
  Runs one call and returns the envelope the other agent tools return.

  `opts` carries the calling session: `:issue` and `:workspace` when the host knows them (the Codex
  path threads both from the session), `:settings` in tests, and `:runner` to replace `Shell.run/3`.
  """
  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @tool -> gate(arguments, opts)
      other -> failure(%{"error" => unsupported_error(other)})
    end
  end

  defp gate(arguments, opts) do
    case refuse_arguments(arguments) do
      {:error, payload} ->
        failure(payload)

      :ok ->
        case run(arguments_map(arguments), opts) do
          {:ok, payload} -> success(payload)
          {:error, payload} -> failure(payload)
        end
    end
  rescue
    # A tool call must fail as a result, never as an exception: the MCP server turns one into a
    # protocol-level error for the whole session, and a Codex turn only sees `success: false`.
    error -> failure(%{"error" => %{"message" => Exception.message(error)}})
  end

  defp run(arguments, opts) do
    with {:ok, gate} <- declared_command(opts),
         {:ok, workspace} <- workspace_for(arguments, opts) do
      execute_declared(gate, context(gate, workspace, arguments, opts), opts)
    end
  end

  # The declared command, through the declared shell, in the declared workspace -- and through
  # `Shell.run/3`, never `System.cmd/3`. That runner owns a **total** deadline (a command that keeps
  # printing cannot reset it), and on expiry it reads the port's `:os_pid` and calls its own
  # `kill_tree/1`, so a `mix test` that outlives the deadline takes its children with it instead of
  # leaving a survivor holding the stdout pipe. Re-deriving that pid here to kill again would be a
  # second process runner, which is the one thing this change must not add.
  defp execute_declared(gate, context, opts) do
    args = ["-lc", gate.command]
    run_opts = [cd: context["workspace"], timeout: gate.timeout_ms]

    case runner(opts).(shell(), args, run_opts) do
      {:ok, output, 0} -> {:ok, report(context, 0, output)}
      {:ok, output, status} -> failed(context, status, output)
      {:error, :timeout} -> timed_out(context, gate.timeout_ms)
      {:error, {:not_found, tool}} -> not_started(context, tool)
      {:error, reason} -> not_started(context, reason)
    end
  end

  # Injected in the tests, the same seam the janitor tools and the tracker clients take, so a test
  # never starts a real gate.
  defp runner(opts), do: Keyword.get(opts, :runner, &Shell.run/3)

  # The same shell the workspace hooks use, for the same reason: a command that says
  # `cd elixir && mix lint` is a shell script, and a bare `sh` is not on the Windows PATH.
  defp shell, do: Shell.find_sh() || "sh"

  defp report(context, status, output) do
    context
    |> Map.put("exitCode", status)
    |> Map.put("timedOut", false)
    |> Map.merge(output_payload(output))
  end

  defp failed(context, status, output) do
    error =
      context
      |> Map.put("message", "the gate exited #{status}; the tail of its output is below")
      |> Map.put("exitCode", status)
      |> Map.merge(output_payload(output))

    {:error, %{"error" => error}}
  end

  defp timed_out(context, timeout_ms) do
    message = "the gate did not finish within #{timeout_ms} ms; the host killed the process tree"
    error = Map.put(context, "message", message)

    {:error, %{"error" => Map.put(error, "timedOut", true)}}
  end

  defp not_started(context, reason) do
    message = "the gate could not start: #{inspect(reason)} -- `gate.command` needs a shell to run in"

    {:error, %{"error" => Map.put(context, "message", message)}}
  end

  defp declared_gate, do: gate_of(settings_from_disk())

  # The declaration, as the schema sees it. `nil`, blank and absent all mean the same thing to a
  # caller -- nothing was declared -- so the tool says so instead of running the empty string.
  defp declared_command(opts) do
    case gate_of(settings(opts)) do
      :none -> {:error, %{"error" => %{"message" => no_gate_message()}}}
      gate -> {:ok, %{command: gate.command, timeout_ms: timeout_ms(gate)}}
    end
  end

  defp no_gate_message do
    "this project declares no gate: add `gate.command` to WORKFLOW.md. Nothing was run."
  end

  defp settings(opts), do: Keyword.get(opts, :settings) || settings_from_disk()

  # Non-bang: a project whose workflow does not load has declared no gate, which is a result this tool
  # reports, not a reason to raise out of a tool call.
  defp settings_from_disk do
    case Config.settings() do
      {:ok, settings} -> settings
      {:error, _reason} -> %{}
    end
  end

  defp gate_of(%{gate: %{command: command} = gate}) when is_binary(command) do
    case String.trim(command) do
      "" -> :none
      _declared -> gate
    end
  end

  defp gate_of(_settings), do: :none

  defp timeout_ms(%{timeout_ms: timeout}) when is_integer(timeout) and timeout > 0, do: timeout
  defp timeout_ms(_gate), do: @default_timeout_ms

  # --- which ticket, and therefore which workspace -------------------------------

  # The session's own workspace wins when there is one: the Codex path threads it from the session
  # beside `:issue`, so the gate runs exactly where the turn is. Everywhere else -- the ACP/MCP stdio
  # server and the HTTP endpoint are separate processes with no session -- the ticket the call names
  # is the only thing that arrives, and the workspace is derived from it the way the orchestrator
  # derived the one it handed the agent (`Workspace.workspace_key/1` exists for exactly this). Either
  # way the path is one the host resolved: an argument cannot name one.
  defp workspace_for(arguments, opts) do
    case Keyword.get(opts, :workspace) do
      workspace when is_binary(workspace) and workspace != "" -> {:ok, workspace}
      _no_session -> derived_workspace(arguments, opts)
    end
  end

  defp derived_workspace(arguments, opts) do
    case ticket_from(arguments, opts) do
      nil -> {:error, %{"error" => %{"message" => no_ticket_message()}}}
      id -> derived_workspace_for(id)
    end
  end

  defp no_ticket_message do
    "symphony_gate needs a ticket identifier to know which workspace to run in, for example " <>
      "{\"ticket\": \"SYM-26\"}."
  end

  defp derived_workspace_for(id) do
    if valid_ticket_id?(id) do
      {:ok, Path.join(Config.local_workspace_root(), Workspace.workspace_key(id))}
    else
      {:error, %{"error" => %{"message" => "not a ticket identifier: #{inspect(id)}"}}}
    end
  end

  defp ticket_from(arguments, opts) do
    ticket_argument(arguments) || issue_identifier(Keyword.get(opts, :issue))
  end

  defp ticket_argument(arguments), do: arguments |> arguments_map() |> Map.get(@ticket_argument) |> presence()
  defp issue_identifier(%{identifier: identifier}), do: presence(identifier)
  defp issue_identifier(_issue), do: nil

  # --- what a call may not say ---------------------------------------------------

  # The rule the tests pin: the caller names *which ticket*, never *what runs*. A key that is not
  # `ticket` is refused by name, and a `ticket` that is not a plain ticket name is refused rather
  # than sanitised -- a value that survives a rewrite is still a value somebody chose.
  defp refuse_arguments(arguments) when is_map(arguments) do
    with :ok <- refuse_extra_keys(arguments) do
      refuse_ticket_value(Map.get(arguments, @ticket_argument))
    end
  end

  defp refuse_arguments(nil), do: :ok

  defp refuse_arguments(_arguments) do
    {:error, %{"error" => %{"message" => not_an_object_message()}}}
  end

  defp not_an_object_message do
    "symphony_gate takes an object naming at most a ticket, and this is not one."
  end

  defp refuse_extra_keys(arguments) do
    case Map.keys(arguments) -- @allowed_arguments do
      [] -> :ok
      extra -> {:error, %{"error" => extra_keys_error(extra)}}
    end
  end

  defp extra_keys_error(extra) do
    %{
      "message" =>
        "symphony_gate takes no command: it runs the gate the project declares, so " <>
          "#{inspect(extra)} is refused rather than used.",
      "supportedArguments" => @allowed_arguments
    }
  end

  defp refuse_ticket_value(nil), do: :ok

  # Checked as it arrives, not after trimming: `SYM-26\n` is exactly what an unanchored `$` would let
  # through -- the janitor's own pattern does -- and that value then gets joined into a path. A ticket
  # argument is either plain or refused.
  defp refuse_ticket_value(ticket) when is_binary(ticket) do
    if valid_ticket_id?(ticket), do: :ok, else: not_a_ticket(ticket)
  end

  defp refuse_ticket_value(ticket), do: not_a_ticket(ticket)

  defp not_a_ticket(ticket) do
    {:error, %{"error" => %{"message" => "not a ticket identifier: #{inspect(ticket)}"}}}
  end

  defp valid_ticket_id?(id) when is_binary(id), do: Regex.match?(@ticket_id, id)
  defp valid_ticket_id?(_id), do: false

  # --- bounding the answer -------------------------------------------------------

  # Last N lines first, then the byte cap through `Workspace.sanitize_hook_output_for_log/2` -- the
  # function that already exists for exactly this class of mistake. It trims back to a character
  # boundary, so a cut inside a multi-byte character cannot leave a tail that is no longer text.
  defp output_payload(output) do
    raw = IO.iodata_to_binary(output)
    {tail, lines_dropped?} = tail_lines(raw)
    {bounded, bytes_dropped?} = cap_bytes(tail)

    %{"output" => bounded, "truncated" => lines_dropped? or bytes_dropped?}
  end

  defp tail_lines(output) do
    lines = String.split(output, ~r/\r?\n/)

    case Enum.take(lines, -@tail_lines) do
      ^lines -> {output, false}
      tail -> {Enum.join(tail, "\n"), true}
    end
  end

  defp cap_bytes(text) do
    case Workspace.sanitize_hook_output_for_log(text, @max_output_bytes) do
      ^text -> {text, false}
      capped -> {capped, true}
    end
  end

  # --- the envelope --------------------------------------------------------------

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

  defp context(gate, workspace, arguments, opts) do
    %{"gate" => gate.command, "workspace" => workspace, "ticket" => ticket_from(arguments, opts)}
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp input_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        @ticket_argument => %{
          "type" => "string",
          "description" => "Ticket whose workspace runs the gate, for example SYM-26. Defaults to the running ticket."
        }
      }
    }
  end

  defp unsupported_error(tool) do
    %{
      "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
      "supportedTools" => [@tool]
    }
  end

  defp arguments_map(arguments) when is_map(arguments), do: arguments
  defp arguments_map(_arguments), do: %{}

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil
end
