defmodule SymphonyElixir.AgentIdentityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentIdentity
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.{Acp, Agent, Codex, CommandCode}

  defp settings(backend, opts) do
    %Schema{
      agent: %Agent{backend: backend},
      acp: struct(Acp, Keyword.take(opts, [:adapter, :model])),
      commandcode: struct(CommandCode, Keyword.take(opts, [:model])),
      codex: struct(Codex, Keyword.take(opts, [:command]))
    }
  end

  describe "the ACP backend" do
    test "reports the adapter and the model route, verbatim" do
      # DSH's model is a JSON string, and it must be reported exactly as configured: it is the value
      # that gets handed back to session/set_config_option.
      identity =
        AgentIdentity.current(
          settings("acp", adapter: "dsh", model: ~s(["commandcode","deepseek/deepseek-v4.1-flash"]))
        )

      assert identity.backend == "acp"
      assert identity.adapter == "dsh"
      assert identity.model == ~s(["commandcode","deepseek/deepseek-v4.1-flash"])
    end

    test "an unset model is nil, not an empty string" do
      identity = AgentIdentity.current(settings("acp", adapter: "workbuddy", model: ""))

      assert identity.adapter == "workbuddy"
      assert identity.model == nil
    end
  end

  describe "the commandcode backend" do
    test "reports its own model field" do
      identity = AgentIdentity.current(settings("commandcode", model: "deepseek-v4.1-flash"))

      assert identity.backend == "commandcode"
      assert identity.model == "deepseek-v4.1-flash"
      # Only the ACP backend has an adapter; reporting one here would be a lie.
      assert identity.adapter == nil
    end
  end

  describe "the codex backend" do
    # Codex has no model field: its model lives inside `codex.command`, a shell string handed to
    # `bash -lc`. The rest of its route lives in ~/.codex/config.toml, which is why this is
    # best-effort and why nil is a legitimate answer.

    test "reads the model out of the command the way this deployment writes it" do
      command =
        ~s(codex --config shell_environment_policy.inherit=all --config model_provider='"commandcode"' ) <>
          ~s(--config 'model="deepseek/deepseek-v4.1-flash"' app-server)

      assert AgentIdentity.current(settings("codex", command: command)).model ==
               "deepseek/deepseek-v4.1-flash"
    end

    test "does not mistake model_provider= for model=" do
      command = ~s(codex --config model_provider='"commandcode"' app-server)

      assert AgentIdentity.current(settings("codex", command: command)).model == nil
    end

    test "reads -m and --model too" do
      assert AgentIdentity.current(settings("codex", command: "codex -m gpt-5.5 app-server")).model ==
               "gpt-5.5"

      assert AgentIdentity.current(settings("codex", command: "codex --model gpt-5.5 app-server")).model ==
               "gpt-5.5"
    end

    test "a workflow that pins nothing reports nil rather than guessing" do
      # The default command, and the default in this fork's own schema.
      assert AgentIdentity.current(settings("codex", command: "codex app-server")).model == nil
      assert AgentIdentity.current(settings("codex", command: nil)).model == nil
    end
  end

  # A ticket may name its own agent route. `resolve/2` is the one place that decides how far the
  # request goes, and it is shared by the runner, the prompt, the dashboard and the task page's
  # preview -- so what the page promises and what runs cannot disagree.
  describe "resolve/2 -- what a ticket is allowed to override" do
    test "a ticket that asks for nothing gets exactly the base" do
      base = %{backend: "acp", adapter: "dsh", model: "auto"}

      assert AgentIdentity.resolve(base, nil) == base
      assert AgentIdentity.resolve(base, %{}) == base
      assert AgentIdentity.resolve(base, %{adapter: nil, model: nil}) == base
    end

    test "blank is not a request" do
      base = %{backend: "acp", adapter: "dsh", model: "auto"}

      assert AgentIdentity.resolve(base, %{adapter: "", model: "   "}) == base
    end

    test "on ACP a ticket may pick the adapter, the model, or both" do
      base = %{backend: "acp", adapter: "dsh", model: "auto"}

      assert AgentIdentity.resolve(base, %{adapter: "workbuddy", model: "gpt-5"}) ==
               %{backend: "acp", adapter: "workbuddy", model: "gpt-5"}

      assert AgentIdentity.resolve(base, %{model: "gpt-5"}) ==
               %{backend: "acp", adapter: "dsh", model: "gpt-5"}

      assert AgentIdentity.resolve(base, %{adapter: "workbuddy"}) ==
               %{backend: "acp", adapter: "workbuddy", model: "auto"}
    end

    test "on codex neither is honoured -- the base is reported, not the request" do
      # The model lives inside `codex.command` and there is no adapter concept, so what comes back is
      # what will actually run. Saying otherwise would be the panel lying.
      base = %{backend: "codex", adapter: nil, model: "gpt-5-codex"}

      assert AgentIdentity.resolve(base, %{adapter: "workbuddy", model: "something-else"}) == base
    end

    test "on CommandCode a model is honoured, an adapter is not" do
      base = %{backend: "commandcode", adapter: nil, model: "default-model"}

      assert AgentIdentity.resolve(base, %{model: "other-model"}) ==
               %{backend: "commandcode", adapter: nil, model: "other-model"}

      assert AgentIdentity.resolve(base, %{adapter: "workbuddy"}).adapter == nil
    end

    test "the backend itself is never taken from the ticket" do
      # A per-ticket backend would mean two session mechanisms inside one project. Ignored, not
      # half-honoured.
      base = %{backend: "codex", adapter: nil, model: nil}

      assert AgentIdentity.resolve(base, %{backend: "acp", model: "x"}).backend == "codex"
    end
  end

  describe "for_issue/2 -- the same rule, on the configured base" do
    test "applies the ticket's request to the project's route" do
      settings = settings("acp", adapter: "dsh", model: "auto")

      assert AgentIdentity.for_issue(%{adapter: "workbuddy", model: "gpt-5"}, settings) ==
               %{backend: "acp", adapter: "workbuddy", model: "gpt-5"}
    end

    test "a ticket with no request is exactly the configuration" do
      settings = settings("acp", adapter: "dsh", model: "auto")

      assert AgentIdentity.for_issue(%{}, settings) == AgentIdentity.current(settings)
      assert AgentIdentity.for_issue(nil, settings) == AgentIdentity.current(settings)
    end
  end
end
