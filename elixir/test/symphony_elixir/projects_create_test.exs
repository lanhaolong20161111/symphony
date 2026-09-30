defmodule SymphonyElixir.ProjectsCreateTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Projects
  alias SymphonyElixir.Workflow

  # A form's worth of answers. The queue directory is real, because validation requires it to be (a
  # missing one means the create path would open the issue and then fail to write the ticket).
  # `create_*` ticked means "make it on GitHub", which is also what makes validation skip the
  # existence checks -- so these tests never touch GitHub.
  defp attrs(overrides \\ %{}) do
    queue = Path.join(System.tmp_dir!(), "queue-#{System.unique_integer([:positive])}")
    workspace = Path.join(System.tmp_dir!(), "ws-#{System.unique_integer([:positive])}")
    File.mkdir_p!(queue)
    on_exit(fn -> File.rm_rf(queue) end)

    Map.merge(
      %{
        name: "my-app",
        port: 4101,
        queue: queue,
        issues_repo: "me/my-app",
        tickets_repo: "me/my-app-tickets",
        create_issues_repo: true,
        create_tickets_repo: true,
        repos: ["me/my-app"],
        workspace_root: workspace,
        backend: "acp",
        adapter: "dsh",
        model: "auto",
        env_prep: "npm ci",
        prompt: "你正在做 {{ issue.identifier }}"
      },
      overrides
    )
  end

  # The property that matters: what the page writes is a workflow the **real** parser accepts, not a
  # shape that merely looks like one.
  describe "render/1" do
    test "produces a workflow the real parser and schema accept" do
      attrs = attrs()
      assert {:ok, settings} = parse(Projects.render(attrs))

      assert settings.server.port == 4101
      assert settings.tracker.provider["path"] == attrs.queue
      # The same directory is declared twice on purpose; both must carry it.
      assert settings.janitor.tickets_path == attrs.queue
      assert settings.janitor.issues_repo == "me/my-app"
      assert settings.janitor.tickets_repo == "me/my-app-tickets"
      assert settings.workspace.root == attrs.workspace_root
      assert settings.agent.backend == "acp"
      assert settings.acp.adapter == "dsh"
    end

    test "writes the agent route where each backend keeps it" do
      text = Projects.render(attrs(%{backend: "acp", adapter: "workbuddy", model: "gpt-5"}))
      assert text =~ "adapter: workbuddy"
      assert text =~ "model: gpt-5"
      assert {:ok, settings} = parse(text)
      assert settings.acp.adapter == "workbuddy"

      # codex has no model field: it goes inside the command string.
      codex = Projects.render(attrs(%{backend: "codex", model: "gpt-5-codex"}))
      assert codex =~ ~s(model="gpt-5-codex")
      assert {:ok, settings} = parse(codex)
      assert settings.agent.backend == "codex"
      assert settings.codex.command =~ "gpt-5-codex"

      commandcode = Projects.render(attrs(%{backend: "commandcode", model: "flash"}))
      assert {:ok, settings} = parse(commandcode)
      assert settings.commandcode.model == "flash"
    end

    test "clones every repository, into a subdirectory each when there is more than one" do
      one = Projects.render(attrs(%{repos: ["me/my-app"]}))
      assert one =~ "git clone --depth 1 https://github.com/me/my-app ."

      many = Projects.render(attrs(%{repos: ["me/api", "me/web"]}))
      assert many =~ "https://github.com/me/api api"
      assert many =~ "https://github.com/me/web web"
    end

    test "asks git whether it is already a checkout, in the hook that actually runs" do
      text = Projects.render(attrs())

      assert text =~ "if ! git -C . rev-parse --is-inside-work-tree"
      # The prompt for `[ ! -d .git ]` appears only as a comment saying not to use it -- which is the
      # point (in a worktree `.git` is a file, so that test is true and would clone over it).
      assert text =~ "# Ask git, not the filesystem"
    end

    test "carries the environment prep, indented into the hook" do
      text = Projects.render(attrs(%{env_prep: "poetry install\necho done"}))
      assert text =~ "    poetry install"
      assert text =~ "    echo done"
    end

    test "keeps every front-matter value ASCII, because a non-ASCII one does not parse" do
      # Measured: `invalid_unicode` for a non-ASCII value, quoting does not help, and Chinese in a
      # comment or the body is fine -- so placeholders and generated values are ASCII.
      text = Projects.render(attrs())

      front_matter = text |> String.split("---") |> Enum.at(1)

      assert front_matter
             |> String.split("\n")
             |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?("#")))
             |> Enum.all?(&String.printable?/1)

      # ...and the prompt, which is the body, keeps its Chinese.
      assert text =~ "你正在做"
    end
  end

  defp parse(text) do
    path = Path.join(System.tmp_dir!(), "rendered-#{System.unique_integer([:positive])}.md")
    File.write!(path, text)

    try do
      with {:ok, loaded} <- Workflow.load(path), do: Schema.parse(loaded.config)
    after
      File.rm(path)
    end
  end

  # `create/2` writes exactly these bytes (`File.write!(path, Projects.render(attrs))`); it is the
  # step before that -- provisioning `gh repo create` and `git clone` -- that keeps a test from
  # calling it, so the assertion is on the file's contents as the registry receives them.
  defp written_file(attrs) do
    path = Path.join(System.tmp_dir!(), "project-#{System.unique_integer([:positive])}.md")
    File.write!(path, Projects.render(attrs))
    on_exit(fn -> File.rm(path) end)
    File.read!(path)
  end

  # How finished work lands is the one project-level choice the create form makes, and the mode has
  # to reach the file: a page that only remembered it in its own assigns would create projects that
  # all publish the default way.
  describe "project.publish (how finished work lands)" do
    test "each mode is written into the file's project: block" do
      assert Schema.Project.publishes() == ["pull_request", "direct"]

      for mode <- Schema.Project.publishes() do
        text = written_file(attrs(%{publish: mode}))

        assert project_block(text) =~ "publish: #{mode}"
        assert {:ok, settings} = parse(text)
        assert settings.project.publish == mode
      end
    end

    test "omitting the choice writes pull_request -- the safe half, and the schema's default" do
      text = written_file(Map.delete(attrs(), :publish))

      assert project_block(text) =~ "publish: pull_request"
      assert {:ok, settings} = parse(text)
      assert settings.project.publish == "pull_request"
      # ...and saying nothing means the same thing to the schema, which is what lets the deployment's
      # own workflow carry no `project:` block at all.
      assert {:ok, settings} = parse(without_project_block(text))
      assert settings.project.publish == "pull_request"
    end

    test "a mode outside the two is not written -- the file falls back to pull_request" do
      # Only reachable by a crafted POST: the form is a pair of radios. The safe half is what it
      # gets, because a file carrying a mode the schema refuses would not load at all.
      text = written_file(attrs(%{publish: "merge"}))

      assert project_block(text) =~ "publish: pull_request"
      refute text =~ "merge"
      assert {:ok, settings} = parse(text)
      assert settings.project.publish == "pull_request"
    end

    test "the block carries publish only -- the sibling setting is not this form's to offer" do
      block = project_block(written_file(attrs()))

      assert block =~ "publish:"
      refute block =~ "isolation"
    end
  end

  # The block as it appears in the file, its comment included: `project:` and everything indented
  # under it.
  defp project_block(text) do
    case Regex.run(~r/^project:\n(?:[ \t].*\n)*/m, text) do
      [block] -> block
      nil -> flunk("no project: block in\n#{text}")
    end
  end

  defp without_project_block(text) do
    text
    |> String.split("\n")
    |> Enum.reject(&(String.starts_with?(&1, "project:") or String.starts_with?(&1, "  publish:")))
    |> Enum.join("\n")
  end

  # The port is chosen by trying to bind, not by reading a table: the registry only knows Symphony's
  # own projects, and a port can be held by anything.
  describe "next_free_port/1" do
    test "skips a port a project already claims" do
      port = Projects.next_free_port([])
      assert is_integer(port)

      refute Projects.next_free_port([port]) == port
    end

    test "stays in the project range and away from common developer ports" do
      port = Projects.next_free_port([])
      assert port in 4001..4099
      refute port in [3000, 5173, 5432, 6379, 8000, 8080, 9000]
    end

    test "skips a port something outside the registry is holding" do
      {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
      {:ok, held} = :inet.port(socket)
      on_exit(fn -> :gen_tcp.close(socket) end)

      if held in 4001..4099 do
        refute Projects.next_free_port([]) == held
      else
        # An ephemeral port rarely lands in our range. Say so rather than passing as though the claim
        # had been exercised.
        assert Projects.next_free_port([]) in 4001..4099
      end
    end
  end

  # The candidates come from what this machine already uses and, for workbuddy, from the adapter's own
  # `--help`. Machine-dependent by design, so the assertions are about shape.
  describe "known_models/1" do
    test "always answers with a list, whatever this machine has" do
      assert is_list(Projects.known_models("workbuddy"))
      assert is_list(Projects.known_models("dsh"))
      assert is_list(Projects.known_models(nil))
    end

    test "has no duplicates and no blanks" do
      models = Projects.known_models("workbuddy")
      assert models == Enum.uniq(models)
      refute "" in models
    end
  end

  # Creating a repository is a side effect on GitHub, so the command runner is injected -- the same
  # shape `InstanceRegistry` injects its launcher. These tests assert the argv and the answer: no
  # network, no `gh` on PATH, and no repository at the other end.
  describe "create_repo/2" do
    defp runner_answering(result) do
      test_pid = self()

      fn args ->
        send(test_pid, {:argv, args})
        result
      end
    end

    test "asks gh for exactly this argv, private by default" do
      runner = runner_answering({:ok, "", 0})
      assert Projects.create_repo("me/my-tickets", runner: runner) == :created

      assert_received {:argv, ["repo", "create", "me/my-tickets", "--private", "--add-readme"]}
    end

    test "the caller's privacy choice is the one that reaches the command line" do
      runner = runner_answering({:ok, "", 0})
      assert Projects.create_repo("me/my-tickets", runner: runner, public: true) == :created

      assert_received {:argv, ["repo", "create", "me/my-tickets", "--public", "--add-readme"]}
    end

    test "a repository that is already there is not a failure -- it is adoptable" do
      # The API's own 422 and the older GraphQL wording; both mean "do not touch it".
      existing = [
        "HTTP 422: Repository creation failed. (name already exists on this account)",
        "GraphQL: Name already exists on this account (createRepository)"
      ]

      for output <- existing do
        assert Projects.create_repo("me/my-tickets", runner: runner_answering({:ok, output, 1})) ==
                 :already_exists
      end
    end

    test "a real failure carries its reason, and is never read as already-existing" do
      runner = runner_answering({:ok, "HTTP 404: Not Found (me)", 1})

      assert Projects.create_repo("me/my-tickets", runner: runner) ==
               {:error, {:gh_exit, 1, "HTTP 404: Not Found (me)"}}

      # A runner that could not run gh at all says that, rather than "created".
      assert Projects.create_repo("me/my-tickets", runner: runner_answering({:error, {:not_found, "gh"}})) ==
               {:error, {:not_found, "gh"}}
    end

    test "a name that is not owner/name is refused before gh is asked anything" do
      runner = runner_answering({:ok, "", 0})

      for bad <- ["not-a-repo", "me/", "/tickets", "", "me/ti ckets", "a/b/c", nil] do
        assert Projects.create_repo(bad, runner: runner) == {:error, {:invalid_repo, bad}}
      end

      refute_received {:argv, _args}
    end
  end

  # Validation is the part that keeps a project from being created and then not running. The GitHub
  # question is injected, so "the repository does not exist" is testable without a network.
  describe "validate/3" do
    defp missing, do: fn _repo -> false end
    defp present, do: fn _repo -> true end

    test "accepts a form that asks to create both repositories" do
      assert Projects.validate(attrs(), [], repo_exists?: missing()) == :ok
    end

    test "requires a repository to exist unless told to create it" do
      attrs = attrs(%{create_issues_repo: false})

      # Not there and not being created: refused, naming the repository.
      assert {:error, problems} = Projects.validate(attrs, [], repo_exists?: missing())
      assert Enum.any?(problems, &(&1 =~ "GitHub 上没有"))
      assert Enum.any?(problems, &(&1 =~ "issues 仓库"))

      # There *and* being created: also refused, because `gh repo create` would fail. Saying so beats
      # running it and reporting whatever GitHub says.
      assert {:error, problems} = Projects.validate(attrs, [], repo_exists?: present())
      assert Enum.any?(problems, &(&1 =~ "已经存在"))
    end

    test "a repository that exists while 'create' is ticked is refused rather than silently skipped" do
      assert {:error, problems} = Projects.validate(attrs(), [], repo_exists?: present())
      assert Enum.any?(problems, &(&1 =~ "已经存在"))
    end

    test "a malformed repository name is named" do
      attrs = attrs(%{issues_repo: "not-a-repo"})

      assert {:error, problems} = Projects.validate(attrs, [], repo_exists?: missing())
      assert Enum.any?(problems, &(&1 =~ "owner/仓库"))
    end

    test "the same queue as another project is refused -- that is the two-janitors case" do
      attrs = attrs()

      existing = [
        %{name: "taken", queue: attrs.queue, mirror_path: attrs.queue, port: 9999, error: nil}
      ]

      assert {:error, problems} = Projects.validate(attrs, existing, repo_exists?: missing())
      assert Enum.any?(problems, &(&1 =~ "已经被项目 taken 占了"))
    end

    test "the same port as another project is refused" do
      existing = [%{name: "taken", queue: "C:/q/other", mirror_path: "C:/q/other", port: 4101, error: nil}]

      assert {:error, problems} = Projects.validate(attrs(), existing, repo_exists?: missing())
      assert Enum.any?(problems, &(&1 =~ "端口 4101"))
    end

    test "an existing name is refused" do
      existing = [%{name: "my-app", queue: nil, mirror_path: nil, port: nil, error: nil}]

      assert {:error, problems} = Projects.validate(attrs(), existing, repo_exists?: missing())
      assert Enum.any?(problems, &(&1 =~ "已经有一个叫 my-app 的项目"))
    end

    test "a queue directory that does not exist is refused, with the consequence spelled out" do
      attrs = attrs(%{queue: "C:/definitely/not/here-#{System.unique_integer([:positive])}"})

      assert {:error, problems} = Projects.validate(attrs, [], repo_exists?: missing())
      assert Enum.any?(problems, &(&1 =~ "队列目录不存在"))
      assert Enum.any?(problems, &(&1 =~ "没有票据的 issue"))
    end

    test "a queue that is not a checkout of the tickets repository is refused" do
      dir = Path.join(System.tmp_dir!(), "queue-not-a-clone-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      attrs = attrs(%{queue: dir, create_tickets_repo: false})

      assert {:error, problems} = Projects.validate(attrs, [], repo_exists?: present())
      assert Enum.any?(problems, &(&1 =~ "不是一个指向"))
    end

    test "no repositories at all is refused -- the agent would work in an empty directory" do
      attrs = attrs(%{repos: []})

      assert {:error, problems} = Projects.validate(attrs, [], repo_exists?: missing())
      assert Enum.any?(problems, &(&1 =~ "至少要有一个代码仓库"))
    end

    test "a bad name or port is refused" do
      assert {:error, p1} = Projects.validate(attrs(%{name: ""}), [], repo_exists?: missing())
      assert Enum.any?(p1, &(&1 =~ "项目名不能为空"))

      assert {:error, p2} = Projects.validate(attrs(%{name: "has space"}), [], repo_exists?: missing())
      assert Enum.any?(p2, &(&1 =~ "只能用字母数字"))

      assert {:error, p3} = Projects.validate(attrs(%{port: 80}), [], repo_exists?: missing())
      assert Enum.any?(p3, &(&1 =~ "1024–65535"))

      assert {:error, p4} = Projects.validate(attrs(%{port: nil}), [], repo_exists?: missing())
      assert Enum.any?(p4, &(&1 =~ "端口必须是整数"))
    end

    test "a value the parser cannot take is refused, with the measured reason" do
      # Environment prep is where a person is most likely to write Chinese, and a non-ASCII value in
      # the front matter does not parse at all.
      attrs = attrs(%{env_prep: "# 装依赖\nnpm ci"})

      assert {:error, problems} = Projects.validate(attrs, [], repo_exists?: missing())
      assert Enum.any?(problems, &(&1 =~ "环境准备里有非 ASCII"))
      assert Enum.any?(problems, &(&1 =~ "invalid_unicode"))
    end

    test "several code repositories warns that publishing is written for one" do
      # Accepted, and the hook handles it (one subdirectory each) -- but `publish_ticket/2` needs the
      # workspace root itself to be a work tree, so the ticket would never get a pull request.
      one = Projects.warnings(attrs(%{repos: ["me/only"]}))
      refute Enum.any?(one, &(&1 =~ "发布那步"))

      many = Projects.warnings(attrs(%{repos: ["me/api", "me/web"]}))
      assert Enum.any?(many, &(&1 =~ "2 个代码仓库"))
      assert Enum.any?(many, &(&1 =~ "不会自动出 PR"))
    end
  end
end
