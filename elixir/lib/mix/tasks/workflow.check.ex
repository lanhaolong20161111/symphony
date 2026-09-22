defmodule Mix.Tasks.Workflow.Check do
  use Mix.Task

  alias SymphonyElixir.{Config, PromptBuilder, Workflow}
  alias SymphonyElixir.Tracker.Issue

  @moduledoc """
  Validates `WORKFLOW.md` without starting anything.

  Two things are checked, because only the first is covered today:

    1. the front matter against the config schema (`Config.settings!/0`), and
    2. the prompt body by rendering it once against a sample issue.

  The body is a template that is only rendered when a run starts, so a typo in it fails *runs* --
  mid-flight, one issue at a time -- rather than failing the gate. Rendering it here moves that
  failure to where it is cheap.
  """

  @shortdoc "Validates WORKFLOW.md (config schema + prompt template)"

  @sample_issue %Issue{
    id: "workflow-check",
    identifier: "MT-0",
    title: "Workflow check",
    description: "Rendered by mix workflow.check to prove the template compiles.",
    state: "open",
    url: "https://example.invalid/MT-0",
    labels: ["workflow-check"]
  }

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(_args) do
    Mix.Task.run("compile", [])
    Mix.shell().info("workflow.check: #{Workflow.workflow_file_path()}")

    _prompt = load_prompt!()
    settings = load_settings!()

    Mix.shell().info(
      "  tracker=#{settings.tracker.kind} backend=#{settings.agent.backend} " <>
        "max_concurrent=#{settings.agent.max_concurrent_agents} max_turns=#{settings.agent.max_turns} " <>
        "workspace_root=#{settings.workspace.root}"
    )

    rendered = render_prompt!()

    if is_binary(rendered) and String.contains?(rendered, @sample_issue.identifier) do
      Mix.shell().info("  prompt template renders (#{byte_size(rendered)} bytes)")
      Mix.shell().info("workflow.check: ok")
      :ok
    else
      Mix.raise(
        "WORKFLOW.md prompt rendered without the issue identifier; the template probably drops " <>
          "its variables"
      )
    end
  end

  defp load_prompt! do
    case Workflow.load() do
      {:ok, %{prompt: prompt}} when is_binary(prompt) and prompt != "" ->
        prompt

      {:ok, _loaded} ->
        Mix.raise("WORKFLOW.md has no prompt body; runs would start with an empty brief")

      {:error, reason} ->
        Mix.raise("WORKFLOW.md is not valid: #{inspect(reason, limit: 5, printable_limit: 500)}")
    end
  end

  defp load_settings! do
    Config.settings!()
  rescue
    error ->
      message = Exception.message(error)
      Mix.raise("WORKFLOW.md fails config validation: #{message}#{config_hint(message)}")
  end

  # The config validates the tracker's credentials too, so a missing token surfaces here. Say which
  # variable: "missing_github_token" alone does not tell an operator that the answer is an
  # environment variable rather than a line in the file. (cond, not a case with guards: `=~` and
  # String.contains?/2 are not allowed in guards.)
  defp config_hint(message) do
    cond do
      String.contains?(message, "missing_github_token") -> " (set GITHUB_TOKEN, or GH_TOKEN)"
      String.contains?(message, "missing_linear_api_token") -> " (set LINEAR_API_KEY)"
      true -> " (the tracker's token comes from the environment, not this file)"
    end
  end

  defp render_prompt! do
    PromptBuilder.build_prompt(@sample_issue, attempt: 2)
  rescue
    error ->
      Mix.raise("WORKFLOW.md prompt template failed to render: #{Exception.message(error)}")
  end
end
