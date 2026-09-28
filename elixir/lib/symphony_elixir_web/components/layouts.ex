defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns =
      assigns
      |> assign(:csrf_token, Plug.CSRFProtection.get_csrf_token())
      |> assign(:dashboard_css_url, SymphonyElixirWeb.StaticAssets.dashboard_css_url())
      |> assign(:favicon_url, SymphonyElixirWeb.StaticAssets.favicon_url())

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Symphony Observability</title>
        <link rel="icon" type="image/png" sizes="128x128" href={@favicon_url} />
        <script defer src="/vendor/phoenix_html/phoenix_html.js"></script>
        <script defer src="/vendor/phoenix/phoenix.js"></script>
        <script defer src="/vendor/phoenix_live_view/phoenix_live_view.js"></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");

            if (!window.Phoenix || !window.LiveView) return;

            var socketPath =
              document.querySelector("meta[name='live-socket-path']")?.content || "/live";

            var liveSocket = new window.LiveView.LiveSocket(socketPath, window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken}
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;
          });
        </script>
        <meta name="live-socket-path" content={Application.get_env(:symphony_elixir, :url_path, "") <> "/live"} />
        <link rel="stylesheet" href={@dashboard_css_url} />
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <main class="app-shell">
      {@inner_content}
    </main>
    """
  end

  @doc """
  Navigation between the console's pages.

  One definition on purpose: three pages each writing their own list is how a page ends up
  stranding whoever is on it (the first version of this used `.status-badge-offline`, which is the
  "disconnected" indicator and hides itself once the LiveView connects, so every link vanished in a
  browser while looking fine in a plain HTTP fetch).
  """
  attr(:current, :atom, required: true)

  @spec page_nav(map()) :: Phoenix.LiveView.Rendered.t()
  def page_nav(assigns) do
    ~H"""
    <nav class="status-stack" aria-label="页面导航">
      <.nav_link href="/" label="仪表盘" current={@current == :dashboard} />
      <.nav_link href="/tasks" label="任务管理" current={@current == :tasks} />
      <.nav_link href="/settings" label="设置" current={@current == :settings} />
    </nav>
    """
  end

  attr(:href, :string, required: true)
  attr(:label, :string, required: true)
  attr(:current, :boolean, default: false)

  defp nav_link(assigns) do
    ~H"""
    <a
      href={@href}
      class={["top-nav-link", @current && "is-current"]}
      aria-current={@current && "page"}
    >
      {@label}
    </a>
    """
  end
end
