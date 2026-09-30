defmodule SymphonyElixir.DeployTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Deploy
  alias SymphonyElixir.Shell

  # Nothing here runs a deploy, starts a shell or touches a process: `:runner` replaces `Shell.run/3`,
  # the same seam the gate tool and the tracker clients take, and the declaration arrives either
  # through injected `:settings` (the schema's own answer) or through a real workflow file written into
  # a temporary registry. What is worth pinning is the rule that keeps this from being a remote shell --
  # a run names a *project*, never a command -- plus the ways a deploy can end while still answering as
  # a value.

  @deploy_command "make deploy"
  @deploy_directory "C:/srv/app"
  @declared_timeout 42_000

  # U+65E5 is three bytes, so a cut at an 8 KiB boundary can land inside it -- which is the whole
  # reason the byte cap goes through the character-safe truncation.
  @three_byte_char "\u65E5"

  defp tmp_dir(prefix) do
    dir = Path.expand(Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}"))
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # The registry rows `Deploy` looks the project up in. Only the name and the path are read, because
  # that is all the lookup needs -- and with `:settings` injected the path is never opened.
  defp rows(name \\ "alpha"), do: [%{name: name, path: "C:/registry/#{name}.md"}]

  # The schema's own answer for a project whose `deploy` block says this. Going through
  # `Schema.parse/1` rather than hand-building a struct is what makes these tests about the declaration
  # a workflow author actually gets.
  defp parsed_settings(overrides) do
    deploy =
      Map.merge(
        %{
          "command" => @deploy_command,
          "working_directory" => @deploy_directory,
          "timeout_ms" => @declared_timeout
        },
        overrides
      )

    assert {:ok, settings} = Schema.parse(%{"deploy" => deploy})
    settings
  end

  # The two seams one call takes: `:settings` and `:projects` (the declaration), and whatever runtime
  # injection the test adds (`:runner`).
  defp deploy_opts(overrides, run_opts \\ []) do
    [settings: parsed_settings(overrides), projects: rows()] ++ run_opts
  end

  defp recording_runner(result) do
    test_pid = self()

    fn executable, args, opts ->
      send(test_pid, {:deploy_ran, executable, args, opts})
      result
    end
  end

  defp never_used, do: [runner: recording_runner(:never_used)]

  # The workflow a person would write, with or without the deploy block. Paths go in with forward
  # slashes: a Windows backslash is an escape character inside a YAML double-quoted scalar, and the
  # front matter's *values* have to stay ASCII for the parser on this host.
  defp write_project!(registry, name, deploy) do
    block =
      case deploy do
        nil ->
          "deploy:\n"

        {command, directory, timeout} ->
          "deploy:\n  command: \"#{command}\"\n  working_directory: \"#{directory}\"\n  timeout_ms: #{timeout}\n"
      end

    File.write!(Path.join(registry, "#{name}.md"), """
    ---
    server:
      host: 127.0.0.1
      port: 4101
    tracker:
      kind: file
      provider:
        path: C:/q/#{name}
    janitor:
      enabled: false
      interval_ms: 30000
      issues_repo: owner/#{name}
      tickets_repo: owner/tickets
      tickets_path: C:/q/#{name}
    workspace:
      root: C:/ws/#{name}
    agent:
      backend: codex
    #{block}---

    Work on #{name}.
    """)
  end

  defp with_registry(directory, fun) do
    previous = Application.get_env(:symphony_elixir, :projects_dir)
    Application.put_env(:symphony_elixir, :projects_dir, directory)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:symphony_elixir, :projects_dir)
      else
        Application.put_env(:symphony_elixir, :projects_dir, previous)
      end
    end)

    fun.()
  end

  describe "the declaration" do
    test "a project with no deploy block parses, and declares nothing" do
      assert {:ok, settings} = Schema.parse(%{})
      assert settings.deploy.command == nil
      assert settings.deploy.working_directory == nil
      assert settings.deploy.timeout_ms == Schema.Deploy.default_timeout_ms()

      assert {:error, message} = Deploy.declared("alpha", settings: settings, projects: rows())
      assert message =~ "alpha declares no deploy"
    end

    test "a blank command is the same state as no block at all, and is not an error in the file" do
      for command <- ["", "   ", "\t\n"] do
        assert {:error, message} = Deploy.declared("alpha", deploy_opts(%{"command" => command}))
        assert message =~ "declares no deploy"
        assert message =~ "deploy.command"
        assert message =~ "Nothing was run"
      end
    end

    test "an omitted working directory and an omitted deadline take the declared defaults" do
      assert {:ok, declaration} =
               Deploy.declared("alpha", deploy_opts(%{"working_directory" => nil, "timeout_ms" => nil}))

      assert declaration.working_directory == nil
      assert declaration.timeout_ms == Schema.Deploy.default_timeout_ms()
    end

    test "a malformed working directory is refused, by name, with the reason" do
      for bad <- ["", "   ", "elixir", "../checkout", "checkout/app", "C:relative", "~/.symphony"] do
        assert {:error, {:invalid_workflow_config, message}} =
                 Schema.parse(%{
                   "deploy" => %{"command" => @deploy_command, "working_directory" => bad}
                 })

        assert message =~ "deploy.working_directory", "expected #{inspect(bad)} to be refused"
      end
    end

    test "a bad timeout is refused, by name" do
      for bad <- [0, -1, "soon"] do
        assert {:error, {:invalid_workflow_config, message}} =
                 Schema.parse(%{"deploy" => %{"command" => @deploy_command, "timeout_ms" => bad}})

        assert message =~ "deploy.timeout_ms", "expected #{inspect(bad)} to be refused"
      end
    end

    test "an absolute working directory is accepted, whichever host wrote it" do
      for good <- ["/srv/app", "C:/code/app", "C:\\code\\app", "\\\\host\\share\\app"] do
        assert {:ok, settings} =
                 Schema.parse(%{
                   "deploy" => %{"command" => @deploy_command, "working_directory" => good}
                 })

        assert settings.deploy.working_directory == good
      end
    end

    test "the declaration is read out of the project's own workflow file, through the registry" do
      registry = tmp_dir("symphony-deploy-registry")

      with_registry(registry, fn ->
        write_project!(registry, "alpha", {@deploy_command, @deploy_directory, @declared_timeout})

        assert {:ok, declaration} = Deploy.declared("alpha")
        assert declaration.command == @deploy_command
        assert declaration.working_directory == @deploy_directory
        assert declaration.timeout_ms == @declared_timeout
      end)
    end

    test "a project that declares none offers none, and a run refuses without starting anything" do
      registry = tmp_dir("symphony-deploy-registry")

      with_registry(registry, fn ->
        write_project!(registry, "alpha", nil)

        assert {:error, message} = Deploy.declared("alpha")
        assert message =~ "alpha declares no deploy"

        assert {:error, result} = Deploy.run("alpha", never_used())
        assert result.message =~ "declares no deploy"
        refute result.timed_out
        refute result.truncated
        assert result.output == ""
        assert result.exit_code == nil
        refute_received {:deploy_ran, _, _, _}
      end)
    end

    test "a workflow that cannot be read or parsed is a refusal, not a crash" do
      registry = tmp_dir("symphony-deploy-registry")

      with_registry(registry, fn ->
        # A file the registry lists but that is not there any more, and one whose front matter is not
        # YAML at all: both are answers this has to give as a message.
        missing = Path.join(registry, "gone.md")

        assert {:error, missing_message} =
                 Deploy.declared("gone", projects: [%{name: "gone", path: missing}])

        assert missing_message =~ "the workflow does not load"

        File.write!(Path.join(registry, "broken.md"), "---\ndeploy: [\n---\n\nWork on broken.\n")

        assert {:error, broken_message} = Deploy.declared("broken")
        assert broken_message =~ "the workflow does not load"
      end)
    end
  end

  describe "what a run may not say" do
    test "a request cannot inject, extend or redirect the command, the directory or the deadline" do
      opts =
        deploy_opts(%{}, runner: recording_runner({:ok, "built", 0}))
        |> Keyword.merge(
          command: "rm -rf /",
          cmd: "rm -rf /",
          shell: "cmd.exe",
          script: "./evil.sh",
          argv: ["-lc", "rm -rf /"],
          cwd: "C:/Windows",
          working_directory: "C:/Windows",
          timeout_ms: 5
        )

      assert {:ok, result} = Deploy.run("alpha", opts)
      assert result.command == @deploy_command
      assert result.working_directory == @deploy_directory

      assert_received {:deploy_ran, executable, args, run_opts}
      assert executable == (Shell.find_sh() || "sh")
      assert args == ["-lc", @deploy_command]
      assert run_opts[:cd] == @deploy_directory
      assert run_opts[:timeout] == @declared_timeout
      refute_received {:deploy_ran, _, ["-lc", "rm -rf /"], _}
    end

    test "a project the registry does not list is refused, and nothing runs" do
      for name <- ["ghost", "../../symphony-projects/symphony", "C:/registry/alpha.md", "alpha "] do
        assert {:error, result} = Deploy.run(name, [projects: rows()] ++ never_used())
        refute result.command
        assert result.message =~ "no project named"
        assert result.message =~ "nothing was run"
      end

      refute_received {:deploy_ran, _, _, _}
    end
  end

  describe "running the declared deploy" do
    test "runs the declared command through the hooks' shell, in the declared directory, for the declared deadline" do
      log =
        capture_log(fn ->
          assert {:ok, result} = Deploy.run("alpha", deploy_opts(%{}, runner: recording_runner({:ok, "release built", 0})))

          assert result.project == "alpha"
          assert result.command == @deploy_command
          assert result.working_directory == @deploy_directory
          assert result.exit_code == 0
          refute result.timed_out
          refute result.truncated
          assert result.output == "release built"
          assert result.message == "exit 0"
        end)

      assert_received {:deploy_ran, executable, args, run_opts}
      assert executable == (Shell.find_sh() || "sh")
      assert args == ["-lc", @deploy_command]
      assert run_opts[:cd] == @deploy_directory
      assert run_opts[:timeout] == @declared_timeout

      # What ran, and how it ended, in the log -- the record a person reads after the fact.
      assert log =~ "deploy: alpha runs"
      assert log =~ @deploy_command
      assert log =~ "deploy: alpha exited 0"
    end

    test "with no working directory declared, the runner is given no :cd at all" do
      opts = deploy_opts(%{"working_directory" => nil}, runner: recording_runner({:ok, "", 0}))

      assert {:ok, result} = Deploy.run("alpha", opts)
      assert result.working_directory == nil

      assert_received {:deploy_ran, _executable, _args, run_opts}
      refute Keyword.has_key?(run_opts, :cd)
      assert run_opts[:timeout] == @declared_timeout
    end
  end

  describe "every failure is a value" do
    test "a non-zero exit comes back with the status and the tail" do
      opts = deploy_opts(%{}, runner: recording_runner({:ok, "line 1\nboom: no such target", 2}))

      assert {:error, result} = Deploy.run("alpha", opts)
      assert result.exit_code == 2
      refute result.timed_out
      assert result.message =~ "the deploy exited 2"
      assert result.output =~ "boom: no such target"
    end

    test "a timeout names the deadline, and the deadline is what kills the process tree" do
      opts = deploy_opts(%{}, runner: recording_runner({:error, :timeout}))

      assert {:error, result} = Deploy.run("alpha", opts)
      assert result.timed_out
      assert result.exit_code == nil
      assert result.output == ""
      assert result.message =~ "did not finish within #{@declared_timeout} ms"
      assert result.message =~ "killed the process tree"

      # The deadline is handed to `Shell.run/3`, whose expiry path reads the port's `:os_pid` and calls
      # `Shell.kill_tree/1` -- so the tree dies with the call instead of outliving it. That is the only
      # tree kill this module may have: a second process runner is exactly what it must not grow.
      assert_received {:deploy_ran, _executable, _args, run_opts}
      assert run_opts[:timeout] == @declared_timeout
    end

    test "a command that cannot start, and a runner that raises, both come back as failures" do
      not_found = deploy_opts(%{}, runner: recording_runner({:error, {:not_found, "sh"}}))

      assert {:error, result} = Deploy.run("alpha", not_found)
      assert result.message =~ "could not start"
      assert result.message =~ "sh"
      refute result.timed_out

      exploding = fn _executable, _args, _opts -> raise "the runner exploded" end
      raised_opts = deploy_opts(%{}, runner: exploding)

      assert {:error, raised} = Deploy.run("alpha", raised_opts)
      assert raised.message =~ "the deploy raised: the runner exploded"
      assert raised.exit_code == nil
    end

    test "a failure built by a caller carries its message in the same shape" do
      result = Deploy.failure("alpha", "the page could not read a runner")

      assert result.project == "alpha"
      assert result.message == "the page could not read a runner"
      assert result.output == ""
      assert result.timeout_ms == Schema.Deploy.default_timeout_ms()
    end
  end

  describe "bounding the answer" do
    test "keeps the last lines of a long transcript" do
      transcript = Enum.map_join(1..100, "\n", &"line #{&1}")
      opts = deploy_opts(%{}, runner: recording_runner({:ok, transcript, 0}))

      assert {:ok, result} = Deploy.run("alpha", opts)
      assert result.truncated
      assert result.output =~ "line 61"
      assert result.output =~ "line 100"
      refute result.output =~ "line 60"
      assert result.message =~ "exit 0"
    end

    test "cuts a large tail on a character boundary, so the answer stays text" do
      huge = Enum.map_join(1..40, "\n", fn _line -> String.duplicate(@three_byte_char, 100) end)
      opts = deploy_opts(%{}, runner: recording_runner({:ok, huge, 0}))

      assert {:ok, result} = Deploy.run("alpha", opts)

      # Validity is the assertion that matters: a cut inside a character would leave bytes that are no
      # longer UTF-8, and the row would render a byte dump instead of the build's last lines.
      assert result.truncated
      assert String.valid?(result.output)
      assert result.output =~ @three_byte_char
      assert String.ends_with?(result.output, "... (truncated)")
      # 8 KiB of kept output plus the marker line `sanitize_hook_output_for_log/2` appends.
      assert byte_size(result.output) < 8_192 + 64
      assert byte_size(result.output) < byte_size(huge)
    end
  end
end
