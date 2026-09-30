defmodule SymphonyElixirWeb.ControlTicketLive do
  @moduledoc """
  One ticket, laid out like an issue page: the description (the ticket's Markdown body), the comments
  the janitor mirrored into `## Discussion`, the `links:` entries (where the pull request is
  recorded), the branch name, the blockers and the agent route.

  Read-only except for the two writes an issue page cannot do without: a state picker and a comment box.
  Everything else is an affordance to read -- links out to the ticket file on disk, to the issue it
  mirrors and to the pull request -- plus a refresh of the file being shown.

  ## The two writes go through the host, not through this page

  `SymphonyElixir.Janitor.set_ticket_state/3` replaces the ticket's `state` key and
  `SymphonyElixir.Janitor.comment_on_ticket/3` appends one `## Discussion` entry; neither is done here.
  A ticket file is UTF-8 and its only safe writer is one that hands its own bytes back unchanged, which
  the janitor is and a view is not, so this page submits and then reads the result back.

  Both controls are shaped by the project rather than by this page:

    * the states offered are the workflow's own `active_states` and `terminal_states`
      (`TicketPresenter.declared_states/1`), never a list written here, because those two lists are the
      scheduler's vocabulary -- a state nobody declared is a ticket nothing picks up again;
    * a comment is signed **operator**, not `agent`: the entry is what the ticket's own history shows,
      and who said it is the one thing a flattened discussion line can still carry.

  ## A refused write changes nothing

  A state the workflow does not declare, an empty comment, or the write path's own `{:error, reason}`
  (including `{:ticket_not_utf8, id}`, should a ticket ever be damaged) is rendered in the page and
  leaves the file byte for byte as it was. Nothing is written unless one of the two forms is submitted.
  A write that succeeded re-reads the ticket, so the new state or comment is on the page without a
  manual refresh; a write that failed re-reads nothing, so the page still shows the ticket and the
  reason it was refused.

  ## Whose ticket this is: `?project=<name>`

  Without a parameter this is a ticket in this instance's own queue. With `?project=<name>` the named
  registry project's workflow file supplies the tracker settings, so a project whose instance is down
  is still readable here. Every link the page makes -- the board, a blocker -- carries the parameter,
  so a reader never silently crosses from one project's queue into this instance's. An unknown name
  or an unreadable file is shown as the reason, never as "no such ticket". A write follows the same
  parameter: `TicketPresenter.write_options/1` names the queue that project reads its tickets from, so
  a write while reading another project cannot land in this instance's files.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Janitor
  alias SymphonyElixirWeb.{Layouts, TicketPresenter}

  # What a comment written from this page is signed with. Not the agent's name: the agent reads this
  # discussion on its next run, and a note from the person running the console has to be distinguishable
  # from the agent's own.
  @operator "operator"

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     assign(socket,
       ticket_id: id,
       ticket: nil,
       error: nil,
       action_error: nil,
       states: [],
       project: nil
     )}
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

  # Both writes are handled through one accessor each, so a form that arrives without its field is a
  # refusal the page can render rather than a `FunctionClauseError` that takes the LiveView down.
  @impl true
  def handle_event("set_state", params, socket) do
    {:noreply, submit_state(socket, params["state"])}
  end

  @impl true
  def handle_event("comment", params, socket) do
    {:noreply, submit_comment(socket, params["comment"])}
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

      <%= if @action_error do %>
        <section class="error-card">
          <h2 class="error-title">That change was not written</h2>
          <p class="error-copy"><%= @action_error %></p>
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
              <h2 class="section-title">Change state</h2>
              <p class="section-copy">
                The states this project's workflow declares:
                <span class="mono">active_states</span> and <span class="mono">terminal_states</span>.
                The write is the host's -- it replaces the <span class="mono">state</span> key and hands
                every other byte of the file back as it was.
              </p>
            </div>
          </div>

          <%= if @states == [] do %>
            <p class="empty-state">This project's workflow declares no state this page could offer.</p>
          <% else %>
            <form class="task-form" phx-submit="set_state">
              <label class="form-field">
                <span class="form-label">State</span>
                <select id="state" name="state" class="form-input">
                  <option :for={state <- @states} value={state} selected={state == @ticket.state}><%= state %></option>
                </select>
              </label>

              <button type="submit" class="task-submit">Set state</button>
            </form>
          <% end %>
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

          <form class="task-form" phx-submit="comment">
            <label class="form-field">
              <span class="form-label">Add a comment</span>
              <textarea
                id="comment"
                name="comment"
                class="form-textarea"
                rows="3"
                required
                placeholder="What the next reader should know"
              ></textarea>
            </label>

            <span class="form-hint">
              Appended to `## Discussion` and signed <span class="mono">operator</span> -- not the
              agent -- so the ticket's own history says who wrote it.
            </span>

            <button type="submit" class="task-submit">Add comment</button>
          </form>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_ticket(socket, id) do
    socket = assign(socket, :ticket_id, id) |> assign(:ticket, nil) |> assign(:error, nil)

    case TicketPresenter.fetch(id, project: socket.assigns.project) do
      {:ok, ticket} -> socket |> assign(:ticket, ticket) |> assign_states()
      {:error, :not_found} -> assign(socket, :states, [])
      {:error, reason} -> socket |> assign(:states, []) |> assign(:error, TicketPresenter.describe(reason))
    end
  end

  # The states the picker offers: the workflow's, with the ticket's own state in front of them when the
  # workflow no longer declares it. A ticket can sit in a state somebody set by hand, and a picker whose
  # selected entry is not the ticket's state would move it on the next submit without anyone asking.
  defp assign_states(%{assigns: %{ticket: %{state: current}}} = socket) do
    case TicketPresenter.declared_states(project: socket.assigns.project) do
      {:ok, states} ->
        assign(socket, :states, offered(states, current))

      {:error, reason} ->
        socket |> assign(:states, []) |> assign(:error, TicketPresenter.describe(reason))
    end
  end

  defp offered(states, current) do
    cond do
      not is_binary(current) or current == "" -> states
      current in states -> states
      true -> [current | states]
    end
  end

  defp submit_state(socket, state) do
    cond do
      socket.assigns.ticket == nil -> socket
      state not in socket.assigns.states -> assign(socket, :action_error, refused_state(state))
      true -> write_state(socket, state)
    end
  end

  defp refused_state(state) when is_binary(state) do
    "The state #{state} is not one of the states this workflow declares, so nothing was written."
  end

  defp refused_state(_state), do: "No state was submitted, so nothing was written."

  defp write_state(socket, state) do
    with {:ok, options} <- TicketPresenter.write_options(project: socket.assigns.project),
         {:ok, _result} <- Janitor.set_ticket_state(socket.assigns.ticket_id, state, options) do
      reload(socket)
    else
      {:error, reason} -> assign(socket, :action_error, TicketPresenter.describe(reason))
    end
  end

  defp submit_comment(socket, body) do
    cond do
      socket.assigns.ticket == nil -> socket
      not is_binary(body) or String.trim(body) == "" -> assign(socket, :action_error, empty_comment())
      true -> write_comment(socket, body)
    end
  end

  defp empty_comment, do: "The comment is empty, so nothing was written."

  defp write_comment(socket, body) do
    with {:ok, options} <- TicketPresenter.write_options(project: socket.assigns.project),
         {:ok, _result} <-
           Janitor.comment_on_ticket(socket.assigns.ticket_id, body, [author: @operator] ++ options) do
      reload(socket)
    else
      {:error, reason} -> assign(socket, :action_error, TicketPresenter.describe(reason))
    end
  end

  # After a write that succeeded: the ticket is re-read, so the new state or comment is on the page
  # without a manual refresh.
  #
  # A write that *failed* reloads nothing, deliberately. The page has to keep showing the ticket and the
  # reason the host refused it, and one of those reasons is a ticket file whose bytes are damaged -- a
  # re-read would turn "refused" into "no ticket with this identifier", which is a different story.
  defp reload(socket) do
    socket |> assign(:action_error, nil) |> load_ticket(socket.assigns.ticket_id)
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
