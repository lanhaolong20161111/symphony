defmodule Mix.Tasks.Escript.Land do
  @shortdoc "Builds bin/land, the escript that runs the land watcher without Mix"

  @moduledoc """
  Builds `bin/land`: a second escript out of this same project, whose `main_module` is
  `SymphonyElixir.Land` instead of `SymphonyElixir.CLI`.

      mix escript.land      # or, the alias: mix build_land

  ## Why this is a task and not a flag

  `mix escript.build` reads exactly one `:escript` key, from `Mix.Project.config()`, and that
  config is produced once -- when Mix loads `mix.exs`. A command line flag therefore cannot
  choose between two escripts, so `mix.exs` asks `SYMPHONY_ESCRIPT` instead and this task is
  what sets it.

  Setting the variable is not enough by itself: by the time a task runs, the config is already
  in memory. `Mix.Project.pop/0` followed by `Mix.Project.push/1` discards that copy and calls
  the project's `project/0` again, which is the one thing that makes Mix re-read the value.
  Both are public API, and that pair is why the build below writes `bin/land` rather than a
  second copy of `bin/symphony`.

  ## The default is untouched

  With no `SYMPHONY_ESCRIPT` in the environment, `mix build` still builds `bin/symphony`, so a
  release, CI, or the running server sees no change at all.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    System.put_env("SYMPHONY_ESCRIPT", "land")
    Mix.Project.pop()
    Mix.Project.push(SymphonyElixir.MixProject)
    Mix.Task.run("escript.build", args)
  end
end
