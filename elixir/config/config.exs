import Config

config :phoenix, :json_library, Jason

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: SymphonyElixirWeb.ErrorHTML, json: SymphonyElixirWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SymphonyElixir.PubSub,
  live_view: [signing_salt: "symphony-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: false

if config_env() == :dev do
  # The development reloaders, matching what `phx.new` generates for a new application. Two halves
  # are needed and neither works alone: this config, and the `if code_reloading?` block in
  # SymphonyElixirWeb.Endpoint. Both are dev-only, so `mix test` and releases are untouched.
  #
  # The code reloader recompiles changed modules on the next request; the live reloader refreshes
  # connected pages (the LiveView console) when one of these patterns changes. The list is pointed
  # at this repository's tree, which is not a stock layout.
  config :symphony_elixir, SymphonyElixirWeb.Endpoint,
    code_reloader: true,
    live_reload: [
      patterns: [
        ~r"priv/static/.*\.(js|css|png|jpeg|jpg|gif|svg)$",
        ~r"lib/symphony_elixir_web/router\.ex$",
        ~r"lib/symphony_elixir_web/presenter\.ex$",
        ~r"lib/symphony_elixir_web/(controllers|components|live)/.*\.(ex|heex)$"
      ]
    ]
end

if config_env() == :test do
  config :symphony_elixir,
    workflow_file_path: Path.expand("../test/fixtures/startup_workflow.md", __DIR__)

  # Tests rewrite the workflow file constantly, so a reload that changes server.port would ask the
  # supervisor to bounce a real endpoint in the middle of the suite. Off here; on everywhere else.
  config :symphony_elixir, restart_endpoint_on_workflow_change: false
end
