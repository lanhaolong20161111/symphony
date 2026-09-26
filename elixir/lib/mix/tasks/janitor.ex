defmodule Mix.Tasks.Janitor do
  @shortdoc "Runs the host janitor for the file tracker (board, mirror, publish)"

  @moduledoc """
  Runs the host janitor: the process that makes a GitHub issue the only surface a person needs.

      mix janitor                 # resident loop, one round every 30s
      mix janitor --once          # a single round, for debugging
      mix janitor --skip-mirror   # do not talk to GitHub (boards and the publish sweep only)

  Options: `--once`, `--interval <seconds>`, `--skip-mirror`, `--tickets <dir>`,
  `--workspace-root <dir>`, `--repo <owner/name>`, `--tickets-repo <owner/name>`.

  ## This task deliberately does NOT start the application

  `Mix.Task.run("app.start")` is the reflex, and here it is wrong: Symphony's application starts the
  observability endpoint, so `mix janitor` would try to bind `server.port` and fight a running
  orchestrator for it. The janitor needs no part of the orchestrator -- only `:logger`, which
  `Application.ensure_all_started/1` gives it.

  It is also safe to run alongside Symphony, which matters because that is the normal deployment:
  Symphony executes tickets, the janitor keeps the paperwork.

  ## Where the work lives

  `SymphonyElixir.Janitor` holds the rounds; `SymphonyElixir.Janitor.Ticket`, `.Board` and
  `.Labels` are pure and covered by tests; `SymphonyElixir.Janitor.Shell` runs external commands
  with a timeout that kills the child.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [
          once: :boolean,
          interval: :integer,
          skip_mirror: :boolean,
          tickets: :string,
          workspace_root: :string,
          repo: :string,
          tickets_repo: :string
        ]
      )

    if invalid != [] do
      Mix.raise("unknown option(s): #{inspect(Keyword.keys(invalid))}")
    end

    # `:logger` only -- see the moduledoc for why the application is not started here.
    {:ok, _} = Application.ensure_all_started(:logger)

    janitor_opts =
      opts
      |> Keyword.take([:tickets, :workspace_root, :repo, :tickets_repo, :interval_seconds])
      |> Keyword.put(:skip_mirror, Keyword.get(opts, :skip_mirror, false))

    if Keyword.get(opts, :once, false) do
      SymphonyElixir.Janitor.run_once(janitor_opts)
    else
      SymphonyElixir.Janitor.run(janitor_opts)
    end
  end
end
