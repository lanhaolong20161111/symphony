defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  require Logger
  alias SymphonyElixir.{Codex.DynamicTool, Config, GitHubAppToken, PathSafety, Shell, SSH}

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @type session :: %{
          port: port(),
          metadata: map(),
          approval_policy: String.t() | map(),
          auto_approve_requests: boolean(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          thread_id: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          dynamic_tool_binding: map()
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    dynamic_tool_binding = DynamicTool.bind()

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, port} <- start_port(expanded_workspace, worker_host, dynamic_tool_binding, opts) do
      metadata = port_metadata(port, worker_host)

      with {:ok, session_policies} <- session_policies(expanded_workspace, worker_host),
           {:ok, thread_id} <-
             do_start_session(port, expanded_workspace, session_policies, dynamic_tool_binding) do
        {:ok,
         %{
           port: port,
           metadata: metadata,
           approval_policy: session_policies.approval_policy,
           auto_approve_requests: session_policies.approval_policy == "never",
           thread_sandbox: session_policies.thread_sandbox,
           turn_sandbox_policy: session_policies.turn_sandbox_policy,
           thread_id: thread_id,
           workspace: expanded_workspace,
           worker_host: worker_host,
           dynamic_tool_binding: dynamic_tool_binding
         }}
      else
        {:error, reason} ->
          stop_port(port)
          {:error, reason}
      end
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          metadata: metadata,
          approval_policy: approval_policy,
          auto_approve_requests: auto_approve_requests,
          turn_sandbox_policy: turn_sandbox_policy,
          thread_id: thread_id,
          workspace: workspace,
          dynamic_tool_binding: dynamic_tool_binding
        },
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    tool_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments ->
        DynamicTool.execute(tool, arguments, dynamic_tool_binding, issue: issue)
      end)

    case start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
      {:ok, turn_id} ->
        session_id = "#{thread_id}-#{turn_id}"
        Logger.info("Codex session started for #{issue_context(issue)} session_id=#{session_id}")

        emit_message(
          on_message,
          :session_started,
          %{
            session_id: session_id,
            thread_id: thread_id,
            turn_id: turn_id
          },
          metadata
        )

        case await_turn_completion(port, on_message, tool_executor, auto_approve_requests) do
          {:ok, result} ->
            Logger.info("Codex session completed for #{issue_context(issue)} session_id=#{session_id}")

            {:ok,
             %{
               result: result,
               session_id: session_id,
               thread_id: thread_id,
               turn_id: turn_id
             }}

          {:error, reason} ->
            Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

            emit_message(
              on_message,
              :turn_ended_with_error,
              %{
                session_id: session_id,
                reason: reason
              },
              metadata
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Codex session failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
  end

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Config.local_workspace_root()
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp start_port(workspace, nil, dynamic_tool_binding, opts) do
    # The environment is built -- which mints an App installation token when the workflow configured
    # one -- before anything is spawned. A run whose credential cannot be minted fails here, with that
    # reason, rather than starting a child that would push with whatever the sandbox account happens
    # to hold.
    with {:ok, env} <- child_env(workspace, dynamic_tool_binding, opts) do
      # `Shell.find_bash/0` rather than `System.find_executable("bash")`: on Windows the latter finds
      # WSL's bash, which cannot run a Windows launch command (it exits 127 on `codex`).
      executable = Shell.find_bash()

      if is_nil(executable) do
        {:error, :bash_not_found}
      else
        port =
          Port.open(
            {:spawn_executable, String.to_charlist(executable)},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              args: [~c"-lc", String.to_charlist(local_launch_command(dynamic_tool_binding))],
              cd: String.to_charlist(workspace),
              env: env,
              line: @port_line_bytes
            ]
          )

        {:ok, port}
      end
    end
  end

  defp start_port(workspace, worker_host, dynamic_tool_binding, _opts) when is_binary(worker_host) do
    remote_command = remote_launch_command(workspace, dynamic_tool_binding)
    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp local_launch_command(dynamic_tool_binding) do
    [
      tracker_secret_unset_command(dynamic_tool_binding),
      # `Shell.normalize_paths/1`: this string is a bash *script*, so a Windows path inside the
      # configured command would lose its backslashes and the child would die with exit 127.
      "exec #{Shell.normalize_paths(Config.settings!().codex.command)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp remote_launch_command(workspace, dynamic_tool_binding) when is_binary(workspace) do
    [
      "cd #{shell_escape(workspace)}",
      tracker_secret_unset_command(dynamic_tool_binding),
      "exec #{Config.settings!().codex.command}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  @doc """
  The environment the locally launched Codex child starts with.

  Four decisions in one place, because they are one decision:

    * the tracker's declared secrets are **removed** (`{name, false}`), which is what keeps a tracker
      token out of the agent's reach;
    * variables a workflow names in `codex.child_env` are **passed through**: values read from
      Symphony's own environment, so no credential has to be written into a project file. An entry is
      either `"NAME"` (the child gets the same name) or `"CHILD=SOURCE"` (the child gets `CHILD`, the
      value is read from `SOURCE`). The mapping form exists so the *host process* never has to hold a
      variable named `GH_TOKEN`: `gh` prefers that name over the OS credential store, so putting it in
      Symphony's own environment would silently move the janitor's own GitHub calls onto the agent's
      token -- which is scoped to one repository and would break the ticket mirror. A source this
      process does not have is omitted rather than set empty, and an entry naming a declared tracker
      secret on either side is refused with a warning -- those intents contradict each other, and
      silently honouring one of them is how a token leaks;
    * when the workflow configures `codex.app_token`, the run **mints a GitHub App installation token**
      and hands it to the child as `GH_TOKEN`, and the git credential header below is built from that
      same minted string. A `child_env` mapping onto `GH_TOKEN`/`GITHUB_TOKEN` is dropped rather than
      passed alongside it -- one credential per child, and the App is the one the workflow asked for --
      and no token is ever logged;
    * git is told to trust the workspace (`safe.directory=*`) when the agent may write git metadata,
      because the sandbox runs as a different OS account and git otherwise refuses every command with
      `fatal: detected dubious ownership`. When a GitHub token is on its way to the child, git is also
      given the `gh` credential helper's replacement, an `http.https://github.com/.extraheader`, without
      which an HTTPS push has no credential at all: the sandbox account has no credential store of its
      own.

  Returns the environment, or the reason minting failed: minting is part of building the environment,
  and a run whose App credential cannot be minted must fail with that reason instead of quietly falling
  back to a long-lived credential -- which is the thing configuring the App exists to avoid.

  Local launches only. An SSH launch builds its environment on the remote host, and what those hosts
  should inherit is a separate decision from what this machine's child gets.

  ## Options

    * `:mint_token` -- the injection point for the mint, arity 1, taking the `codex.app_token` map and
      returning `{:ok, %{token: String.t()}} | {:error, term()}`, defaulting to
      `GitHubAppToken.installation_token/1`. Tests inject it so no key file and no network call is
      needed; a workflow with no `app_token` never reaches it.
  """
  @spec child_env(Path.t() | nil, map(), keyword()) ::
          {:ok, [{charlist(), charlist() | false}]} | {:error, term()}
  def child_env(_workspace, dynamic_tool_binding, opts \\ []) do
    secrets = dynamic_tool_binding.secret_environment_names |> valid_environment_names()

    with {:ok, token} <- app_token_token(opts) do
      {:ok, environment(secrets, passthrough_env(secrets), token)}
    end
  end

  # The two names `gh` itself reads, and therefore the two that mean "a GitHub token is on its way to the
  # child". Defined here, above every use: a module attribute reads as nil in any function compiled
  # before it, and `name in nil` fails at runtime rather than at compile time.
  @gh_token_names ~w(GH_TOKEN GITHUB_TOKEN)

  # A minted token replaces -- rather than joins -- a `child_env` mapping onto either of `gh`'s names,
  # and the mapping it replaces is named in a warning so the workflow's author can see which of their
  # two credentials was honoured.
  defp environment(secrets, passthrough, nil) do
    credential = passthrough_github_token(passthrough)

    Enum.map(secrets, &{String.to_charlist(&1), false}) ++
      passthrough ++ no_prompt_env(credential) ++ git_config_env(credential)
  end

  defp environment(secrets, passthrough, token) when is_binary(token) do
    Enum.map(secrets, &{String.to_charlist(&1), false}) ++
      [{~c"GH_TOKEN", String.to_charlist(token)}] ++
      drop_passthrough_github_token(passthrough) ++
      no_prompt_env(token) ++ git_config_env(token)
  end

  defp passthrough_github_token(passthrough) do
    Enum.find_value(passthrough, fn {name, value} ->
      if to_string(name) in @gh_token_names, do: to_string(value)
    end)
  end

  defp drop_passthrough_github_token(passthrough) do
    Enum.reject(passthrough, fn {name, _value} ->
      if to_string(name) in @gh_token_names do
        Logger.warning("codex: app_token is configured, so the child_env mapping onto #{name} is not passed through")

        true
      else
        false
      end
    end)
  end

  # A broken token should fail, not hang: without this, git may sit waiting for a username it can never
  # be given, and the run burns its budget on a prompt nobody will answer.
  defp no_prompt_env(nil), do: []

  defp no_prompt_env(_credential), do: [{~c"GIT_TERMINAL_PROMPT", ~c"0"}]

  defp passthrough_env(secrets) do
    Config.settings!().codex.child_env
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(&passthrough_entry(&1, secrets))
  end

  defp passthrough_entry(spec, secrets) do
    case env_spec(spec) do
      nil ->
        []

      {_child, _source} = entry ->
        {child, source} = entry

        cond do
          child in secrets or source in secrets ->
            Logger.warning("codex: child_env #{inspect(spec)} names a tracker secret; not passing it through")

            []

          value = System.get_env(source) ->
            [{String.to_charlist(child), String.to_charlist(value)}]

          true ->
            # Absent here: omit it, so the child sees the same absence rather than an empty value that
            # looks like a configured-but-blank credential.
            []
        end
    end
  end

  defp env_spec(spec) do
    case String.split(spec, "=", parts: 2) do
      [child, source] -> validate_env_spec(child, source)
      [name] -> validate_env_spec(name, name)
    end
  end

  defp validate_env_spec(child, source) do
    case {valid_environment_names([String.trim(child)]), valid_environment_names([String.trim(source)])} do
      {[child], [source]} -> {child, source}
      _ -> nil
    end
  end

  # How the token reaches git, and why it is not a credential helper.
  #
  # A helper (`!gh auth git-credential`) is the tidier idea, but it makes git run another program: the
  # string goes to `sh`, which needs `gh` on PATH inside a sandbox owned by a different Windows account
  # whose PATH nobody has measured. `http.<url>.extraheader` needs none of that -- git sends the header
  # itself -- and it is what CI systems do with a token. Measured: SYM-54 and SYM-55 both failed with
  # `schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS`, which is what git reports when it
  # has no credential at all, helper or not.
  #
  # The empty `credential.helper` comes first and clears any inherited helper, so a credential manager in
  # the sandbox account cannot answer for the wrong user.
  defp github_auth_entries(token) do
    basic = Base.encode64("x-access-token:#{token}")

    [
      # Git for Windows defaults to schannel, and schannel needs a TLS client credential from
      # CryptoAPI. The sandbox account has no loaded profile, so it cannot get one: measured on
      # SYM-56, an agent whose git config *did* carry the Authorization header still failed with
      # `schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS` -- the failure is below
      # the token, in the TLS layer. OpenSSL ships with Git for Windows and needs none of that.
      {"http.sslBackend", "openssl"},
      {"http.https://github.com/.extraheader", "Authorization: Basic #{basic}"}
    ]
  end

  # `credential` is the token itself -- never the *name* of an environment variable that carries it:
  # `github_auth_entries/1` puts its argument into the header verbatim, so a name here would base64 a
  # variable name into a credential nobody can use. It is either the token minted for this run from
  # `codex.app_token`, or the value a `child_env` mapping passed through; `nil` means no GitHub
  # credential at all, and the header is omitted.
  defp git_config_env(credential) do
    trust? = Config.settings!().codex.git_metadata_writable

    entries =
      if(trust? or credential, do: [{"safe.directory", "*"}], else: []) ++
        if credential, do: github_auth_entries(credential), else: []

    case entries do
      [] ->
        []

      entries ->
        pairs =
          entries
          |> Enum.with_index()
          |> Enum.flat_map(fn {{key, value}, index} ->
            [
              {String.to_charlist("GIT_CONFIG_KEY_#{index}"), String.to_charlist(key)},
              {String.to_charlist("GIT_CONFIG_VALUE_#{index}"), String.to_charlist(value)}
            ]
          end)

        [{~c"GIT_CONFIG_COUNT", String.to_charlist(to_string(length(entries)))} | pairs]
    end
  end

  # -- app token -------------------------------------------------------------------------------

  # Exactly the options `GitHubAppToken.installation_token/1` takes, in the order the setting's own
  # schema lists them.
  @app_token_option_keys [
    {:app_id, "app_id"},
    {:private_key_path, "private_key_path"},
    {:installation_id, "installation_id"},
    {:account, "account"}
  ]

  # The whole setting: absent (`nil`) means no minting at all, so nothing here can reach the network
  # for a workflow that does not name an App.
  defp app_token_token(opts) do
    case Config.settings!().codex.app_token do
      nil -> {:ok, nil}
      app_token -> mint_token(app_token, opts)
    end
  end

  defp mint_token(app_token, opts) do
    case attempt_mint(app_token, opts) do
      {:ok, token} -> {:ok, token}
      {:error, reason} -> maybe_retry_mint(app_token, opts, reason)
    end
  end

  defp attempt_mint(app_token, opts) do
    case mint_fun(opts).(app_token) do
      {:ok, %{token: token}} when is_binary(token) and token != "" -> {:ok, token}
      # The minted string is never echoed back in an error: it is the credential.
      {:ok, _other} -> {:error, :malformed_mint_result}
      {:error, reason} -> {:error, reason}
    end
  end

  # One immediate retry, and only for a transport failure: GitHub was never reached, so the key and the
  # App are not what failed, and the alternative is throwing a whole run away over one dropped
  # connection. Every other failure is a decision -- an unreadable key, a missing installation, a
  # rejected JWT -- and repeating it only doubles the wait before the same reason is reported.
  # `GitHubAppToken` sets `retry: false` for the same reason.
  defp maybe_retry_mint(app_token, opts, {:api_unreachable, _reason}) do
    case attempt_mint(app_token, opts) do
      {:ok, token} -> {:ok, token}
      {:error, reason} -> {:error, {:app_token_mint_failed, reason}}
    end
  end

  defp maybe_retry_mint(_app_token, _opts, reason), do: {:error, {:app_token_mint_failed, reason}}

  defp mint_fun(opts), do: Keyword.get(opts, :mint_token) || (&default_mint_token/1)

  # The real implementation is the existing module, unchanged: the setting names the same options
  # `GitHubAppToken.installation_token/1` documents, so this only copies them across -- by name, so the
  # settings map never doubles as a keyword list by accident.
  defp default_mint_token(app_token) do
    app_token
    |> app_token_options()
    |> GitHubAppToken.installation_token()
  end

  # The schema hands this map over with string keys; atom keys are accepted too, so a hand-built map (a
  # test, a future caller) reads the same.
  defp app_token_options(app_token) do
    Enum.flat_map(@app_token_option_keys, fn {key, name} ->
      case Map.get(app_token, name) || Map.get(app_token, key) do
        nil -> []
        value -> [{key, value}]
      end
    end)
  end

  defp tracker_secret_unset_command(dynamic_tool_binding) do
    case dynamic_tool_binding.secret_environment_names |> valid_environment_names() do
      [] -> nil
      names -> "unset " <> Enum.join(names, " ")
    end
  end

  defp valid_environment_names(names) do
    Enum.filter(names, fn name ->
      is_binary(name) and String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
    end)
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{codex_app_server_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp send_initialize(port) do
    payload = %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{
          "experimentalApi" => true
        },
        "clientInfo" => %{
          "name" => "symphony-orchestrator",
          "title" => "Symphony Orchestrator",
          "version" => "0.1.0"
        }
      }
    }

    send_message(port, payload)

    with {:ok, _} <- await_response(port, @initialize_id) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  end

  defp session_policies(workspace, nil) do
    Config.codex_runtime_settings(workspace)
  end

  defp session_policies(workspace, worker_host) when is_binary(worker_host) do
    Config.codex_runtime_settings(workspace, remote: true)
  end

  defp do_start_session(port, workspace, session_policies, dynamic_tool_binding) do
    case send_initialize(port) do
      :ok ->
        start_thread(port, workspace, session_policies, dynamic_tool_binding)

      {:error, reason} ->
        # The handshake itself: if this fails, nothing about the configured policies is reachable
        # yet, so report it as its own step rather than as a generic session failure.
        Logger.error("codex rejected initialize: #{inspect(reason, limit: 5)}")
        {:error, {:initialize_rejected, reason}}
    end
  end

  defp start_thread(
         port,
         workspace,
         %{approval_policy: approval_policy, thread_sandbox: thread_sandbox},
         dynamic_tool_binding
       ) do
    send_message(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" => %{
        "approvalPolicy" => approval_policy,
        "sandbox" => thread_sandbox,
        "cwd" => workspace,
        "dynamicTools" => dynamic_tool_binding.tool_specs
      }
    })

    case await_response(port, @thread_start_id) do
      {:ok, %{"thread" => thread_payload}} ->
        case thread_payload do
          %{"id" => thread_id} -> {:ok, thread_id}
          _ -> {:error, {:invalid_thread_payload, thread_payload}}
        end

      {:error, reason} ->
        # Name the version-sensitive options that were sent. codex renamed an approval policy once
        # ("reject" -> "granular"), and every run then failed here, before its first turn, with an
        # error that never mentioned the option -- which is the expensive part to debug. The server
        # stays authoritative: no local allowlist, just its answer alongside what we asked for.
        Logger.error(
          "codex rejected thread/start with approvalPolicy=#{inspect(approval_policy)} " <>
            "sandbox=#{inspect(thread_sandbox)}: #{inspect(reason, limit: 5)}"
        )

        {:error, {:thread_start_rejected, %{approval_policy: approval_policy, thread_sandbox: thread_sandbox}, reason}}

      other ->
        other
    end
  end

  defp start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
    send_message(port, %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" => %{
        "threadId" => thread_id,
        "input" => [
          %{
            "type" => "text",
            "text" => prompt
          }
        ],
        "cwd" => workspace,
        "title" => "#{issue.identifier}: #{issue.title}",
        "approvalPolicy" => approval_policy,
        "sandboxPolicy" => turn_sandbox_policy
      }
    })

    case await_response(port, @turn_start_id) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end

  defp await_turn_completion(port, on_message, tool_executor, auto_approve_requests) do
    receive_loop(
      port,
      on_message,
      Config.settings!().codex.turn_timeout_ms,
      "",
      tool_executor,
      auto_approve_requests
    )
  end

  defp receive_loop(port, on_message, timeout_ms, pending_line, tool_executor, auto_approve_requests) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_incoming(port, on_message, complete_line, timeout_ms, tool_executor, auto_approve_requests)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(
          port,
          on_message,
          timeout_ms,
          pending_line <> to_string(chunk),
          tool_executor,
          auto_approve_requests
        )

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_incoming(port, on_message, data, timeout_ms, tool_executor, auto_approve_requests) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, %{"method" => "turn/completed"} = payload} ->
        emit_turn_event(on_message, :turn_completed, payload, payload_string, port, payload)
        {:ok, :turn_completed}

      {:ok, %{"method" => "turn/failed", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_failed,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_failed, Map.get(payload, "params")}}

      {:ok, %{"method" => "turn/cancelled", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_cancelled,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_cancelled, Map.get(payload, "params")}}

      {:ok, %{"method" => method} = payload}
      when is_binary(method) ->
        handle_turn_method(
          port,
          on_message,
          payload,
          payload_string,
          method,
          timeout_ms,
          tool_executor,
          auto_approve_requests
        )

      {:ok, payload} ->
        emit_message(
          on_message,
          :other_message,
          %{
            payload: payload,
            raw: payload_string
          },
          metadata_from_message(port, payload)
        )

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)

      {:error, _reason} ->
        log_non_json_stream_line(payload_string, "turn stream")

        if protocol_message_candidate?(payload_string) do
          emit_message(
            on_message,
            :malformed,
            %{
              payload: payload_string,
              raw: payload_string
            },
            metadata_from_message(port, %{raw: payload_string})
          )
        end

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
    end
  end

  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details) do
    emit_message(
      on_message,
      event,
      %{
        payload: payload,
        raw: payload_string,
        details: payload_details
      },
      metadata_from_message(port, payload)
    )
  end

  defp handle_turn_method(
         port,
         on_message,
         payload,
         payload_string,
         method,
         timeout_ms,
         tool_executor,
         auto_approve_requests
       ) do
    metadata = metadata_from_message(port, payload)

    case maybe_handle_approval_request(
           port,
           method,
           payload,
           payload_string,
           on_message,
           metadata,
           tool_executor,
           auto_approve_requests
         ) do
      :input_required ->
        emit_message(
          on_message,
          :turn_input_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:turn_input_required, payload}}

      :approved ->
        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)

      :approval_required ->
        emit_message(
          on_message,
          :approval_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:approval_required, payload}}

      :unhandled ->
        if needs_input?(method, payload) do
          emit_message(
            on_message,
            :turn_input_required,
            %{payload: payload, raw: payload_string},
            metadata
          )

          {:error, {:turn_input_required, payload}}
        else
          emit_message(
            on_message,
            :notification,
            %{
              payload: payload,
              raw: payload_string
            },
            metadata
          )

          Logger.debug("Codex notification: #{inspect(method)}")
          receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
        end
    end
  end

  defp maybe_handle_approval_request(
         port,
         "item/commandExecution/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/call",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         tool_executor,
         _auto_approve_requests
       ) do
    tool_name = tool_call_name(params)
    arguments = tool_call_arguments(params)

    result =
      tool_name
      |> tool_executor.(arguments)
      |> normalize_dynamic_tool_result()

    send_message(port, %{
      "id" => id,
      "result" => result
    })

    event =
      case result do
        %{"success" => true} -> :tool_call_completed
        _ when is_nil(tool_name) -> :unsupported_tool_call
        _ -> :tool_call_failed
      end

    emit_message(on_message, event, %{payload: payload, raw: payload_string}, metadata)

    :approved
  end

  defp maybe_handle_approval_request(
         port,
         "execCommandApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "applyPatchApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/fileChange/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/requestUserInput",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    maybe_auto_answer_tool_request_user_input(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         _port,
         _method,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _tool_executor,
         _auto_approve_requests
       ) do
    :unhandled
  end

  defp normalize_dynamic_tool_result(%{"success" => success} = result) when is_boolean(success) do
    output =
      case Map.get(result, "output") do
        existing_output when is_binary(existing_output) -> existing_output
        _ -> dynamic_tool_output(result)
      end

    content_items =
      case Map.get(result, "contentItems") do
        existing_items when is_list(existing_items) -> existing_items
        _ -> dynamic_tool_content_items(output)
      end

    result
    |> Map.put("output", output)
    |> Map.put("contentItems", content_items)
  end

  defp normalize_dynamic_tool_result(result) do
    %{
      "success" => false,
      "output" => inspect(result),
      "contentItems" => dynamic_tool_content_items(inspect(result))
    }
  end

  defp dynamic_tool_output(%{"contentItems" => [%{"text" => text} | _]}) when is_binary(text), do: text
  defp dynamic_tool_output(result), do: Jason.encode!(result, pretty: true)

  defp dynamic_tool_content_items(output) when is_binary(output) do
    [
      %{
        "type" => "inputText",
        "text" => output
      }
    ]
  end

  defp approve_or_require(
         port,
         id,
         decision,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    send_message(port, %{"id" => id, "result" => %{"decision" => decision}})

    emit_message(
      on_message,
      :approval_auto_approved,
      %{payload: payload, raw: payload_string, decision: decision},
      metadata
    )

    :approved
  end

  defp approve_or_require(
         _port,
         _id,
         _decision,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ) do
    :approval_required
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    case tool_request_user_input_approval_answers(params) do
      {:ok, answers, decision} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :approval_auto_approved,
          %{payload: payload, raw: payload_string, decision: decision},
          metadata
        )

        :approved

      :error ->
        :input_required
    end
  end

  defp maybe_auto_answer_tool_request_user_input(
         _port,
         _id,
         _params,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ),
       do: :input_required

  defp tool_request_user_input_approval_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_approval_answer(question) do
          {:ok, question_id, answer_label} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [answer_label]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map, "Approve this Session"}
      _ -> :error
    end
  end

  defp tool_request_user_input_approval_answers(_params), do: :error

  defp tool_request_user_input_approval_answer(%{"id" => question_id, "options" => options})
       when is_binary(question_id) and is_list(options) do
    if String.starts_with?(question_id, "mcp_tool_call_approval_") do
      case tool_request_user_input_approval_option_label(options) do
        nil -> :error
        answer_label -> {:ok, question_id, answer_label}
      end
    else
      :error
    end
  end

  defp tool_request_user_input_approval_answer(_question), do: :error

  defp tool_request_user_input_approval_option_label(options) do
    options
    |> Enum.map(&tool_request_user_input_option_label/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      labels ->
        Enum.find(labels, &(&1 == "Approve this Session")) ||
          Enum.find(labels, &(&1 == "Approve Once")) ||
          Enum.find(labels, &approval_option_label?/1)
    end
  end

  defp tool_request_user_input_option_label(%{"label" => label}) when is_binary(label), do: label
  defp tool_request_user_input_option_label(_option), do: nil

  defp approval_option_label?(label) when is_binary(label) do
    normalized_label =
      label
      |> String.trim()
      |> String.downcase()

    String.starts_with?(normalized_label, "approve") or String.starts_with?(normalized_label, "allow")
  end

  defp await_response(port, request_id) do
    with_timeout_response(port, request_id, Config.settings!().codex.read_timeout_ms, "")
  end

  defp with_timeout_response(port, request_id, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, data, timeout_ms) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{} = other} ->
        Logger.debug("Ignoring message while waiting for response: #{inspect(other)}")
        with_timeout_response(port, request_id, timeout_ms, "")

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream")
        with_timeout_response(port, request_id, timeout_ms, "")
    end
  end

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Codex #{stream_label} output: #{text}")
      else
        Logger.debug("Codex #{stream_label} output: #{text}")
      end
    end
  end

  defp protocol_message_candidate?(data) do
    data
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("{")
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp metadata_from_message(port, payload) do
    port |> port_metadata(nil) |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(_message), do: :ok

  defp tool_call_name(params) when is_map(params) do
    case Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") || Map.get(params, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp tool_call_name(_params), do: nil

  defp tool_call_arguments(params) when is_map(params) do
    Map.get(params, "arguments") || Map.get(params, :arguments) || %{}
  end

  defp tool_call_arguments(_params), do: %{}

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  defp needs_input?("mcpServer/elicitation/request", payload) when is_map(payload), do: true

  defp needs_input?(method, payload)
       when is_binary(method) and is_map(payload) do
    String.starts_with?(method, "turn/") && input_required_method?(method, payload)
  end

  defp needs_input?(_method, _payload), do: false

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "inputRequired") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false
end
