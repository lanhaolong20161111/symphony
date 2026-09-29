defmodule SymphonyElixir.MixProject do
  use Mix.Project

  def project do
    [
      app: :symphony_elixir,
      version: "0.0.3",
      elixir: "~> 1.19",
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      test_coverage: [
        summary: [
          threshold: 100
        ],
        ignore_modules: [
          SymphonyElixir.Asana.Client,
          SymphonyElixir.Config,
          SymphonyElixir.GitHub.Client,
          SymphonyElixir.GitLab.Client,
          SymphonyElixir.Jira.Client,
          SymphonyElixir.Linear.Client,
          SymphonyElixir.SpecsCheck,
          SymphonyElixir.Orchestrator,
          SymphonyElixir.Orchestrator.State,
          SymphonyElixir.AgentRunner,
          SymphonyElixir.Application,
          SymphonyElixir.CLI,
          SymphonyElixir.ACP.AppServer,
          SymphonyElixir.CommandCode.AppServer,
          SymphonyElixir.Codex.AppServer,
          SymphonyElixir.Codex.DynamicTool,
          SymphonyElixir.HttpServer,
          SymphonyElixir.StatusDashboard,
          SymphonyElixir.LogFile,
          SymphonyElixir.Workspace,
          SymphonyElixirWeb.DashboardLive,
          SymphonyElixirWeb.Endpoint,
          SymphonyElixirWeb.ErrorHTML,
          SymphonyElixirWeb.ErrorJSON,
          SymphonyElixirWeb.Layouts,
          SymphonyElixirWeb.ObservabilityApiController,
          SymphonyElixirWeb.Presenter,
          SymphonyElixirWeb.ProjectLive,
          SymphonyElixirWeb.SettingsLive,
          SymphonyElixirWeb.StaticAssetController,
          SymphonyElixirWeb.StaticAssets,
          SymphonyElixirWeb.TaskApiController,
          SymphonyElixirWeb.TaskLive,
          SymphonyElixirWeb.Router,
          SymphonyElixirWeb.Router.Helpers
        ]
      ],
      test_ignore_filters: [
        "test/support/snapshot_support.exs",
        "test/support/test_support.exs"
      ],
      dialyzer: [
        plt_add_apps: [:mix]
      ],
      escript: escript(),
      releases: releases(),
      aliases: aliases(),
      # Phoenix's code reloader needs this Mix listener to watch files and recompile as they change;
      # without it the reloader still compiles on the next request, but nothing is pushed to the
      # browser, so live reload never fires. `phx.new` generates this line for the same reason.
      listeners: [Phoenix.CodeReloader],
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {SymphonyElixir.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Zero-dependency ACP (Agent Client Protocol) client SDK. Required by
      # `SymphonyElixir.ACP.AppServer`, which drives non-Codex coding agents (DSH, WorkBuddy).
      # Path dep because the SDK is developed alongside Symphony in this workspace.
      {:acp_sdk, path: "../../elixir_acp_sdk"},
      {:bandit, "~> 1.8"},
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix, "~> 1.8.0"},
      {:phoenix_html, "~> 4.2"},
      # Dev-only, like `phx.new` generates: this is the module behind the `if code_reloading?`
      # block in SymphonyElixirWeb.Endpoint. `plug Phoenix.LiveReloader` is compiled in whenever
      # code_reloading? is true, and that setting is read at compile time -- so without this the
      # dev build fails on an undefined module, and with `only: :dev` neither `mix test` nor a
      # release ever sees it.
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"},
      {:solid, "~> 1.2"},
      {:ecto, "~> 3.13"},
      {:burrito, "~> 1.5", only: :prod, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      build: ["escript.build"],
      build_land: ["escript.land"],
      lint: ["specs.check", "credo --strict"]
    ]
  end

  # Two escripts out of one project, and Mix only builds one: `escript.build` reads the
  # `:escript` key from `Mix.Project.config()`, which is evaluated once when `mix` loads this
  # file. So the target is chosen here, by an environment variable that `mix escript.land`
  # (lib/mix/tasks/escript.land.ex) sets before re-pushing the project -- the re-push is what
  # makes Mix re-read this function. With no variable set, nothing changes: the default is
  # still the `bin/symphony` server, which is what `mix build` and CI build.
  defp escript do
    case System.get_env("SYMPHONY_ESCRIPT") do
      "land" ->
        [
          app: nil,
          main_module: SymphonyElixir.Land,
          name: "land",
          path: "bin/land"
        ]

      _other ->
        [
          app: nil,
          main_module: SymphonyElixir.CLI,
          name: "symphony",
          path: "bin/symphony"
        ]
    end
  end

  defp releases do
    [
      symphony: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos_arm64: [os: :darwin, cpu: :aarch64],
            macos_x86_64: [os: :darwin, cpu: :x86_64],
            linux_arm64: [os: :linux, cpu: :aarch64],
            linux_x86_64: [os: :linux, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end
end
