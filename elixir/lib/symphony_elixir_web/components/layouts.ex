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

  @doc """
  The badge class for a ticket state.

  Here rather than in each page: two pages showing the same state in different colours is a page
  that lies about the state.
  """
  @spec state_badge_class(String.t() | nil) :: String.t()
  def state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) ->
        "#{base} state-badge-active"

      String.contains?(normalized, ["blocked", "error", "failed", "paused"]) ->
        "#{base} state-badge-danger"

      String.contains?(normalized, ["todo", "queued", "pending", "retry", "ready"]) ->
        "#{base} state-badge-warning"

      true ->
        base
    end
  end

  @doc """
  Ticket states with the issue comments the janitor pulled down.

  Exists so the discussion can be read without opening GitHub. The comments are already in the
  ticket file -- `Janitor.append_discussion/3` appends them every round and tracks the last comment
  id it has seen -- so this is a display of something already on disk, not a new fetch.

  Only the newest `per_ticket` comments are shown per ticket: the point is "what happened last", and
  a ticket with thirty comments would otherwise bury the other tickets.
  """
  attr(:tickets, :list, required: true)
  attr(:title, :string, default: "票据状态与讨论")
  attr(:per_ticket, :integer, default: 3)

  @spec ticket_discussions(map()) :: Phoenix.LiveView.Rendered.t()
  def ticket_discussions(assigns) do
    ~H"""
    <section class="section-card">
      <div class="section-header">
        <div>
          <h2 class="section-title">{@title}</h2>
          <p class="section-copy">
            票据状态 + 从 issue 拉回来的评论（janitor 每轮同步）——
            只有点 issue 号追原帖才需要去 GitHub。
          </p>
        </div>
      </div>

      <%= if @tickets == [] do %>
        <p class="empty-state">暂无票据（或票据目录读不到）。</p>
      <% else %>
        <div class="dep-graph">
          <div
            :for={ticket <- @tickets}
            class="dep-node"
            style="flex-direction: column; align-items: stretch; gap: 0.4rem;"
          >
            <div style="display: flex; align-items: center; gap: 0.5rem; flex-wrap: wrap;">
              <span class="issue-id">{ticket.id}</span>
              <span class={state_badge_class(ticket.state)}>{ticket.state}</span>
              <span>{ticket.title}</span>
              <%= if ticket.issue_url do %>
                <a
                  href={ticket.issue_url}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="issue-link"
                >#{ticket.issue} ↗</a>
              <% end %>
              <span class="muted">
                {length(ticket.discussion)} 条评论
                <%= if ticket.blocked_by != [] do %>
                  · 依赖 {Enum.join(ticket.blocked_by, ", ")}
                <% end %>
              </span>
            </div>

            <div
              :for={comment <- newest(comment_list(ticket), @per_ticket)}
              class="event-meta"
              style="padding-left: 0.6rem; border-left: 2px solid var(--line);"
            >
              <div>
                <span class="mono muted">{comment.author}</span>
                <span class="muted"> · {short_time(comment.at)}</span>
              </div>
              <div>{comment.text}</div>
            </div>

            <%= if ticket.discussion == [] do %>
              <span class="muted event-meta">还没有评论。</span>
            <% end %>
          </div>
        </div>
      <% end %>
    </section>
    """
  end

  defp comment_list(ticket), do: Map.get(ticket, :discussion) || []

  defp newest(comments, n), do: comments |> Enum.take(-n)

  # `2026-09-26T11:57:49Z` -> `09-26 11:57`. The year is noise on a board and the seconds always are.
  defp short_time(at) when is_binary(at) do
    case Regex.run(~r/^\d{4}-(\d{2}-\d{2})T(\d{2}:\d{2})/, at) do
      [_, date, time] -> "#{date} #{time}"
      _ -> at
    end
  end

  defp short_time(at), do: to_string(at)

  @doc """
  The three places a task's work lives: the issue (human surface), the ticket queue (what the
  orchestrator polls), and the local clone (what the agent actually edits).

  Shared by all three pages for the same reason the nav is: they must agree, and a page that
  renders its own version is a page that can disagree.

  Nothing here is derived from anything else, and that is the point. The **code** repository is read
  out of `hooks.after_create` -- the only place it is written -- so when it differs from
  `janitor.issues_repo` this says so rather than quietly showing the wrong repository.
  """
  attr(:site, :map, required: true)
  attr(:title, :string, default: "这套系统连着哪些仓库")

  @spec site_card(map()) :: Phoenix.LiveView.Rendered.t()
  def site_card(assigns) do
    ~H"""
    <section class="section-card">
      <div class="section-header">
        <div>
          <h2 class="section-title">{@title}</h2>
          <p class="section-copy">
            issue 是给人看的表面 · 票据文件是编排器轮询的队列 · 本地代码是 agent 真正改的那份 clone
          </p>
        </div>
      </div>

      <%= if @site[:error] do %>
        <p class="empty-state">读不到站点信息：<%= @site.error %></p>
      <% else %>
        <div class="dep-graph">
          <div class="dep-node">
            <span class="issue-id">issues</span>
            <%= if @site.issues_url do %>
              <a
                href={@site.issues_url}
                target="_blank"
                rel="noopener noreferrer"
                class="issue-link"
              ><%= @site.issues_repo %> ↗</a>
              <span class="dep-arrow">·</span>
              <a
                href={"#{@site.issues_url}/issues?q=label%3Aagent-task"}
                target="_blank"
                rel="noopener noreferrer"
                class="issue-link"
              >任务 issue 列表 ↗</a>
            <% else %>
              <span class="muted">未配置</span>
            <% end %>
          </div>

          <div class="dep-node">
            <span class="issue-id">tickets</span>
            <%= if @site.tickets_url do %>
              <a
                href={@site.tickets_url}
                target="_blank"
                rel="noopener noreferrer"
                class="issue-link"
              ><%= @site.tickets_repo %> ↗</a>
            <% else %>
              <span class="muted">未配置</span>
            <% end %>
            <span class="dep-arrow">· 本机队列</span>
            <span class="dep-list">{@site.tickets_path}</span>
          </div>

          <div class="dep-node">
            <span class="issue-id">本地代码</span>
            <%= if @site.code[:url] do %>
              <a
                href={@site.code.url}
                target="_blank"
                rel="noopener noreferrer"
                class="issue-link"
              >{@site.code.repo} ↗</a>
            <% else %>
              <span class="muted">hooks.after_create 里没写 git clone</span>
            <% end %>
            <span class="dep-arrow">· 每单 clone 到</span>
            <span class="dep-list">{@site.code[:path]}</span>
            <span class="dep-arrow">·</span>
            <span class="muted">不用 worktree（见 /settings 的说明）</span>
          </div>

          <%= if @site.code[:url] && not @site.code[:matches_issues_repo?] do %>
            <div class="dep-node" style="border-color: #f1d8a6; background: #fff7e8;">
              <span class="issue-id">⚠️ 名称不一致</span>
              <span class="dep-list">
                本地代码来自 <strong>{@site.code.repo}</strong>，issues 仓库是
                <strong>{@site.issues_repo}</strong> —— 两者不同**是允许的**，
                但代码仓库写在 <code>hooks.after_create</code> 的 clone URL 里、**不是**配置项，
                改名时容易只改一个。
              </span>
            </div>
          <% end %>
        </div>
      <% end %>
    </section>
    """
  end
end
