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
end
