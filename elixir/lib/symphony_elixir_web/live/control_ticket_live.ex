defmodule SymphonyElixirWeb.ControlTicketLive do
  @moduledoc """
  One ticket, laid out like an issue page: the description (the ticket's Markdown body), the comments
  the janitor mirrored into `## Discussion`, the `links:` entries (where the pull request is
  recorded), the branch name, the blockers and the agent route.

  Read-only, like the board. The only affordances are links out -- to the ticket file on disk, to the
  issue it mirrors, and to the pull request -- plus a refresh of the file being shown.

  ## Whose ticket this is: `?project=<name>`

  Without a parameter this is a ticket in this instance's own queue. With `?project=<name>` the named
  registry project's workflow file supplies the tracker settings, so a project whose instance is down
  is still readable here. Every link the page makes -- the board, a blocker -- carries the parameter,
  so a reader never silently crosses from one project's queue into this instance's. An unknown name
  or an unreadable file is shown as the reason, never as "no such ticket".
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Layouts, TicketPresenter}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok, assign(socket, ticket_id: id, ticket: nil, error: nil, project: nil)}
  end

  # The query string, not the mount params: `handle_params/3` sees the URI on a page load **and** on a
  # live navigation, so the parameter cannot depend on how the page was reached.
  @impl true
  def handle_params(params, _uri, socket) do
    socket = assign(socket, :project, present(params["project"]))
    {:noreply, load_ticket(socket, socket.assigns.ticket_id)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_ticket(socket, socket.assigns.ticket_id)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Symphony Tracker</p>
            <h1 class="hero-title"><%= @ticket_id %></h1>
            <p class="hero-copy"><%= @ticket && @ticket.title %></p>
            <%= if @project do %>
              <p class="hero-copy">
                Read from the queue of project <span class="mono"><%= @project %></span>, named in the
                registry -- not from this instance's own tracker.
              </p>
            <% end %>
          </div>
          <Layouts.page_nav current={:control} />
        </div>
      </header>

      <%= if @error do %>
        <section class="error-card">
          <h2 class="error-title">This ticket could not be read</h2>
          <p class="error-copy"><%= @error %></p>
        </section>
      <% end %>

      <%= if @ticket == nil && @error == nil do %>
        <section class="section-card">
          <p class="empty-state">
            No ticket with this identifier is in the queue.
            <a class="issue-link" href={Layouts.tickets_path(@project)}>back to the board</a>
          </p>
        </section>
      <% end %>

      <%= if @ticket do %>
        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">The ticket</h2>
              <p class="section-copy">
                <a class="issue-link" href={Layouts.tickets_path(@project)}>back to the board</a>
                <span class="dep-arrow">·</span>
                <button type="button" class="subtle-button" phx-click="refresh">Refresh</button>
              </p>
            </div>
          </div>

          <div class="dep-graph">
            <div class="dep-node">
              <span class="issue-id">state</span>
              <span class={Layouts.state_badge_class(@ticket.state)}><%= @ticket.state %></span>
              <span class="dep-arrow">·</span>
              <span class="muted">priority</span>
              <span class="dep-list"><%= @ticket.priority || "-" %></span>
            </div>

            <div class="dep-node">
              <span class="issue-id">labels</span>
              <span class="dep-list"><%= join(@ticket.labels) %></span>
            </div>

            <div class="dep-node">
              <span class="issue-id">assignee</span>
              <span class="dep-list"><%= @ticket.assignee || "-" %></span>
            </div>

            <div class="dep-node">
              <span class="issue-id">branch</span>
              <span class="mono dep-list"><%= @ticket.branch_name || "-" %></span>
            </div>

            <div class="dep-node">
              <span class="issue-id">agent</span>
              <span class="mono dep-list"><%= route(@ticket) %></span>
            </div>

            <div class="dep-node">
              <span class="issue-id">file</span>
              <span class="mono dep-list"><%= @ticket.path || "not found beside the queue" %></span>
            </div>
          </div>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Links</h2>
              <p class="section-copy">
                The issue this ticket mirrors, the pull request the janitor recorded on it, and any
                other `links:` entry in its front matter.
              </p>
            </div>
          </div>

          <div class="dep-graph">
            <%= if @ticket.url do %>
              <div class="dep-node">
                <span class="issue-id">issue</span>
                <a class="issue-link" href={@ticket.url} target="_blank" rel="noopener noreferrer">open the issue</a>
              </div>
            <% end %>

            <%= if @ticket.pr_url do %>
              <div class="dep-node">
                <span class="issue-id">pull request</span>
                <a class="issue-link" href={@ticket.pr_url} target="_blank" rel="noopener noreferrer"><%= @ticket.pr_url %></a>
              </div>
            <% end %>

            <div :for={link <- other_links(@ticket)} class="dep-node">
              <span class="issue-id"><%= link.kind %></span>
              <a class="issue-link" href={link.url} target="_blank" rel="noopener noreferrer"><%= link.title %></a>
            </div>

            <%= if @ticket.links == [] and @ticket.url == nil do %>
              <span class="muted">No link is recorded on this ticket.</span>
            <% end %>
          </div>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Blocked by</h2>
              <p class="section-copy">
                A blocker holds this ticket back only while it is unfinished and this ticket is still in
                the workflow's first active state.
              </p>
            </div>
          </div>

          <%= if @ticket.blocked_by == [] do %>
            <p class="empty-state">Nothing blocks this ticket.</p>
          <% else %>
            <div class="dep-graph">
              <div :for={blocker <- @ticket.blocked_by} class="dep-node">
                <a class="issue-id issue-id-link" href={Layouts.ticket_path(blocker.identifier, @project)}>
                  <%= blocker.identifier %>
                </a>
                <span class="dep-arrow">·</span>
                <span class={Layouts.state_badge_class(blocker.state || "unknown")}>
                  <%= blocker.state || "unknown" %>
                </span>
              </div>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Description</h2>
              <p class="section-copy">The ticket body, as written -- this is what the agent is given.</p>
            </div>
          </div>

          <pre class="code-panel"><%= @ticket.description %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Comments</h2>
              <p class="section-copy">
                The `## Discussion` section: the issue comments the janitor mirrored, each with its
                author and its stable id.
              </p>
            </div>
          </div>

          <%= if @ticket.discussion == [] do %>
            <p class="empty-state">No comment on this ticket yet.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 760px;">
                <thead>
                  <tr>
                    <th>Author</th>
                    <th>At</th>
                    <th>Id</th>
                    <th>Comment</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={comment <- @ticket.discussion}>
                    <td class="mono"><%= comment.author %></td>
                    <td class="mono numeric"><%= comment.at %></td>
                    <td class="mono"><%= comment.id %></td>
                    <td><%= comment.text %></td>
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

  defp load_ticket(socket, id) do
    socket = assign(socket, :ticket_id, id) |> assign(:ticket, nil) |> assign(:error, nil)

    case TicketPresenter.fetch(id, project: socket.assigns.project) do
      {:ok, ticket} -> assign(socket, :ticket, ticket)
      {:error, :not_found} -> socket
      {:error, reason} -> assign(socket, :error, TicketPresenter.describe(reason))
    end
  end

  # "" is not a project name: a link that wants this instance's own queue says nothing, rather than
  # naming a project that cannot exist.
  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defp other_links(ticket) do
    Enum.reject(ticket.links, &(&1.url == ticket.pr_url))
  end

  defp route(ticket) do
    [ticket.adapter, ticket.model]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "the project's route"
      parts -> Enum.join(parts, " / ")
    end
  end

  defp join([]), do: "-"
  defp join(values), do: Enum.join(values, ", ")
end
