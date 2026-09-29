defmodule SymphonyElixirWeb.ControlLive do
  @moduledoc """
  The control plane: the hub for the pages that manage this instance, plus the panels the fork had
  bolted onto the dashboard.

  Upstream's dashboard is a read-only status view and is kept that way -- this module is where
  everything that is not "what is running right now" lives: links to settings, task management, the
  new-project form and the ticket board; the pause/resume switch; the recorder's per-agent usage; the
  project registry; the repository card; the ticket discussions; and the per-session agent route with
  its context window.

  ## Why pause/resume is a LiveView event and not a form post

  The API routes (`POST /api/v1/pause`, `POST /api/v1/resume`) answer JSON, so a plain form post would
  navigate the browser to a JSON body. The buttons call the same orchestrator functions the controller
  calls, and re-read the payload afterwards so the state shown is the state the orchestrator reports
  rather than the one the click assumed.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Orchestrator, Projects, RecorderClient, Settings, TaskComposer}
  alias SymphonyElixirWeb.{Endpoint, Layouts, ObservabilityPubSub, Presenter}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :ok = ObservabilityPubSub.subscribe()

    {:ok,
     socket
     |> assign_panels()
     |> assign(:control_error, nil)}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply, assign_panels(socket)}
  end

  @impl true
  def handle_event("pause", _params, socket), do: control(socket, :pause)

  @impl true
  def handle_event("resume", _params, socket), do: control(socket, :resume)

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> assign_panels() |> assign(:control_error, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Control Plane
            </p>
            <h1 class="hero-title">
              Control Plane
            </h1>
            <p class="hero-copy">
              Everything that changes this instance -- settings, tasks, projects, the runtime switch --
              lives here. The dashboard is upstream's read-only status view.
            </p>
          </div>

          <Layouts.page_nav current={:control} />
        </div>
      </header>

      <%= if @control_error do %>
        <section class="error-card">
          <h2 class="error-title">Not done</h2>
          <p class="error-copy"><%= @control_error %></p>
        </section>
      <% end %>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Pages</h2>
            <p class="section-copy">
              The console's other surfaces. The dashboard link is here because upstream's dashboard
              carries no navigation of its own.
            </p>
          </div>
        </div>

        <div class="dep-graph">
          <.hub_link href="/settings" label="Settings" copy="Credentials, the editable workflow, the repository layout." />
          <.hub_link href="/tasks" label="Tasks" copy="Create a task (issue + ticket in one step), list tickets, change state." />
          <.hub_link href="/projects/new" label="New project" copy="Add a project: its workflow, queue and agent route." />
          <.hub_link href="/control/tickets" label="Tickets" copy="The queue as a tracker: state, priority, labels, blockers, branch, pull request, comments." />
          <.hub_link href="/" label="Dashboard" copy="Upstream's runtime view: counts, rate limits, running, blocked, retrying." />
        </div>
      </section>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Runtime control</h2>
            <p class="section-copy">
              Pause stops taking on new work; runs already in flight keep going, so it drains rather
              than freezes. Resume starts polling again.
            </p>
          </div>
        </div>

        <div class="dep-graph">
          <div class="dep-node">
            <span class="issue-id">state</span>
            <%= if paused?(@payload) do %>
              <span id="runtime-state" class="state-badge state-badge-danger">Paused</span>
            <% else %>
              <span id="runtime-state" class="state-badge state-badge-active">Running</span>
            <% end %>
            <span class="dep-arrow">·</span>
            <span class="muted">POST /api/v1/pause and /api/v1/resume do the same thing over HTTP.</span>
          </div>

          <div class="dep-node">
            <button type="button" class="subtle-button" phx-click="pause">Pause</button>
            <button type="button" class="subtle-button" phx-click="resume">Resume</button>
            <button type="button" class="subtle-button" phx-click="refresh">Refresh</button>
          </div>
        </div>
      </section>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Agent usage (from the recorder)</h2>
            <p class="section-copy">
              Why the recorder rather than the dashboard's token card:
              <strong>the ACP protocol's <code>usage_update</code> carries the context window's
              used/size, never a token total</strong>, so Symphony's own token counters are
              <strong>always 0</strong> for <code>backend: acp</code> (dsh / workbuddy). The recorder
              reads each agent's own session files, so the real numbers are there.
            </p>
          </div>
        </div>

        <%= if @usage == [] do %>
          <p class="empty-state">
            No recorder data (4010 is not up, or <code>:recorder_upstream</code> is wrong).
          </p>
        <% else %>
          <div class="table-wrap">
            <table class="data-table" style="min-width: 520px;">
              <thead>
                <tr>
                  <th>agent</th>
                  <th>sessions</th>
                  <th>tokensUsed</th>
                  <th>largest context window</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @usage}>
                  <td><span class="mono"><%= row.agent %></span></td>
                  <td class="numeric"><%= row.sessions %></td>
                  <td class="numeric"><%= format_int(row.tokens) %></td>
                  <td class="numeric"><%= format_int(row.context) %></td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>
      </section>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Context windows (running sessions)</h2>
            <p class="section-copy">
              Which agent each running session is on (backend / adapter / model) and how full its
              context window is. Moved off the dashboard, which shows upstream's columns only.
            </p>
          </div>
        </div>

        <%= if @sessions == [] do %>
          <p class="empty-state">No running session reports a context window.</p>
        <% else %>
          <div class="table-wrap">
            <table class="data-table" style="min-width: 760px;">
              <thead>
                <tr>
                  <th>Issue</th>
                  <th>State</th>
                  <th>agent</th>
                  <th>Context</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={session <- @sessions}>
                  <td><span class="issue-id"><%= session.identifier %></span></td>
                  <td>
                    <span class={Layouts.state_badge_class(session.state)}><%= session.state %></span>
                  </td>
                  <td class="mono event-meta"><%= session.route %></td>
                  <td class="numeric">
                    <%= format_int(session.context.used) %> / <%= format_int(session.context.size) %>
                    (<%= session.context.percent %>%)
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>
      </section>

      <Layouts.project_overview projects={@projects} conflicts={@queue_conflicts} />

      <%= if @site do %>
        <Layouts.site_card site={@site} />
      <% end %>

      <Layouts.ticket_discussions tickets={@tickets} title="Ticket states and discussions" />
    </section>
    """
  end

  attr(:href, :string, required: true)
  attr(:label, :string, required: true)
  attr(:copy, :string, required: true)

  defp hub_link(assigns) do
    ~H"""
    <div class="dep-node">
      <a class="issue-link" href={@href}><%= @label %></a>
      <span class="dep-arrow">·</span>
      <span class="dep-list"><%= @copy %></span>
    </div>
    """
  end

  # One snapshot read per refresh, shared by the runtime switch and the context table: `Presenter`
  # asks the orchestrator, so reading it twice would double the cost of one page render.
  defp assign_panels(socket) do
    payload = load_payload()

    socket
    |> assign(:payload, payload)
    |> assign(:sessions, sessions_with_context(payload))
    |> assign(:site, site_info())
    |> assign(:tickets, load_tickets())
    |> assign(:usage, load_usage())
    |> assign_site_projects()
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp paused?(payload), do: Map.get(payload, :paused, false) == true

  # One row per running session that reports a context window. A session that reports none is left
  # out rather than shown as a zero the agent never claimed (see `Presenter.running_entry_payload/1`).
  defp sessions_with_context(payload) do
    payload
    |> Map.get(:running, [])
    |> Enum.filter(&Map.get(&1, :context))
    |> Enum.map(fn entry ->
      %{
        identifier: entry.issue_identifier,
        state: entry.state || "running",
        route: route_line(entry),
        context: entry.context
      }
    end)
  end

  defp route_line(entry) do
    [entry[:backend], entry[:adapter], entry[:model]]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "-"
      parts -> Enum.join(parts, " / ")
    end
  end

  # The control action goes through `Orchestrator.pause/1` `resume/1` -- the same entry points
  # `Presenter` uses for the snapshot, and the ones that answer `:unavailable` when the orchestrator
  # is not running. The state shown afterwards is read back from the orchestrator, not assumed from
  # the click.
  defp control(socket, :pause), do: run_control(socket, &Orchestrator.pause/1)
  defp control(socket, :resume), do: run_control(socket, &Orchestrator.resume/1)

  defp run_control(socket, call) do
    case call.(orchestrator()) do
      :unavailable ->
        {:noreply, assign(socket, :control_error, "The orchestrator is unavailable.")}

      _payload ->
        {:noreply, socket |> assign_panels() |> assign(:control_error, nil)}
    end
  end

  defp site_info do
    Settings.site()
  rescue
    _error -> nil
  end

  defp load_tickets do
    case TaskComposer.list_tickets() do
      {:ok, tickets} -> tickets
      {:error, _reason} -> []
    end
  rescue
    _error -> []
  end

  # From the recorder, because ACP does not report token totals (see the panel's own text). No
  # caching on purpose: this page already re-reads the ticket files on every mount, and a stale
  # usage number is worse than a slightly slower page.
  defp load_usage do
    case RecorderClient.usage() do
      {:ok, rows} -> rows
      {:error, _reason} -> []
    end
  rescue
    _error -> []
  end

  defp load_projects do
    Projects.list()
  rescue
    _error -> []
  end

  # The registry is read **once**: `Projects.list/0` probes every project over HTTP, so calling it
  # twice to answer two questions about the same list doubled the cost of an optional panel.
  #
  # Two projects on one queue is not a display detail either way: both instances would race for the
  # same tickets and both janitors would mirror one ticket repository.
  defp assign_site_projects(socket) do
    projects = load_projects()

    socket
    |> assign(:projects, projects)
    |> assign(:queue_conflicts, Projects.queue_conflicts(projects))
  rescue
    _error -> socket |> assign(:projects, []) |> assign(:queue_conflicts, %{})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"
end
