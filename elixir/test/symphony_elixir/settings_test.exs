defmodule SymphonyElixir.SettingsTest do
  # async: false -- the write path goes through `Workflow.set_workflow_file_path/1`, which is
  # application-global (and makes the running WorkflowStore reload).
  use ExUnit.Case, async: false

  alias SymphonyElixir.{Settings, Workflow}

  @workflow """
  ---
  tracker:
    kind: file
    provider:
      path: C:/Users/lhl20/code/symphony-tickets
    active_states:
      - ready
  janitor:
    enabled: true
    interval_ms: 30000
    issues_repo: lanhaolong20161111/beekeeper
  agent:
    max_concurrent_agents: 1
    max_turns: 5
  ---

  Prompt body.
  """

  setup do
    path = Path.join(System.tmp_dir!(), "settings-#{System.unique_integer([:positive])}.md")
    File.write!(path, @workflow)

    # The app env, NOT `Workflow.set_workflow_file_path/1`: that one also tells the running
    # `WorkflowStore` to reload, and restoring it afterwards can leave the store holding *this* file
    # -- `WORKFLOW.md` in the test environment is a github tracker with no token, so the reload back
    # to it fails and the store keeps the last good configuration, which would then be a temp file
    # that no longer exists. Measured: it showed up as an unrelated workspace test failing only in
    # the full run.
    Application.put_env(:symphony_elixir, :workflow_file_path, path)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :workflow_file_path)
      File.rm(path)
      File.rm(path <> ".bak")
    end)

    {:ok, path: path}
  end

  describe "effective/0" do
    test "reports the running configuration, grouped for display" do
      assert {:ok, sections} = Settings.effective()

      titles = Enum.map(sections, & &1.title)
      assert "GitHub" in titles
      assert "janitor" in titles
      assert "agent" in titles
      assert "acp / codex" in titles

      github = Enum.find(sections, &(&1.title == "GitHub"))
      assert {"issues 仓库", _} = Enum.find(github.rows, fn {key, _} -> key == "issues 仓库" end)
    end

    test "every row is a two-tuple, so the page never has to know the schema's shape" do
      {:ok, sections} = Settings.effective()

      for section <- sections, row <- section.rows do
        assert {key, _value} = row
        assert is_binary(key)
      end
    end
  end

  describe "credentials/0" do
    test "reports presence and never a value" do
      credentials = Settings.credentials()

      refute credentials == []
      assert Enum.any?(credentials, &(&1.name == "CMD_API_KEY"))
      assert Enum.any?(credentials, &(&1.name == "CODEBUDDY_AUTH_TOKEN"))

      for credential <- credentials do
        assert Map.has_key?(credential, :process?)
        assert Map.has_key?(credential, :user_scope?)
        assert Map.has_key?(credential, :length)
        # The whole point: no field carries the secret, not even a masked one.
        refute Map.has_key?(credential, :value)
      end
    end

    test "length is a count, never the value itself" do
      for credential <- Settings.credentials() do
        case credential.length do
          nil -> :ok
          length -> assert is_integer(length) and length >= 0
        end
      end
    end
  end

  describe "update/2" do
    test "writes a valid value, and keeps the original beside it" do
      assert {:ok, path} = Settings.update(["janitor", "issues_repo"], "owner/other")

      assert File.read!(path) =~ "issues_repo: owner/other"
      assert File.read!(path <> ".bak") =~ "issues_repo: lanhaolong20161111/beekeeper"
    end

    test "refuses a value the schema rejects, and does NOT touch the file" do
      before = File.read!(effective_path())

      # `interval_ms` must be greater than zero; zero is the smallest thing a person is likely to
      # type by accident, and it is exactly what this guard exists for.
      assert {:error, _reason} = Settings.update(["janitor", "interval_ms"], "0")

      assert File.read!(effective_path()) == before
      refute File.exists?(effective_path() <> ".bak")
    end

    test "refuses a non-integer for an integer key" do
      assert {:error, {:not_an_integer, "soon"}} = Settings.update(["janitor", "interval_ms"], "soon")
    end

    test "refuses a non-boolean for a boolean key" do
      assert {:error, {:not_a_boolean, "maybe"}} = Settings.update(["janitor", "enabled"], "maybe")
      assert {:ok, _} = Settings.update(["janitor", "enabled"], "false")
    end

    test "refuses a key outside the curated list" do
      assert {:error, {:not_editable, ["tracker", "kind"]}} =
               Settings.update(["tracker", "kind"], "github")
    end

    test "refuses to write a section as a scalar" do
      assert {:error, _reason} = Settings.update(["janitor"], "oops")
    end
  end

  describe "loopback_peer?/1 (the whole guard on the write path)" do
    test "accepts loopback, both families" do
      assert Settings.loopback_peer?(%{address: {127, 0, 0, 1}})
      assert Settings.loopback_peer?(%{address: {127, 9, 9, 9}})
      assert Settings.loopback_peer?(%{address: {0, 0, 0, 0, 0, 0, 0, 1}})
    end

    test "refuses anything else -- a LAN address, a tailnet address, a malformed peer" do
      refute Settings.loopback_peer?(%{address: {192, 168, 1, 5}})
      refute Settings.loopback_peer?(%{address: {100, 64, 0, 1}})
      refute Settings.loopback_peer?(%{address: {10, 0, 0, 7}})
      refute Settings.loopback_peer?(%{address: {0, 0, 0, 0}})
      refute Settings.loopback_peer?(nil)
      refute Settings.loopback_peer?(%{})
    end
  end

  defp effective_path, do: Workflow.workflow_file_path()
end
