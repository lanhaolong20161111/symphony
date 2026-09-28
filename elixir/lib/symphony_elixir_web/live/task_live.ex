defmodule SymphonyElixirWeb.TaskLive do
  @moduledoc """
  Task management page: create tasks (which become GitHub issues + ticket
  files), list existing tickets, update ticket state, and see dependency
  relationships.

  This page is the "entry" the architecture names as the gap: a person fills a
  form, and the middleware (`TaskComposer`) creates the GitHub issue and the
  ticket file in one step, so the janitor's next round only mirrors state.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Settings
  alias SymphonyElixir.TaskComposer
  alias SymphonyElixirWeb.Layouts

  @states ["ready", "in-progress", "in-review", "paused", "done", "cancelled"]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:site, site_info())
      |> assign(:tickets, load_tickets())
      |> assign(:states, @states)
      |> assign(:form, empty_form())
      |> assign(:creating, false)
      |> assign(:error, nil)
      |> assign(:info, nil)
      |> assign(:warnings, [])

    {:ok, socket}
  end

  @impl true
  def handle_event("create", %{"task" => task_params}, socket) do
    attrs = %{
      title: task_params["title"],
      description: task_params["description"],
      validation: task_params["validation"],
      blocked_by: parse_blocked_by(task_params["blocked_by"]),
      priority: task_params["priority"]
    }

    socket = assign(socket, :creating, true)

    case TaskComposer.create_task(attrs) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(:creating, false)
         |> assign(:tickets, load_tickets())
         |> assign(:form, empty_form())
         |> assign(:error, nil)
         |> assign(:warnings, Map.get(result, :dependency_warnings, []))
         |> assign(:info, creation_summary(result))}

      {:error, :missing_title} ->
        {:noreply,
         socket
         |> assign(:creating, false)
         |> assign(:error, "标题不能为空")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:creating, false)
         |> assign(:error, "创建失败: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("change_state", %{"ticket_id" => ticket_id, "state" => new_state}, socket) do
    case TaskComposer.update_state(ticket_id, new_state) do
      {:ok, _ticket} ->
        {:noreply,
         socket
         |> assign(:tickets, load_tickets())
         |> assign(:info, "#{ticket_id} → #{new_state}")
         |> assign(:error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, "状态更新失败: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, :tickets, load_tickets())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Symphony Task Management</p>
            <h1 class="hero-title">任务管理</h1>
            <p class="hero-copy">
              填表创建任务 → 中间件自动建 GitHub issue + 票据文件。依赖关系写入票据 <code>blocked_by</code>，编排器会据此拦截。
            </p>
          </div>
          <Layouts.page_nav current={:tasks} />
          <button type="button" class="subtle-button" phx-click="refresh">刷新</button>
        </div>
      </header>

      <%= if @site do %>
        <Layouts.site_card site={@site} title="这些任务会去哪个仓库" />
      <% end %>

      <%= if @error do %>
        <section class="error-card">
          <h2 class="error-title">错误</h2>
          <p class="error-copy"><%= @error %></p>
        </section>
      <% end %>

      <%= if @info do %>
        <section class="section-card">
          <p class="section-copy"><%= @info %></p>
        </section>
      <% end %>

      <%= if @warnings != [] do %>
        <section class="error-card">
          <h2 class="error-title">依赖没连上（这部分没做成）</h2>
          <div class="error-copy">
            <p :for={warning <- @warnings}><%= warning %></p>
            <p style="margin-top: 0.5rem;">
              票据本身建好了，<strong>没有</strong>假装它也建好了依赖 ——
              去「设置」确认 issues 仓库，或核对依赖票据 ID 再补一次。
            </p>
          </div>
        </section>
      <% end %>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">创建任务</h2>
            <p class="section-copy">填表 → GitHub issue + 票据文件。</p>
          </div>
        </div>

        <form phx-submit="create" class="task-form">
          <label class="form-field">
            <span class="form-label">标题 *</span>
            <input type="text" name="task[title]" class="form-input" required placeholder="一句话说清要做什么" />
          </label>

          <label class="form-field">
            <span class="form-label">要做什么</span>
            <textarea name="task[description]" class="form-textarea" rows="4" placeholder="详细描述任务内容"></textarea>
          </label>

          <label class="form-field">
            <span class="form-label">怎么算做完了（验收标准）</span>
            <textarea name="task[validation]" class="form-textarea" rows="2" placeholder="可以不填，agent 会自己推导"></textarea>
          </label>

          <label class="form-field">
            <span class="form-label">依赖（逗号分隔票据 ID，如 SYM-1, SYM-2）</span>
            <input type="text" name="task[blocked_by]" class="form-input" placeholder="可以不填" />
            <%= if @tickets != [] do %>
              <span class="form-hint">已有票据: <%= format_ticket_ids(@tickets) %></span>
            <% end %>
          </label>

          <label class="form-field">
            <span class="form-label">优先级</span>
            <input type="text" name="task[priority]" class="form-input" placeholder="可以不填" />
          </label>

          <button type="submit" class="task-submit" disabled={@creating}>
            <%= if @creating, do: "创建中…", else: "创建任务" %>
          </button>
        </form>
      </section>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">票据列表</h2>
            <p class="section-copy">已有票据、状态、依赖关系。</p>
          </div>
        </div>

        <%= if @tickets == [] do %>
          <p class="empty-state">暂无票据。</p>
        <% else %>
          <div class="table-wrap">
            <table class="data-table" style="min-width: 800px;">
              <thead>
                <tr>
                  <th>ID</th>
                  <th>标题</th>
                  <th>状态</th>
                  <th>依赖</th>
                  <th>Issue</th>
                  <th>改状态</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={ticket <- @tickets}>
                  <td>
                    <span class="issue-id"><%= ticket.id %></span>
                  </td>
                  <td><%= truncate(ticket.title, 40) %></td>
                  <td>
                    <span class={state_badge_class(ticket.state)}>
                      <%= ticket.state %>
                    </span>
                  </td>
                  <td>
                    <%= if ticket.blocked_by == [] do %>
                      <span class="muted">—</span>
                    <% else %>
                      <span class="dep-list"><%= Enum.join(ticket.blocked_by, ", ") %></span>
                    <% end %>
                  </td>
                  <td>
                    <%= if ticket.issue_url do %>
                      <a href={ticket.issue_url} target="_blank" rel="noopener noreferrer" class="issue-link">
                        #<%= ticket.issue %>
                      </a>
                    <% else %>
                      <span class="muted">无</span>
                    <% end %>
                  </td>
                  <td>
                    <form phx-change="change_state" class="state-form">
                      <input type="hidden" name="ticket_id" value={ticket.id} />
                      <select name="state" class="state-select">
                        <%= for state <- @states do %>
                          <option value={state} selected={state == ticket.state}><%= state %></option>
                        <% end %>
                      </select>
                    </form>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>
      </section>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">依赖图</h2>
            <p class="section-copy">票据之间的依赖关系（→ 表示被谁阻塞）。</p>
          </div>
        </div>

        <%= if @tickets == [] do %>
          <p class="empty-state">暂无票据。</p>
        <% else %>
          <div class="dep-graph">
            <div :for={ticket <- @tickets} class="dep-node">
              <span class="issue-id"><%= ticket.id %></span>
              <%= if ticket.blocked_by != [] do %>
                <span class="dep-arrow">← 被</span>
                <span class="dep-list"><%= Enum.join(ticket.blocked_by, ", ") %></span>
                <span class="dep-arrow">阻塞</span>
              <% else %>
                <span class="dep-free">可派发</span>
              <% end %>
            </div>
          </div>
        <% end %>
      </section>
    </section>
    """
  end

  defp load_tickets do
    case TaskComposer.list_tickets() do
      {:ok, tickets} -> tickets
      {:error, _} -> []
    end
  end

  defp site_info do
    Settings.site()
  rescue
    _error -> nil
  end

  # Says what actually happened, including the part that did not. A created task whose dependency
  # links failed must not read as an unqualified success -- the caller asked for the link.
  defp creation_summary(result) do
    base = "已创建 #{result.id} → #{result.issue_url}"

    case Map.get(result, :linked_dependencies, []) do
      [] ->
        base

      linked ->
        base <>
          "；依赖已连到 GitHub（#{Enum.join(linked, ", ")}），" <>
          "同时写进了票据的 blocked_by（编排器据此拦截派发）"
    end
  end

  defp empty_form do
    %{title: "", description: "", validation: "", blocked_by: "", priority: ""}
  end

  defp parse_blocked_by(nil), do: []
  defp parse_blocked_by(""), do: []

  defp parse_blocked_by(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_blocked_by(_), do: []

  defp format_ticket_ids(tickets) do
    tickets
    |> Enum.map(& &1.id)
    |> Enum.take(20)
    |> Enum.join(", ")
  end

  defp truncate(nil, _len), do: ""
  defp truncate(text, len) when is_binary(text) do
    if String.length(text) > len do
      String.slice(text, 0, len) <> "…"
    else
      text
    end
  end

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed", "paused"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry", "ready"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end
end
