defmodule SymphonyElixirWeb.ProjectPublishLiveTest do
  # async: false -- every test renders a real route, moves `:projects_dir` and (for the settings
  # page) reads the running configuration.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    registry_config = Application.get_env(:symphony_elixir, :projects_dir)

    registry = Path.join(System.tmp_dir!(), "publish-live-#{System.unique_integer([:positive])}")
    File.mkdir_p!(registry)
    Application.put_env(:symphony_elixir, :projects_dir, registry)

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)

      if registry_config,
        do: Application.put_env(:symphony_elixir, :projects_dir, registry_config),
        else: Application.delete_env(:symphony_elixir, :projects_dir)

      File.rm_rf(registry)
    end)

    :ok
  end

  # The mode is a choice between two values, so the page is where "which one" has to be visible --
  # before and after it is written into the file.
  test "the create form offers both modes, with pull_request preselected" do
    start_test_endpoint()
    {:ok, view, html} = live(build_conn(), "/projects/new")

    for mode <- Schema.Project.publishes() do
      assert html =~ ~s(name="project[publish]" value="#{mode}")
    end

    # One short line each, so the choice is made on what it does rather than on the word.
    assert html =~ "推一个分支并开 pull request"
    assert html =~ "不开 pull request"

    assert view
           |> element(~s(input[name="project[publish]"][value="pull_request"]))
           |> render() =~ "checked"

    refute view
           |> element(~s(input[name="project[publish]"][value="direct"]))
           |> render() =~ "checked"
  end

  test "choosing the other mode is what the form then carries" do
    start_test_endpoint()
    {:ok, view, _html} = live(build_conn(), "/projects/new")

    view
    |> form("form[phx-submit=create]",
      project: %{
        "name" => "my-app",
        "port" => "4123",
        "queue" => Path.join(System.tmp_dir!(), "publish-queue"),
        "issues_repo" => "me/my-app",
        "tickets_repo" => "me/my-app-tickets",
        "create_issues_repo" => "true",
        "create_tickets_repo" => "true",
        "repos" => "me/my-app",
        "workspace_root" => Path.join(System.tmp_dir!(), "ws-my-app"),
        "backend" => "acp",
        "adapter" => "dsh",
        "model" => "auto",
        "publish" => "direct",
        "env_prep" => "",
        "prompt" => "prompt"
      }
    )
    |> render_change()

    assert view
           |> element(~s(input[name="project[publish]"][value="direct"]))
           |> render() =~ "checked"

    refute view
           |> element(~s(input[name="project[publish]"][value="pull_request"]))
           |> render() =~ "checked"
  end

  # The failure path: a form that cannot be created has to come back with what is wrong, in the
  # page, rather than taking the LiveView down -- and it must not get as far as writing a file or
  # creating a repository (validation runs first, which is why a queue that does not exist is
  # enough to stop it).
  test "a form that cannot be created renders the problems instead of raising" do
    start_test_endpoint()
    {:ok, view, _html} = live(build_conn(), "/projects/new")

    missing_queue =
      Path.join(System.tmp_dir!(), "publish-missing-#{System.unique_integer([:positive])}")

    html =
      view
      |> form("form[phx-submit=create]",
        project: %{
          "name" => "broken-app",
          "port" => "4124",
          "queue" => missing_queue,
          "issues_repo" => "me/broken-app",
          "tickets_repo" => "me/broken-app-tickets",
          "create_issues_repo" => "true",
          "create_tickets_repo" => "true",
          "repos" => "me/broken-app",
          "workspace_root" => Path.join(System.tmp_dir!(), "ws-broken-app"),
          "backend" => "acp",
          "adapter" => "dsh",
          "model" => "auto",
          "publish" => "direct",
          "env_prep" => "",
          "prompt" => "prompt"
        }
      )
      |> render_submit()

    assert html =~ "还差这些"
    assert html =~ "队列目录不存在"
    assert html =~ missing_queue

    # Still a page, still holding the choice that was made.
    assert render(view) =~ "完工怎么落地"
    refute File.exists?(Path.join(projects_dir(), "broken-app.md"))
  end

  # The settings page: the running project's mode, in words and in a picker, without opening the
  # YAML. The write itself is the generic curated-key path (`Settings.update/2`), which is where it
  # is asserted.
  test "the settings page shows the running project's publish mode and offers both" do
    start_test_endpoint()
    {:ok, _view, html} = live(build_conn(), "/settings")

    assert html =~ "project.publish"
    assert html =~ ~s(<option value="pull_request")
    assert html =~ ~s(<option value="direct")
    # The mode in force, selected in the picker -- the test workflow declares no `project:` block,
    # so this is the schema's default rather than a value read out of a file.
    assert html =~ ~s(value="pull_request" selected)
    refute html =~ ~s(value="direct" selected)
  end

  defp projects_dir, do: Application.get_env(:symphony_elixir, :projects_dir)

  defp start_test_endpoint(overrides \\ []) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end
end
