defmodule SymphonyElixir.CodexChildEnvTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Workflow

  # `codex.child_env` is the deliberate opposite of `secret_environment_names`: one keeps a tracker
  # token away from the agent, the other hands the agent a credential it needs to push. What is worth
  # pinning is the precedence when a workflow asks for both, and that a variable this process does not
  # have is omitted rather than passed through empty.

  setup do
    {:ok, binding: %{secret_environment_names: ["LINEAR_API_KEY"], tool_specs: []}}
  end

  test "a named variable is passed through with the value this process has", %{binding: binding} do
    restore_env("SYMPHONY_CHILD_ENV_PROBE", "from-the-parent")

    write_workflow_file!(Workflow.workflow_file_path(), codex_child_env: ["SYMPHONY_CHILD_ENV_PROBE"])

    assert {~c"SYMPHONY_CHILD_ENV_PROBE", ~c"from-the-parent"} in AppServer.child_env("/tmp/ws", binding)
  end

  test "a variable this process does not have is omitted, not set empty", %{binding: binding} do
    restore_env("SYMPHONY_CHILD_ENV_ABSENT", nil)

    write_workflow_file!(Workflow.workflow_file_path(), codex_child_env: ["SYMPHONY_CHILD_ENV_ABSENT"])

    env = AppServer.child_env("/tmp/ws", binding)

    refute Enum.any?(env, &match?({~c"SYMPHONY_CHILD_ENV_ABSENT", _value}, &1))
  end

  test "a tracker secret wins over the allow-list", %{binding: binding} do
    restore_env("LINEAR_API_KEY", "tracker-token")
    write_workflow_file!(Workflow.workflow_file_path(), codex_child_env: ["LINEAR_API_KEY"])

    env = AppServer.child_env("/tmp/ws", binding)

    assert {~c"LINEAR_API_KEY", false} in env
    refute Enum.any?(env, fn {name, value} -> name == ~c"LINEAR_API_KEY" and value != false end)
  end

  test "git is told to trust the workspace only when the agent may write git metadata",
       %{binding: binding} do
    write_workflow_file!(Workflow.workflow_file_path(), codex_git_metadata_writable: false)

    refute Enum.any?(
             AppServer.child_env("/tmp/ws", binding),
             &match?({~c"GIT_CONFIG_KEY_0", _value}, &1)
           )

    write_workflow_file!(Workflow.workflow_file_path(), codex_git_metadata_writable: true)
    env = AppServer.child_env("/tmp/ws", binding)

    assert {~c"GIT_CONFIG_COUNT", ~c"1"} in env
    assert {~c"GIT_CONFIG_KEY_0", ~c"safe.directory"} in env
    assert {~c"GIT_CONFIG_VALUE_0", ~c"*"} in env
  end

  test "nothing is passed through by default", %{binding: binding} do
    restore_env("SYMPHONY_CHILD_ENV_PROBE", "from-the-parent")
    write_workflow_file!(Workflow.workflow_file_path(), [])

    env = AppServer.child_env("/tmp/ws", binding)

    assert env == [{~c"LINEAR_API_KEY", false}]
  end
end
