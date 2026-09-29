defmodule SymphonyElixirWeb.ControlTicketsLive do
  @moduledoc """
  The ticket board: every ticket in the queue, filterable and sortable, shaped like a tracker rather
  than a file dump.

  Read-only. State changes are made by the agent (it edits its own ticket) and by the janitor (it
  mirrors the issue), so this page offers no write affordance at all -- only filters, sorting, a
  refresh and a link to each ticket's own page. `TicketPresenter` explains where the fields come from.

  Filters are ordinary LiveView state (`phx-change` on the form), not a query string: the page reads a
  directory, not a database, and a filter that survives a reload was not asked for.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Layouts, TicketPresenter}

  @any "any"
  @filters ["state", "label", "assignee", "priority"]
  @states ["ready", "in-progress", "in-review", "paused", "blocked", "done", "cancelled"]
  @sorts ["identifier", "priority", "state", "title"]

  @impl true
  def mount(_params, _session, socket) do
    socket
    |> assign(:filters, default_filters())
    |> assign(:sorts, @sorts)
    |> load_tickets()
    |> then(&{:ok, &1})
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    {:noreply, socket |> assign(:filters, normalize(params)) |> load_tickets()}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_tickets(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Symphony Tracker</p>
            <h1 class="hero-title">Tickets</h1>
            <p class="hero-copy">
              The queue as a tracker: state, priority, labels, assignee, blockers, branch and the pull
              request each ticket carries. Read-only -- the agent and the janitor own the writes.
            </p>
          </div>
          <Layouts.page_nav current={:control} />
        </div>
      </header>

      <%= if @error do %>
        <section class="error-card">
          <h2 class="error-title">The ticket queue could not be read</h2>
          <p class="error-copy"><%= @error %></p>
        </section>
      <% else %>
        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Board</h2>
              <p class="section-copy">
                <%= length(@visible) %> of <%= length(@tickets) %> tickets
                <%= if @summary != "" do %>
                  -- <%= @summary %>
                <% end %>
              </p>
            </div>
          </div>

          <form class="task-form" phx-change="filter" phx-submit="filter">
            <.filter_select name="state" label="State" value={@filters["state"]} options={@options.states} />
            <.filter_select name="label" label="Label" value={@filters["label"]} options={@options.labels} />
            <.filter_select name="assignee" label="Assignee" value={@filters["assignee"]} options={@options.assignees} />
            <.filter_select name="priority" label="Priority" value={@filters["priority"]} options={@options.priorities} />

            <div class="form-field">
              <label class="form-label" for="sort">Sort</label>
              <select id="sort" name="filters[sort]" class="form-input">
                <option :for={sort <- @sorts} value={sort} selected={@filters["sort"] == sort}><%= sort %></option>
              </select>
            </div>

            <div class="form-field">
              <button type="button" class="subtle-button" phx-click="refresh">Refresh</button>
            </div>
          </form>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Tickets</h2>
              <p class="section-copy">Click a ticket to open its description, comments and links.</p>
            </div>
          </div>

          <%= if @visible == [] do %>
            <p class="empty-state">No ticket matches these filters.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 1100px;">
                <thead>
                  <tr>
                    <th>Ticket</th>
                    <th>Title</th>
                    <th>State</th>
                    <th>Priority</th>
                    <th>Labels</th>
                    <th>Assignee</th>
                    <th>Blocked by</th>
                    <th>Branch</th>
                    <th>Pull request</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={ticket <- @visible}>
                    <td>
                      <a class="issue-id issue-id-link" href={"/control/tickets/#{ticket.identifier}"}>
                        <%= ticket.identifier %>
                      </a>
                    </td>
                    <td><%= ticket.title %></td>
                    <td>
                      <span class={Layouts.state_badge_class(ticket.state)}><%= ticket.state %></span>
                    </td>
                    <td class="numeric"><%= ticket.priority || "-" %></td>
                    <td class="mono event-meta"><%= list_or_dash(ticket.labels) %></td>
                    <td class="mono event-meta"><%= ticket.assignee || "-" %></td>
                    <td class="mono event-meta"><%= blockers(ticket.blocked_by) %></td>
                    <td class="mono event-meta"><%= ticket.branch_name || "-" %></td>
                    <td>
                      <%= if ticket.pr_url do %>
                        <a class="issue-link" href={ticket.pr_url} target="_blank" rel="noopener noreferrer">PR</a>
                      <% else %>
                        <span class="muted">-</span>
                      <% end %>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  attr(:name, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:options, :list, required: true)

  defp filter_select(assigns) do
    ~H"""
    <div class="form-field">
      <label class="form-label" for={@name}><%= @label %></label>
      <select id={@name} name={"filters[#{@name}]"} class="form-input">
        <option value="any" selected={@value == "any"}>any</option>
        <option :for={option <- @options} value={option} selected={@value == option}><%= option %></option>
      </select>
    </div>
    """
  end

  defp default_filters, do: Map.new(@filters, &{&1, @any}) |> Map.put("sort", "identifier")

  defp normalize(params) do
    filters = Map.new(@filters, &{&1, present(params[&1]) || @any})
    sort = params["sort"]

    Map.put(filters, "sort", if(sort in @sorts, do: sort, else: "identifier"))
  end

  defp load_tickets(socket) do
    case TicketPresenter.list() do
      {:ok, tickets} ->
        filters = socket.assigns.filters
        visible = tickets |> Enum.filter(&matches?(&1, filters)) |> apply_sort(filters["sort"])

        socket
        |> assign(:tickets, tickets)
        |> assign(:visible, visible)
        |> assign(:options, options(tickets))
        |> assign(:summary, summary(tickets))
        |> assign(:error, nil)

      {:error, reason} ->
        socket
        |> assign(:tickets, [])
        |> assign(:visible, [])
        |> assign(:options, options([]))
        |> assign(:summary, "")
        |> assign(:error, TicketPresenter.describe(reason))
    end
  end

  defp matches?(ticket, filters) do
    matches_value?(filters["state"], ticket.state) and
      matches_value?(filters["assignee"], ticket.assignee) and
      matches_value?(filters["priority"], ticket.priority && to_string(ticket.priority)) and
      matches_label?(ticket, filters["label"])
  end

  defp matches_value?(@any, _value), do: true
  defp matches_value?(wanted, value), do: wanted == value

  defp matches_label?(_ticket, @any), do: true
  defp matches_label?(ticket, label), do: label in ticket.labels

  defp apply_sort(tickets, "priority"), do: Enum.sort_by(tickets, &{&1.priority || 999, &1.identifier})
  defp apply_sort(tickets, "state"), do: Enum.sort_by(tickets, &{&1.state, &1.identifier})
  defp apply_sort(tickets, "title"), do: Enum.sort_by(tickets, &{&1.title, &1.identifier})
  defp apply_sort(tickets, _identifier), do: Enum.sort_by(tickets, & &1.identifier)

  defp options(tickets) do
    %{
      states: option_values(Enum.map(tickets, & &1.state), @states),
      labels: option_values(Enum.flat_map(tickets, & &1.labels), []),
      assignees: option_values(Enum.map(tickets, & &1.assignee), []),
      priorities: tickets |> Enum.map(& &1.priority) |> option_values([]) |> Enum.sort() |> Enum.map(&to_string/1)
    }
  end

  # The workflow's own vocabulary first (so an empty queue still offers the states a person expects),
  # then anything else the tickets actually use.
  defp option_values(values, preferred) do
    present = values |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq()

    preferred ++ Enum.reject(present, &(&1 in preferred))
  end

  defp summary(tickets) do
    tickets
    |> Enum.frequencies_by(& &1.state)
    |> Enum.sort()
    |> Enum.map_join(" - ", fn {state, count} -> "#{state} #{count}" end)
  end

  defp blockers([]), do: "-"

  defp blockers(blocked_by) do
    Enum.map_join(blocked_by, ", ", fn blocker ->
      case blocker.state do
        nil -> blocker.identifier
        state -> "#{blocker.identifier} (#{state})"
      end
    end)
  end

  defp list_or_dash([]), do: "-"
  defp list_or_dash(values), do: Enum.join(values, ", ")

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil
end
