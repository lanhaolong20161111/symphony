defmodule SymphonyElixir.AgentIdentity do
  @moduledoc """
  Which agent is actually running: the backend, the adapter and the model.

  Two things need to say this, and they must not be able to disagree:

    * **the prompt the agent is given.** A ticket asking "which model are you?" previously had no
      answer the agent could give. The template could interpolate only `issue.*` and `attempt`, and
      because rendering uses `strict_variables: true`, a workflow could not even name the missing
      variable -- so the agent went looking for itself in the workspace, found nothing, and
      improvised. That is a missing channel, not a confused agent.
    * **the observability payload**, so a person reading `/api/v1/state` or the dashboard can see
      which route a run is on. Until this existed, the only way to answer that was to open the
      agent's rollout file in `~/.codex/sessions`, which is not something a person should have to do.

  ## Why the model is best-effort on the codex backend

  `acp.model` and `commandcode.model` are configuration fields. The codex backend has no such field:
  its model lives inside `codex.command`, a shell string handed to `bash -lc`, and the rest of its
  route lives in `~/.codex/config.toml`. So for codex this reads a `model=` or `-m/--model` out of
  the command when the workflow pins one, and reports `nil` when it does not -- which is the honest
  answer, because in that case only codex's own configuration knows.
  """

  alias SymphonyElixir.Config

  @typedoc "Who is running. `adapter` and `model` are `nil` when they do not apply or are not pinned."
  @type t :: %{backend: String.t(), adapter: String.t() | nil, model: String.t() | nil}

  @doc """
  The identity implied by the configuration.

  Takes settings explicitly so it can be tested without a workflow; defaults to the live settings.
  """
  @spec current(map() | nil) :: t()
  def current(settings \\ nil) do
    settings = settings || Config.settings!()

    %{
      backend: settings.agent.backend,
      adapter: adapter(settings),
      model: model(settings)
    }
  end

  # Only the ACP backend has an adapter; for the others the field would be a lie.
  defp adapter(%{agent: %{backend: "acp"}, acp: acp}), do: blank_to_nil(acp.adapter)
  defp adapter(_settings), do: nil

  defp model(%{agent: %{backend: "acp"}, acp: acp}), do: blank_to_nil(acp.model)

  defp model(%{agent: %{backend: "commandcode"}, commandcode: commandcode}),
    do: blank_to_nil(commandcode.model)

  defp model(%{agent: %{backend: "codex"}, codex: codex}), do: codex_model(codex.command)
  defp model(_settings), do: nil

  # `--config model="x"`, `--config 'model="x"'`, `-m x`, `--model x`.
  #
  # `model_provider=` deliberately does not match: after `model` comes `_`, so the literal `model=`
  # never appears in it.
  defp codex_model(command) when is_binary(command) do
    [
      ~r/model=\s*["']?([^"'\s]+)/,
      ~r/(?:^|\s)(?:-m|--model)\s+["']?([^"'\s]+)/
    ]
    |> Enum.find_value(fn pattern ->
      case Regex.run(pattern, command) do
        [_, value] -> blank_to_nil(value)
        _ -> nil
      end
    end)
  end

  defp codex_model(_command), do: nil

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value
end
