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

  alias SymphonyElixir.AgentIdentity
  alias SymphonyElixir.Projects
  alias SymphonyElixir.Settings
  alias SymphonyElixir.TaskComposer
  alias SymphonyElixirWeb.Layouts

  @states ["ready", "in-progress", "in-review", "paused", "done", "cancelled"]

  @impl true
  def mount(_params, _session, socket) do
    projects = projects()

    socket =
      socket
      |> assign(:site, site_info())
      |> assign(:tickets, load_tickets())
      |> assign(:projects, projects)
      |> assign_project(default_project_name(projects))
      |> assign_route(%{adapter: nil, model: nil})
      |> assign(:states, @states)
      |> assign(:form, empty_form())
      |> assign(:creating, false)
      |> assign(:error, nil)
      |> assign(:info, nil)
      |> assign(:warnings, [])

    {:ok, socket}
  end

  @impl true
  def handle_event("select_project", %{"task" => params}, socket) do
    name = params["project"] || socket.assigns.selected
    overrides = %{adapter: params["adapter"], model: params["model"]}

    {:noreply, socket |> assign_project(name) |> assign_route(overrides)}
  end

  @impl true
  def handle_event("create", %{"task" => task_params}, socket) do
    attrs = %{
      title: task_params["title"],
      description: task_params["description"],
      validation: task_params["validation"],
      blocked_by: parse_blocked_by(task_params["blocked_by"]),
      priority: task_params["priority"],
      # Written to the ticket as its own route. `AgentIdentity.resolve/2` decides how far each goes;
      # the panel above the form says which, so this cannot promise more than it delivers.
      adapter: task_params["adapter"],
      model: task_params["model"]
    }

    socket = assign(socket, :creating, true)

    # The chosen project decides the queue and the repository the task lands in -- and therefore
    # which instance picks it up, with its own workspace, hooks and agent. Nothing on this page
    # decides that; the picker only says where to write.
    case TaskComposer.create_task(attrs, socket.assigns.project) do
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

        <form phx-submit="create" phx-change="select_project" class="task-form">
          <label class="form-field">
            <span class="form-label">项目（任务写到哪个队列 / 仓库）</span>
            <select name="task[project]" class="form-input">
              <option :for={p <- @projects} value={p.name} selected={p.name == @selected}>
                <%= p.name %><%= project_option_suffix(p) %>
              </option>
            </select>
            <span class="form-hint">
              项目决定任务进哪个队列、开在哪个仓库，以及**由哪个实例、用哪个 agent 去跑** ——
              这三件事在这里都改不了：它们是项目自己的属性（一份 workflow = 一个项目）。
            </span>
          </label>

          <%= if @project do %>
            <div class="dep-node" style="flex-direction: column; align-items: stretch; gap: 0.3rem;">
              <span class="issue-id">这一提交会发生什么</span>
              <div class="event-meta">
                <div><span class="mono muted">队列　　</span> <%= @project[:queue] || "（没声明 ✗）" %></div>
                <div><span class="mono muted">issues　</span> <%= @project[:issues_repo] || "（没声明 ✗）" %></div>
                <div><span class="mono muted">tickets　</span> <%= @project[:tickets_repo] || "（没声明 ✗）" %></div>
                <div><span class="mono muted">agent　　</span> <%= agent_text(@project) %></div>
                <%= if @route do %>
                  <div>
                    <span class="mono muted">本任务用　</span>
                    <strong><%= route_text(@route) %></strong>
                    <%= if @route != project_identity(@project) do %>
                      <span class="muted">（覆盖了项目默认）</span>
                    <% end %>
                  </div>
                <% end %>
                <div><span class="mono muted">工作区　</span> <%= @project[:workspace_root] || "（没声明）" %></div>
                <div><span class="mono muted">代码　　　</span> <%= repos_text(@project) %></div>
                <div>
                  <span class="mono muted">谁来跑　</span>
                  <%= @project[:url] || "（不知道地址）" %>
                  <%= if @project[:reachable?], do: "✓ 在跑", else: "✗ 没在跑" %>
                </div>
              </div>
              <%= for warning <- project_warnings(@project) ++ @override_notes do %>
                <div class="event-meta" style="color: #a15c00;"><%= warning %></div>
              <% end %>
            </div>
          <% end %>

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
            <span class="form-label">依赖（逗号分隔票据 ID）</span>
            <input type="text" name="task[blocked_by]" class="form-input" placeholder="可以不填" />
            <%= if @dep_tickets != [] do %>
              <span class="form-hint">
                只能选**所选项目**的票据（依赖不跨项目）:
                <%= format_ticket_ids(@dep_tickets) %>
              </span>
            <% end %>
          </label>

          <label class="form-field">
            <span class="form-label">优先级</span>
            <input type="text" name="task[priority]" class="form-input" placeholder="可以不填" />
          </label>

          <div style="display: flex; gap: 0.8rem; flex-wrap: wrap;">
            <label class="form-field" style="flex: 1 1 12rem;">
              <span class="form-label">coding agent（留空 = 跟项目）</span>
              <input
                type="text"
                name="task[adapter]"
                class="form-input"
                list="known-adapters"
                placeholder={@project && @project[:adapter] || "如 dsh / workbuddy"}
              />
            </label>
            <label class="form-field" style="flex: 1 1 12rem;">
              <span class="form-label">模型（留空 = 跟项目）</span>
              <input
                type="text"
                name="task[model]"
                class="form-input"
                placeholder={@project && @project[:model] || "如 auto"}
              />
            </label>
          </div>
          <span class="form-hint">
            这两项**只对 ACP 后端生效**（adapter ✓、model ✓）；codex 后端把模型写在
            <code>codex.command</code> 里 ⇒ 填了也不会生效，上面会直接说 ✗。
            留空就跟项目走 —— 一张不填的票和以前完全一样。
          </span>

          <datalist id="known-adapters">
            <option value="dsh"></option>
            <option value="workbuddy"></option>
          </datalist>

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
                    <span class={Layouts.state_badge_class(ticket.state)}>
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

      <Layouts.ticket_discussions tickets={@tickets} title="票据状态与讨论（不用去 GitHub）" />

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

  # ── Projects ─────────────────────────────────────────────────────────────────

  # The registry, or a single entry standing in for this instance when there is none yet: the picker
  # always has one honest option rather than an empty box that explains nothing.
  defp projects do
    case Projects.list() do
      [] -> [local_project()]
      list -> list
    end
  rescue
    _error -> [local_project()]
  end

  defp local_project do
    Projects.from_local_config()
  rescue
    _error -> %{name: "本实例", queue: nil, issues_repo: nil, repos: [], error: nil, reachable?: true}
  end

  # This instance's own project when the registry knows it, so the default is "where I am" rather
  # than whichever file happens to sort first.
  defp default_project_name(projects) do
    case Projects.current() do
      {:ok, project} -> project.name
      :error -> projects |> List.first() |> Map.get(:name)
    end
  rescue
    _error -> projects |> List.first() |> Map.get(:name)
  end

  defp assign_project(socket, name) do
    case Enum.find(socket.assigns.projects, &(&1.name == name)) do
      nil ->
        socket |> assign(:selected, name) |> assign(:project, nil) |> assign(:dep_tickets, [])

      project ->
        socket
        |> assign(:selected, project.name)
        |> assign(:project, project)
        |> assign(:dep_tickets, tickets_of(project))
    end
  end

  # Dependencies are read from the **selected** project's queue, not this instance's: a ticket id
  # only means something inside the queue it lives in, and cross-project dependencies are not
  # something this system expresses (one queue belongs to one instance).
  defp tickets_of(project) do
    case TaskComposer.list_tickets(tickets_path: project[:queue], issues_repo: project[:issues_repo]) do
      {:ok, tickets} -> tickets
      {:error, _reason} -> []
    end
  end

  # What this task will actually run on: the project's route, with the form's own choices applied by
  # **the same function the runner and the prompt use**. That is the point -- a preview computed any
  # other way could promise a route the run would not take.
  defp assign_route(socket, overrides) do
    case socket.assigns.project do
      nil ->
        assign(socket, :route, nil) |> assign(:override_notes, [])

      project ->
        route = AgentIdentity.resolve(project_identity(project), overrides)

        socket
        |> assign(:route, route)
        |> assign(:override_notes, override_notes(project, route, overrides))
    end
  end

  defp project_identity(project) do
    %{backend: project[:backend], adapter: project[:adapter], model: project[:model]}
  end

  # A request the runtime cannot honour is said out loud. The alternative -- accepting the value and
  # running something else -- is the failure this whole panel exists to prevent.
  defp override_notes(project, route, overrides) do
    []
    |> add_warning(
      present?(overrides[:adapter]) and project[:backend] != "acp",
      "⚠️ 你填了 adapter=#{overrides[:adapter]}，但项目的后端是 #{project[:backend]} ✗" <>
        "　adapter 是 ACP 后端的选型 ⇒ 这个任务仍按项目的路由跑（#{route.backend}）"
    )
    |> add_warning(
      present?(overrides[:model]) and project[:backend] == "codex",
      "⚠️ 你填了 model=#{overrides[:model]}，但 codex 的后端把模型写在 codex.command 里 ✗" <>
        "　⇒ 每任务覆盖在 codex 上不生效，实际用的是项目的那份"
    )
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  # What the picker must state rather than hide. Every one of these is a way a task can be created
  # successfully and then not run, which is the failure mode this page exists to prevent.
  #
  # Only reached with a project in hand: the template renders the panel under `if @project`, so a
  # missing project is the panel not existing rather than an empty panel.
  defp project_warnings(project) do
    []
    |> add_warning(project[:error] not in [nil, ""], "配置读不出来：#{project[:error]}")
    |> add_warning(is_nil(project[:queue]), "⚠️ 没声明队列（tracker.provider.path）⇒ 任务没地方写")
    |> add_warning(
      is_binary(project[:queue]) and project[:queue_present?] == false,
      "⚠️ 队列目录不存在：#{project[:queue]}\n" <>
        "　提交会**先建 GitHub issue、再写票据**，所以这里缺目录 ⇒ 会留下一个没有票据的 issue ✗"
    )
    |> add_warning(is_nil(project[:issues_repo]), "⚠️ 没声明 issues 仓库 ⇒ 开不了 issue")
    |> add_warning(
      is_binary(project[:queue]) and is_binary(project[:mirror_path]) and
        project[:queue] != project[:mirror_path],
      "⚠️ 队列与镜像目录不一致：编排器轮询 #{project[:queue]}，janitor 镜像 #{project[:mirror_path]}" <>
        "（票据会写进队列 ✓ 会被跑；但本页的票据列表来自本实例，看不到那一份）"
    )
    |> add_warning(
      project[:url] != nil and project[:reachable?] == false,
      "⚠️ 这个项目现在没在跑（探测 #{project[:url]} 失败）：任务会写进它的队列，" <>
        "但要等它的实例起来才会被领走"
    )
  end

  defp add_warning(list, true, text), do: list ++ [text]
  defp add_warning(list, false, _text), do: list

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

  # ── Project display ──────────────────────────────────────────────────────────

  defp project_option_suffix(project) do
    case {project[:backend], project[:queue]} do
      {nil, _} -> "（配置读不出来）"
      {backend, nil} -> "（#{backend} · 没声明队列）"
      {backend, queue} -> "（#{backend} · #{Path.basename(queue)}）"
    end
  end

  defp agent_text(project) do
    [project[:backend], project[:adapter], project[:model]]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "（没声明）"
      parts -> Enum.join(parts, " / ")
    end
  end

  defp route_text(route) do
    [route.backend, route.adapter, route.model]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" / ")
  end

  defp repos_text(project) do
    case project[:repos] do
      [] -> "（hooks.after_create 里没写 git clone）"
      [one] -> one
      many -> "#{length(many)} 个仓库：" <> Enum.map_join(many, "、", &short_repo/1)
    end
  end

  # `https://github.com/owner/name` reads better as `owner/name` when several are listed.
  defp short_repo(url) do
    case Regex.run(~r{github\.com/([\w.\-]+/[\w.\-]+)}, url) do
      [_, repo] -> repo
      _ -> url
    end
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
end
