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

  ## Starting and stopping other instances

  The project table's `Start` / `Stop` buttons are the two events that change something outside this
  process, so they are the two that must not be able to break this page. Both go through
  `InstanceRegistry`, which answers `{:ok, _}` or `{:error, reason}` and refuses the hub's own
  instance outright; whatever comes back is put **in that row** (`@instance_outcomes`), and the page
  re-reads the panels afterwards so the row shows the state that resulted rather than the state the
  click assumed. Nothing here can raise a page: the call is wrapped even though the registry already
  answers reasons rather than raising.

  The event carries a **project name**, never a path: `InstanceRegistry.start_instance/2` looks the
  name up in the registry, which is what makes "start an arbitrary file" unrepresentable rather than
  merely discouraged.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{InstanceRegistry, Orchestrator, Projects, ProjectStatus, RecorderClient, Settings, TaskComposer}
  alias SymphonyElixirWeb.{Endpoint, Layouts, ObservabilityPubSub, Presenter}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :ok = ObservabilityPubSub.subscribe()

    {:ok,
     socket
     |> assign_panels()
     |> assign(:control_error, nil)
     |> assign(:instance_outcomes, %{})}
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
    {:noreply, socket |> assign_panels() |> assign(:control_error, nil) |> assign(:instance_outcomes, %{})}
  end

  @impl true
  def handle_event("start_instance", %{"project" => name}, socket), do: instance_action(socket, name, :start)

  @impl true
  def handle_event("stop_instance", %{"project" => name}, socket), do: instance_action(socket, name, :stop)

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

      <Layouts.project_overview
        projects={@projects}
        conflicts={@queue_conflicts}
        controls={@instance_controls}
        outcomes={@instance_outcomes}
      />

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

  defp project_status_client, do: Endpoint.config(:project_status_client)

  defp project_status_timeout_ms, do: Endpoint.config(:project_status_timeout_ms) || 1_500

  # The registry is read **once**: `Projects.list/1` probes every project over HTTP, so calling it
  # twice to answer two questions about the same list doubled the cost of an optional panel.
  #
  # Two projects on one queue is not a display detail either way: both instances would race for the
  # same tickets and both janitors would mirror one ticket repository.
  #
  # Every row is then overlaid with what the hub knows about it (`InstanceRegistry.overlay/2`): a
  # project the hub started is probed on the port the hub **assigned** it, and each row's control
  # action is decided from the state that probe came back with -- so "up" and "the hub's to stop" are
  # two different facts and neither is assumed from the other.
  defp assign_site_projects(socket) do
    records = InstanceRegistry.records(instance_opts())
    rows = InstanceRegistry.overlay(Projects.list(probe: false), records)

    projects =
      ProjectStatus.list(
        projects: rows,
        client: project_status_client(),
        timeout: project_status_timeout_ms()
      )

    socket
    |> assign(:projects, projects)
    |> assign(:instance_controls, Map.new(projects, &{&1.name, InstanceRegistry.action(&1)}))
    |> assign(:queue_conflicts, Projects.queue_conflicts(projects))
  rescue
    _error ->
      socket
      |> assign(:projects, [])
      |> assign(:instance_controls, %{})
      |> assign(:queue_conflicts, %{})
  end

  # What a start or a stop did, put in the row it belongs to and nowhere else -- and wrapped, because
  # "the page renders" outranks "the page explains": a stub that raises must produce a row with a
  # reason in it, exactly like `ProjectStatus.attach/2` treats a client that raises.
  defp instance_action(socket, name, action) do
    outcome = safe_instance_outcome(name, action, instance_opts())

    {:noreply,
     socket
     |> assign(:instance_outcomes, Map.put(socket.assigns[:instance_outcomes] || %{}, name, outcome))
     |> assign_panels()
     |> put_unroutable_outcome(name, outcome)}
  end

  # An outcome lives in a row, so it needs a row to live in. An event naming something the registry
  # does not list -- a crafted `phx-value-project`, or a project deleted while the page was open --
  # has no row, and its refusal would otherwise be invisible. It goes to the page's own error card
  # instead, which is where failures that are not about one row already land.
  defp put_unroutable_outcome(socket, name, {:error, reason}) do
    if Enum.any?(socket.assigns[:projects] || [], &(&1.name == name)) do
      socket
    else
      assign(socket, :control_error, "#{name}: #{reason}")
    end
  end

  defp put_unroutable_outcome(socket, _name, _outcome), do: socket

  defp safe_instance_outcome(name, :start, opts) do
    case InstanceRegistry.start_instance(name, opts) do
      {:ok, record} ->
        {:ok, "started pid #{record.pid} on port #{record.port} (logs: #{record.logs_root})"}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, "the hub raised: #{Exception.message(error)}"}
  catch
    kind, reason -> {:error, "the hub exited: #{kind} #{inspect(reason)}"}
  end

  defp safe_instance_outcome(name, :stop, opts) do
    case InstanceRegistry.stop_instance(name, opts) do
      :ok -> {:ok, "stopped"}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, "the hub raised: #{Exception.message(error)}"}
  catch
    kind, reason -> {:error, "the hub exited: #{kind} #{inspect(reason)}"}
  end

  # The four functions the hub would otherwise have to spawn a process, open a socket or kill one to
  # answer, injected the same way `:project_status_client` is. `nil` means "use the real one", which
  # is what every environment except a test wants.
  defp instance_opts do
    [
      launcher: Endpoint.config(:instance_launcher),
      held?: Endpoint.config(:instance_port_held?),
      alive?: Endpoint.config(:instance_alive?),
      kill: Endpoint.config(:instance_kill),
      own_port: Endpoint.config(:instance_own_port)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
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
