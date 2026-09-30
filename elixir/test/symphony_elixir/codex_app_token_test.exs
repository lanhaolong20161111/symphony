defmodule SymphonyElixir.CodexAppTokenTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Config
  alias SymphonyElixir.Workflow

  # `codex.app_token` is the way a project hands its agent a GitHub App installation token instead of a
  # long-lived personal access token: minted for the run through `GitHubAppToken`, delivered to the
  # child as `GH_TOKEN`, and used -- itself, not the name of a variable that carries it -- for git's
  # credential header.
  #
  # No case here reaches the network, runs `gh`, or reads a real key: the configured cases inject
  # `:mint_token`, and the no-App cases never reach the mint at all.

  @key_path "C:/symphony-test/app.private-key.pem"

  # The workflow a person would write, minus the codex block under test. A whole file rather than
  # TestSupport's key list, because `app_token` is a nested mapping of its own and half of these cases
  # are about a file that is meant to be refused.
  @workflow_head """
  ---
  tracker:
    kind: memory
  codex:
  """

  @workflow_tail """
  ---
  Prompt body.
  """

  setup do
    {:ok, binding: %{secret_environment_names: ["LINEAR_API_KEY"], tool_specs: []}}
  end

  defp codex_block(lines), do: Enum.map_join(lines, "", &("  " <> &1 <> "\n"))

  defp app_token_block(fields) do
    codex_block(["app_token:" | Enum.map(fields, &("  " <> &1))])
  end

  defp workflow_content(codex_block), do: @workflow_head <> codex_block <> @workflow_tail

  defp write_workflow!(codex_block) do
    File.write!(Workflow.workflow_file_path(), workflow_content(codex_block))
    assert :ok = WorkflowStore.force_reload()
  end

  defp write_refused_workflow!(codex_block) do
    File.write!(Workflow.workflow_file_path(), workflow_content(codex_block))
    _ = WorkflowStore.force_reload()
    :ok
  end

  # The header git will send, found the way git finds it: the `GIT_CONFIG_VALUE_n` whose sibling
  # `GIT_CONFIG_KEY_n` is `http.https://github.com/.extraheader`.
  defp git_extraheader(env) do
    values = Map.new(env, fn {name, value} -> {to_string(name), to_string(value)} end)

    index =
      Enum.find_value(values, fn
        {"GIT_CONFIG_KEY_" <> index, "http.https://github.com/.extraheader"} -> index
        _entry -> nil
      end)

    Map.fetch!(values, "GIT_CONFIG_VALUE_#{index}")
  end

  defp configured_workflow!(extra_lines \\ []) do
    write_workflow!(
      app_token_block([
        "app_id: 123456",
        "private_key_path: \"#{@key_path}\"",
        "installation_id: 654321"
      ]) <> codex_block(extra_lines)
    )
  end

  describe "a configured App" do
    test "the minted token is what the child gets, and what git's header carries", %{binding: binding} do
      restore_env("SYMPHONY_AGENT_TOKEN", "long-lived-pat")

      configured_workflow!(["child_env: [\"GH_TOKEN=SYMPHONY_AGENT_TOKEN\"]"])

      mint = fn app_token ->
        send(self(), {:minted_with, app_token})
        {:ok, %{token: "ghs_minted_for_this_run"}}
      end

      parent = self()

      log =
        capture_log(fn ->
          assert {:ok, env} = AppServer.child_env("/tmp/ws", binding, mint_token: mint)
          send(parent, {:child_env, env})
        end)

      assert_received {:child_env, env}

      assert {~c"GH_TOKEN", ~c"ghs_minted_for_this_run"} in env
      assert {~c"GIT_TERMINAL_PROMPT", ~c"0"} in env

      header = git_extraheader(env)

      assert Base.decode64!(String.replace_prefix(header, "Authorization: Basic ", "")) ==
               "x-access-token:ghs_minted_for_this_run"

      # The token *itself* is in the header. A variable's name here would base64 a name into a
      # credential git cannot use, and the push would fail with no credential at all.
      refute header =~ "GH_TOKEN"

      # The long-lived token is not merely unused: it is gone, and the reason is logged.
      refute Enum.any?(env, fn {_name, value} -> value == ~c"long-lived-pat" end)
      assert log =~ "app_token is configured"

      # The mint was handed exactly what the workflow configured.
      assert_received {:minted_with,
                       %{
                         "app_id" => 123_456,
                         "private_key_path" => @key_path,
                         "installation_id" => 654_321
                       }}
    end

    test "with no App configured, the environment is byte for byte today's", %{binding: binding} do
      restore_env("SYMPHONY_AGENT_TOKEN", "scoped-token")
      restore_env("GH_TOKEN", nil)

      write_workflow!(
        codex_block([
          "command: \"codex app-server\"",
          "git_metadata_writable: false",
          "child_env: [\"GH_TOKEN=SYMPHONY_AGENT_TOKEN\"]"
        ])
      )

      assert {:ok, env} = AppServer.child_env("/tmp/ws", binding)

      # Captured from the committed implementation before this change -- `mix run --no-start` on this
      # same workflow and binding -- and written out entry for entry, in order, rather than computed:
      # a change to the contents, the order, or which credential git is given fails here.
      assert env == [
               {~c"LINEAR_API_KEY", false},
               {~c"GH_TOKEN", ~c"scoped-token"},
               {~c"GIT_TERMINAL_PROMPT", ~c"0"},
               {~c"GIT_CONFIG_COUNT", ~c"3"},
               {~c"GIT_CONFIG_KEY_0", ~c"safe.directory"},
               {~c"GIT_CONFIG_VALUE_0", ~c"*"},
               {~c"GIT_CONFIG_KEY_1", ~c"http.sslBackend"},
               {~c"GIT_CONFIG_VALUE_1", ~c"openssl"},
               {~c"GIT_CONFIG_KEY_2", ~c"http.https://github.com/.extraheader"},
               {~c"GIT_CONFIG_VALUE_2", ~c"Authorization: Basic eC1hY2Nlc3MtdG9rZW46c2NvcGVkLXRva2Vu"}
             ]
    end

    test "a failed mint fails the run with that reason, and there is no fallback", %{binding: binding} do
      restore_env("SYMPHONY_AGENT_TOKEN", "long-lived-pat")

      configured_workflow!(["child_env: [\"GH_TOKEN=SYMPHONY_AGENT_TOKEN\"]"])

      calls = :counters.new(1, [])

      mint = fn _app_token ->
        :counters.add(calls, 1, 1)
        {:error, {:api_status, 401, "A JSON web token could not be decoded"}}
      end

      # No `{:ok, env}` at all, so there is no environment in which the long-lived token could appear:
      # the run fails with GitHub's own words instead of pushing with the credential the App was
      # configured to replace.
      assert {:error, {:app_token_mint_failed, {:api_status, 401, _message}}} =
               AppServer.child_env("/tmp/ws", binding, mint_token: mint)

      # A rejected JWT is a decision, not a blip, so it is not retried.
      assert :counters.get(calls, 1) == 1
    end

    test "the run fails at that seam, before a child process is spawned" do
      configured_workflow!()

      workspace =
        Path.join(Config.local_workspace_root(), "app-token-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf(workspace) end)

      assert {:error, {:app_token_mint_failed, :key_unreadable}} =
               AppServer.start_session(workspace, mint_token: fn _app_token -> {:error, :key_unreadable} end)
    end

    test "a transport failure is retried once, and only once", %{binding: binding} do
      configured_workflow!()

      calls = :counters.new(1, [])

      mint = fn _app_token ->
        :counters.add(calls, 1, 1)
        {:error, {:api_unreachable, :timeout}}
      end

      assert {:error, {:app_token_mint_failed, {:api_unreachable, :timeout}}} =
               AppServer.child_env("/tmp/ws", binding, mint_token: mint)

      assert :counters.get(calls, 1) == 2
    end

    test "a mint that answers without a token is refused, and the answer is not echoed back",
         %{binding: binding} do
      configured_workflow!()

      assert {:error, {:app_token_mint_failed, :malformed_mint_result}} =
               AppServer.child_env("/tmp/ws", binding, mint_token: fn _app_token -> {:ok, :nope} end)
    end
  end

  describe "codex.app_token settings" do
    test "parses when present, and keeps what the workflow wrote" do
      write_workflow!(
        app_token_block([
          "app_id: 123456",
          "private_key_path: \"#{@key_path}\"",
          "installation_id: 654321",
          "account: acme"
        ])
      )

      assert Config.settings!().codex.app_token == %{
               "app_id" => 123_456,
               "private_key_path" => @key_path,
               "installation_id" => 654_321,
               "account" => "acme"
             }
    end

    test "a numeric string App id is accepted, the way the mint accepts it" do
      write_workflow!(app_token_block(["app_id: \"123456\"", "private_key_path: \"#{@key_path}\""]))

      assert Config.settings!().codex.app_token == %{
               "app_id" => "123456",
               "private_key_path" => @key_path
             }
    end

    test "a workflow without it still loads, with the setting absent" do
      write_workflow!(codex_block(["command: \"codex app-server\""]))

      assert :ok = Config.validate!()
      assert Config.settings!().codex.app_token == nil
    end

    test "a malformed one is refused, and the message names the setting" do
      malformed = [
        # No App id at all.
        app_token_block(["private_key_path: \"#{@key_path}\""]),
        # An App id that is not a number.
        app_token_block(["app_id: \"soon\"", "private_key_path: \"#{@key_path}\""]),
        # An installation id that cannot be one.
        app_token_block([
          "app_id: 123456",
          "private_key_path: \"#{@key_path}\"",
          "installation_id: 0"
        ]),
        # No path to the key the mint has to read.
        app_token_block(["app_id: 123456"]),
        # A blank path is not a path.
        app_token_block(["app_id: 123456", "private_key_path: \"   \""]),
        # A key the mint never reads: accepted silently it would look like it did something.
        app_token_block([
          "app_id: 123456",
          "private_key_path: \"#{@key_path}\"",
          "api_url: \"https://github.example.com\""
        ]),
        # Not a mapping at all.
        codex_block(["app_token: \"the-app\""])
      ]

      for block <- malformed do
        write_refused_workflow!(block)

        assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
        assert message =~ "codex.app_token"
      end
    end
  end
end
