defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from normalized tracker work item data.
  """

  alias SymphonyElixir.{AgentIdentity, Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @doc """
  Builds the prompt for one turn.

  Four variables are available to the template: `issue`, `attempt`, `agent` and `run`. The last two
  exist so that "which agent am I?" is answerable *by construction* -- before them, the agent had no
  channel to learn its own backend, model or session, and a ticket asking was unanswerable no matter
  how well it was written. `opts[:run]` carries what only the caller knows: the workspace, the
  session id and the turn number.
  """
  @spec build_prompt(SymphonyElixir.Tracker.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" => issue |> Map.from_struct() |> to_solid_map(),
        "agent" => agent_context(),
        "run" => run_context(Keyword.get(opts, :run, %{}))
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
  end

  # Names are stable and documented; `model` may be nil on the codex backend (see AgentIdentity).
  defp agent_context do
    identity = AgentIdentity.current()

    %{
      "backend" => identity.backend,
      "adapter" => identity.adapter,
      "model" => identity.model
    }
  end

  # `session_id` is the agent's own session -- the same string `/api/v1/state` reports for this run,
  # so an agent that answers "which session am I?" and a person reading the API agree.
  defp run_context(run) do
    %{
      "workspace" => Map.get(run, :workspace),
      "session_id" => Map.get(run, :session_id),
      "turn" => Map.get(run, :turn)
    }
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
