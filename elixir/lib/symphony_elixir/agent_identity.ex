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

  @doc """
  The identity for one ticket: the project's route, with the ticket's own choices applied **where the
  runtime can honour them**.

  ## Why this is the same function, not a second one

  `current/1` exists because the prompt, the dashboard and the actual run must not be able to
  disagree about who is working. Nothing about that changes here -- this is the same resolution,
  given the ticket, and all three callers already hold the ticket.

  ## Where a ticket may override, and where it may not

  * **`:model`** -- honoured on the ACP and CommandCode backends, whose model is a setting. On the
    codex backend the model lives inside `codex.command`, a shell string, so only that command knows
    it; a per-ticket model cannot be honoured there, and the project's answer is reported instead of
    the request being silently dropped.
  * **`:adapter`** -- honoured when the backend is ACP, because an adapter is what ACP has. A ticket
    asking for `workbuddy` inside a `codex` project gets the project's answer: a per-ticket backend
    would mean two session mechanisms inside one project, which is a different change with a
    different blast radius. Saying what will actually run matters more than accepting the value.

  A ticket naming neither gets exactly the configuration, so every ticket that exists today behaves
  exactly as it did.
  """
  @spec for_issue(map() | nil, map() | nil) :: t()
  def for_issue(issue, settings \\ nil) do
    resolve(current(settings || Config.settings!()), issue)
  end

  @doc """
  Applies a ticket's own choices to a base identity -- **the one place that rule lives**.

  Two callers provide the base from different places: the runner, the prompt and the dashboard from
  the running configuration, and the task page from the *selected project's* parsed workflow (which
  is not this instance's). Both then use this function, so the preview cannot promise a route the
  runner would not take.
  """
  @spec resolve(t(), map() | nil) :: t()
  def resolve(base, nil), do: base

  def resolve(base, issue) do
    %{
      backend: base.backend,
      adapter: override(base.adapter, Map.get(issue, :adapter), base.backend == "acp"),
      model: override(base.model, Map.get(issue, :model), base.backend in ["acp", "commandcode"])
    }
  end

  # A blank value is not a request -- including a value that is only whitespace, which is what a form
  # field left half-touched produces. A request the runtime cannot honour leaves the project's answer
  # in place, so what is reported is what will run.
  defp override(base, requested, allowed) do
    requested = if is_binary(requested), do: requested |> String.trim() |> blank_to_nil(), else: requested

    cond do
      requested == nil -> base
      not allowed -> base
      true -> requested
    end
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
