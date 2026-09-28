defmodule SymphonyElixirWeb.SettingsLive do
  @moduledoc """
  Settings page: what this instance is running, where its credentials stand, and a form for the
  curated subset of the workflow that may be changed from here.

  ## Why writes are loopback-only

  This app has no authentication -- it is designed to listen on the loopback interface and nothing
  else (`AGENTS.md`: "控制台能读文件、跑命令、启停 agent，且没有鉴权 … 别加'方便远程访问'的默认值").
  A settings page changes that calculus, because it writes the workflow: whoever can reach it can
  point the agent at another repository, or at their own endpoint.

  So the **write** actions re-check the peer address and refuse anything that is not loopback, while
  **reading** stays available. Remote operation therefore works the way it should -- over an SSH
  port-forward (`ssh -L 4001:127.0.0.1:4001 <host>`), where the request genuinely arrives from
  loopback and the tunnel carries the authentication. Exposing the port is not a shortcut around
  this; it is the thing this guard exists to stop.

  Credentials are shown as **presence only**, never as a value or a mask, and the page distinguishes
  "set in the User environment" from "visible to this process" -- a service started from a shell
  whose environment predates the variable sees neither, and that difference is the whole diagnosis.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Settings, TaskComposer}
  alias SymphonyElixirWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:site, safe(&TaskComposer.site_info/0))
     |> assign(:sections, load_sections())
     |> assign(:credentials, safe(&Settings.credentials/0) || [])
     |> assign(:editable, safe(&Settings.editable/0) || [])
     |> assign(:can_write, connected?(socket) and loopback?(socket))
     |> assign(:error, nil)
     |> assign(:info, nil)}
  end

  @impl true
  def handle_event("save", %{"path" => path_key, "value" => value}, socket) do
    path = String.split(path_key, ".")

    # Re-checked here rather than trusting the assign from `mount`: this is where the write actually
    # happens, the socket is connected so the peer is knowable, and a guard that reads its own
    # cached answer is one bad assign away from being no guard at all.
    if socket.assigns.can_write and loopback?(socket) do
      case Settings.update(path, value) do
        {:ok, workflow_path} ->
          {:noreply,
           socket
           |> refresh()
           |> assign(:error, nil)
           |> assign(
             :info,
             "已写入 #{Enum.join(path, ".")}（#{workflow_path}）。Symphony 约 1 秒内重载生效；" <>
               "改坏的话它保留上一份好配置，原文件备份在 #{Path.basename(workflow_path)}.bak。"
           )}

        {:error, reason} ->
          {:noreply, assign(socket, :error, "没写进去：#{describe(reason)}")}
      end
    else
      {:noreply, assign(socket, :error, write_refused_message())}
    end
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    socket
    |> assign(:site, safe(&TaskComposer.site_info/0))
    |> assign(:sections, load_sections())
    |> assign(:credentials, safe(&Settings.credentials/0) || [])
    |> assign(:editable, safe(&Settings.editable/0) || [])
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Symphony Settings</p>
            <h1 class="hero-title">设置</h1>
            <p class="hero-copy">
              这里显示的是<strong>生效值</strong>（解析 + 默认值 + 环境变量之后），不是文件原文。
              改的是 workflow 文件，<strong>约 1 秒自动生效</strong>；改坏时它保留上一份好配置。
            </p>
          </div>
          <Layouts.page_nav current={:settings} />
          <button type="button" class="subtle-button" phx-click="refresh">刷新</button>
        </div>
      </header>

      <%= if @error do %>
        <section class="error-card">
          <h2 class="error-title">没做成</h2>
          <p class="error-copy"><%= @error %></p>
        </section>
      <% end %>

      <%= if @info do %>
        <section class="section-card">
          <p class="section-copy"><%= @info %></p>
        </section>
      <% end %>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">GitHub 仓库</h2>
            <p class="section-copy">任务页建出来的 issue 进这里；票据文件在另一个仓库。</p>
          </div>
        </div>

        <%= if @site do %>
          <div class="dep-graph">
            <div class="dep-node">
              <span class="issue-id">issues</span>
              <a href={@site.issues_url} target="_blank" rel="noopener noreferrer" class="issue-link">
                <%= @site.issues_repo %>
              </a>
              <span class="dep-arrow">·</span>
              <a href={"#{@site.issues_url}/issues"} target="_blank" rel="noopener noreferrer" class="issue-link">
                打开 issue 列表 ↗
              </a>
            </div>
            <div class="dep-node">
              <span class="issue-id">tickets</span>
              <%= if @site.tickets_url do %>
                <a href={@site.tickets_url} target="_blank" rel="noopener noreferrer" class="issue-link">
                  <%= @site.tickets_repo %>
                </a>
              <% else %>
                <span class="muted">未配置</span>
              <% end %>
              <span class="dep-arrow">· 本机目录</span>
              <span class="dep-list"><%= @site.tickets_path %></span>
            </div>
            <div class="dep-node">
              <span class="issue-id">workspace</span>
              <span class="dep-list"><%= @site.workspace_root %></span>
            </div>
          </div>
        <% else %>
          <p class="empty-state">读不到站点信息（workflow 可能没加载）。</p>
        <% end %>
      </section>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">凭据</h2>
            <p class="section-copy">
              只显示<strong>设了没设</strong>，永不回显值。
              两列不等就是问题：<code>User 环境</code> 有而 <code>本进程</code> 看不到 ⇒
              这个服务是从一个"环境早于该变量"的 shell 起来的，继承到的是空值。
            </p>
          </div>
        </div>

        <div class="table-wrap">
          <table class="data-table" style="min-width: 760px;">
            <thead>
              <tr>
                <th>凭据</th>
                <th>谁用</th>
                <th>User 环境</th>
                <th>本进程</th>
                <th>长度</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={credential <- @credentials}>
                <td><span class="mono"><%= credential.name %></span></td>
                <td class="muted"><%= credential.used_by %></td>
                <td>
                  <%= case credential.user_scope? do %>
                    <% true -> %><span class="dep-free">已设置</span>
                    <% false -> %><span class="muted">未设置</span>
                    <% :unknown -> %><span class="muted">读不到</span>
                  <% end %>
                </td>
                <td>
                  <%= if credential.process? do %>
                    <span class="dep-free">可见</span>
                  <% else %>
                    <span class="state-badge state-badge-danger">看不到</span>
                  <% end %>
                </td>
                <td class="mono muted"><%= credential.length || "—" %></td>
              </tr>
            </tbody>
          </table>
        </div>

        <p class="section-copy" style="margin-top: 0.75rem;">
          ⚠️ 凭据<strong>不从这个页面填</strong>：本服务无鉴权，一个能远程写入凭据的表单等于把机器交出去。
          设 User 环境变量请在本机终端做（<code>[Environment]::SetEnvironmentVariable(..., 'User')</code>，
          注意 <code>setx</code> 有 1024 字符上限），然后<strong>新开终端</strong>重启服务。
        </p>
      </section>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">可改的设置</h2>
            <%= if @can_write do %>
              <p class="section-copy">
                <span class="dep-free">写入已启用</span> —— 这个请求来自回环（本机，或 SSH 端口转发）。
              </p>
            <% else %>
              <p class="section-copy">
                <span class="state-badge state-badge-danger">只读</span>
                <%= write_refused_message() %>
              </p>
            <% end %>
          </div>
        </div>

        <div class="table-wrap">
          <table class="data-table" style="min-width: 820px;">
            <thead>
              <tr>
                <th>设置</th>
                <th>生效值</th>
                <th>改成</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={entry <- @editable}>
                <td>
                  <div class="detail-stack">
                    <span class="mono"><%= Enum.join(entry.path, ".") %></span>
                    <span class="muted event-meta"><%= entry.label %></span>
                    <%= if Map.get(entry, :hint) do %>
                      <span class="muted event-meta"><%= entry.hint %></span>
                    <% end %>
                  </div>
                </td>
                <td class="mono"><%= inspect(Map.get(entry, :value)) %></td>
                <td>
                  <form phx-submit="save" class="state-form">
                    <input type="hidden" name="path" value={Enum.join(entry.path, ".")} />
                    <input
                      type="text"
                      name="value"
                      class="form-input"
                      value={input_value(Map.get(entry, :value))}
                      disabled={not @can_write}
                    />
                    <button type="submit" class="subtle-button" disabled={not @can_write}>写入</button>
                  </form>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">生效配置</h2>
            <p class="section-copy">
              只读。文件里没写的键会显示成默认值 —— 那正是"文件原文"看不出来的部分。
            </p>
          </div>
        </div>

        <div :for={section <- @sections} class="dep-graph" style="margin-top: 0.75rem;">
          <div class="dep-node" style="justify-content: flex-start;">
            <span class="issue-id"><%= section.title %></span>
          </div>
          <div class="table-wrap" style="margin-top: 0;">
            <table class="data-table" style="min-width: 620px;">
              <tbody>
                <tr :for={{key, value} <- section.rows}>
                  <td class="mono muted" style="width: 45%;"><%= key %></td>
                  <td class="mono"><%= inspect(value) %></td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>
    </section>
    """
  end

  # ── helpers ───────────────────────────────────────────────────────────────────

  defp load_sections do
    case Settings.effective() do
      {:ok, sections} -> sections
      {:error, _reason} -> []
    end
  end

  defp safe(fun) do
    fun.()
  rescue
    _error -> nil
  end

  defp input_value(nil), do: ""
  defp input_value(value) when is_binary(value), do: value
  defp input_value(value), do: to_string(value)

  # `connected?/1` is false on the static render, which has no peer to inspect; writes are refused
  # there anyway because they arrive as events on the connected socket. Failing closed means a page
  # served without JS is read-only, which is the right way round.
  defp loopback?(socket) do
    Settings.loopback_peer?(get_connect_info(socket, :peer_data))
  rescue
    _error -> false
  end

  defp write_refused_message do
    "只读：这个请求不是从回环来的。远程要用写入，请走 SSH 端口转发 " <>
      "（ssh -L 4001:127.0.0.1:4001 <这台机器>），那时请求本身就是回环。"
  end

  defp describe({:not_editable, path}), do: "#{Enum.join(path, ".")} 不在可改清单里"
  defp describe({:not_an_integer, raw}), do: "#{inspect(raw)} 不是整数"
  defp describe({:not_a_boolean, raw}), do: "#{inspect(raw)} 不是 true/false"
  defp describe({:would_overwrite_section, key}), do: "#{key} 是一个小节，不能改成单个值"
  defp describe({:error, {:invalid_workflow_config, message}}), do: "改完的 workflow 过不了校验：#{message}"
  defp describe(:missing_front_matter), do: "workflow 文件没有 front matter"
  defp describe(other), do: inspect(other)
end
