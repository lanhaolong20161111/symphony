defmodule SymphonyElixirWeb.ControlTicketLive do
  @moduledoc """
  One ticket, laid out like an issue page: the description (the ticket's Markdown body), the comments
  the janitor mirrored into `## Discussion`, the `links:` entries (where the pull request is
  recorded), the branch name, the blockers and the agent route.

  Read-only except for the three writes an issue page cannot do without: a state picker, a comment
  box, and the last step of the loop this system runs -- landing the ticket's pull request. Everything
  else is an affordance to read -- links out to the ticket file on disk, to the issue it mirrors and to
  the pull request -- plus a refresh of the file being shown.

  ## The writes go through the host, not through this page

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

  ## Landing: the `land` skill's judgement, and its merge

  The loop ends with a pull request that somebody has to merge. This page offers that one step: it
  takes the pull request the ticket records -- the `links:` entry the janitor wrote when it opened it,
  and the branch name beside it -- judges it through the same core the watcher uses
  (`SymphonyElixir.Land.land/3`, which asks `Land.verdict/1`), and squash-merges it with the branch
  deleted only when that judgement says to land.

  The operation is looked up rather than called by name (`land_operation/0`), so a test can put its own
  function in the endpoint config and drive every answer this page has without one `gh` call ever being
  made. What it is handed is only what the ticket records: a ticket that records no pull request, or no
  branch, is told so -- this page does not go looking for a pull request on the ticket's behalf.

  A refusal writes **nothing**: the four verdicts that stop a landing (conflict, checks, feedback, a
  moved head) are rendered with the skill's own reason, and the ticket file is left byte for byte as it
  was. A merge is what moves the ticket on, and a merge always leaves a trace -- the workflow's own
  terminal state, and a `## Discussion` entry naming who asked, the verdict and what the merge did.

  ## A refused write changes nothing

  A state the workflow does not declare, an empty comment, or the write path's own `{:error, reason}`
  (including `{:ticket_not_utf8, id}`, should a ticket ever be damaged) is rendered in the page and
  leaves the file byte for byte as it was. Nothing is written unless one of the three forms is
  submitted. A write that succeeded re-reads the ticket, so the new state or comment is on the page
  without a manual refresh; a write that failed re-reads nothing, so the page still shows the ticket and
  the reason it was refused.

  A landing that merged and then failed to record it is the one case the page reports in two halves,
  because both halves happened: the merge is announced, and the reason the ticket does not yet say so is
  rendered beside it. Losing either half would be the page lying about the state of the world.

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
  alias SymphonyElixir.Land
  alias SymphonyElixirWeb.{Endpoint, Layouts, TicketPresenter}

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
       landed: nil,
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

  # Landing takes no field: the pull request and the branch are the ticket's own, so the submit is the
  # whole request. That is also why the handler takes no params -- there is nothing a form could say
  # that would change what is landed.
  @impl true
  def handle_event("land", _params, socket) do
    {:noreply, submit_land(socket)}
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

      <%= if @landed do %>
        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">The pull request was landed</h2>
              <p class="section-copy"><%= @landed %></p>
            </div>
          </div>
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
              <span class="mono dep-list"><%= @ticket.path || file_note(@ticket) %></span>
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
              <span class="muted"><%= no_link_note(@ticket) %></span>
            <% end %>
          </div>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Land the pull request</h2>
              <p class="section-copy">
                Judges the pull request this ticket records with the `land` skill's own rules -- the
                same core the watcher runs -- and, only when that judgement says to land, squash-merges
                it with its branch deleted. Any other answer merges nothing and writes nothing on this
                ticket; the reason is shown here.
              </p>
            </div>
          </div>

          <%= if landable?(@ticket) do %>
            <form class="task-form" phx-submit="land">
              <span class="form-hint">
                The pull request is taken from this ticket's <span class="mono">links:</span> entry and
                the branch from its <span class="mono">branch_name</span>, never searched for: a
                ticket that records neither is not landed from here.
              </span>

              <button type="submit" class="task-submit">Land pull request</button>
            </form>
          <% else %>
            <p class="empty-state"><%= unlandable(@ticket) %></p>
          <% end %>
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

          <%= if blank_description?(@ticket) do %>
            <p class="empty-state">
              The ticket service holds no description for this ticket. It is still readable: its state,
              its labels, its blockers and its comments are on this page.
            </p>
          <% else %>
            <pre class="code-panel"><%= @ticket.description %></pre>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Comments</h2>
              <p class="section-copy"><%= comments_note(@ticket) %></p>
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
    socket =
      socket
      |> assign(:ticket_id, id)
      |> assign(:ticket, nil)
      |> assign(:error, nil)
      |> assign(:landed, nil)

    case TicketPresenter.fetch(id, read_options(socket)) do
      {:ok, ticket} -> socket |> assign(:ticket, ticket) |> assign_states()
      {:error, :not_found} -> assign(socket, :states, [])
      {:error, reason} -> socket |> assign(:states, []) |> assign(:error, TicketPresenter.describe(reason))
    end
  end

  # Whose queue this is, and the transport that queue is read over. The ticket service's client is
  # injected through the endpoint config exactly like the control plane's `:project_status_client`, so
  # a test drives every answer this page has without one socket being opened; `nil` -- which is what
  # every environment but a test configures -- means the real client.
  defp read_options(socket) do
    [project: socket.assigns.project, client: Endpoint.config(:ticket_reader_client)]
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
         {:ok, _result} <-
           host_write(fn -> Janitor.set_ticket_state(socket.assigns.ticket_id, state, options) end) do
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
           host_write(fn ->
             Janitor.comment_on_ticket(socket.assigns.ticket_id, body, [author: @operator] ++ options)
           end) do
      reload(socket)
    else
      {:error, reason} -> assign(socket, :action_error, TicketPresenter.describe(reason))
    end
  end

  # The host fails closed with an `{:error, reason}` for everything it refuses, but the last step of a
  # write is still a filesystem call, and on Windows a ticket file another writer holds open makes
  # `File.write!/2` raise `File.Error`. A LiveView that came down over that would lose the ticket it was
  # showing, so an unexpected raise is turned into the same shape as a refusal and rendered like one.
  # The land operation is wrapped in the same call for the same reason: it shells out to `gh`, which can
  # fail in ways no `{:error, _}` of ours describes.
  defp host_write(write) do
    write.()
  rescue
    error -> {:error, {:write_raised, Exception.message(error)}}
  end

  ## Landing

  # The one call this page makes that acts on another system, looked up rather than named so that a
  # test can put its own function in the endpoint config -- the same place this application keeps the
  # rest of the settings this page reads -- and no `gh` is ever run. It is handed a pull request URL
  # and a branch, and nothing else: those two are what the ticket records, and a caller that cannot
  # name both is refused before this is reached.
  defp land_operation do
    :symphony_elixir
    |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
    |> Keyword.get(:ticket_land, &Land.land/2)
  end

  defp landable?(%{pr_url: pr_url, branch_name: branch}), do: is_binary(pr_url) and is_binary(branch)

  defp unlandable(%{pr_url: pr_url}) when not is_binary(pr_url), do: no_pull_request()
  defp unlandable(_ticket), do: no_branch()

  defp no_pull_request do
    "This ticket records no pull request, so there is nothing to land. The janitor records one as a " <>
      "links: entry when it opens it; nothing was searched for and nothing was merged."
  end

  defp no_branch do
    "This ticket records no branch for its pull request, so the pull request it names cannot be " <>
      "confirmed as the one that was opened for it. Nothing was merged."
  end

  defp submit_land(%{assigns: %{ticket: nil}} = socket), do: socket

  defp submit_land(%{assigns: %{ticket: ticket}} = socket) do
    cond do
      not is_binary(ticket.pr_url) -> assign(socket, :action_error, no_pull_request())
      not is_binary(ticket.branch_name) -> assign(socket, :action_error, no_branch())
      true -> land_ticket(socket, ticket)
    end
  end

  defp land_ticket(socket, ticket) do
    operation = land_operation()

    case host_write(fn -> operation.(ticket.pr_url, ticket.branch_name) end) do
      {:ok, merged} -> record_landing(socket, merged)
      {:refused, code, messages} -> assign(socket, :action_error, refused_landing(code, messages))
      {:error, reason} -> assign(socket, :action_error, land_failed(reason))
    end
  end

  # A merge is the only thing that moves the ticket, so this is reached only when a merge happened.
  # The state first, then the comment, because the state is what the scheduler reads: if only one of
  # the two can be written, the one that decides whether the ticket is picked up again is the one that
  # has to land.
  defp record_landing(socket, merged) do
    with {:ok, options} <- TicketPresenter.write_options(project: socket.assigns.project),
         {:ok, terminal} <- TicketPresenter.terminal_state(project: socket.assigns.project) do
      apply_landing(socket, merged, terminal, options)
    else
      {:error, reason} ->
        landed_page(socket, merged, "The ticket was not updated: " <> TicketPresenter.describe(reason))
    end
  end

  defp apply_landing(socket, merged, terminal, options) do
    case host_write(fn -> Janitor.set_ticket_state(socket.assigns.ticket_id, terminal, options) end) do
      {:ok, _result} -> comment_landing(socket, merged, terminal, options)
      {:error, reason} -> landed_page(socket, merged, not_moved(terminal, reason))
    end
  end

  defp comment_landing(socket, merged, terminal, options) do
    note = landing_note(merged, terminal)

    case host_write(fn ->
           Janitor.comment_on_ticket(socket.assigns.ticket_id, note, [author: @operator] ++ options)
         end) do
      {:ok, _result} -> landed_page(socket, merged, nil)
      {:error, reason} -> landed_page(socket, merged, not_recorded(terminal, reason))
    end
  end

  defp not_moved(terminal, reason) do
    "The pull request was merged, but the ticket was not moved to #{terminal}: " <>
      TicketPresenter.describe(reason)
  end

  defp not_recorded(terminal, reason) do
    "The pull request was merged and the ticket was moved to #{terminal}, but the outcome was not " <>
      "written on it: " <> TicketPresenter.describe(reason)
  end

  # Both halves of a landing that did not finish: the merge happened, and the ticket does not (yet) say
  # so. The ticket is re-read first, because `reload/1` is what clears the previous reason.
  defp landed_page(socket, merged, reason) do
    socket
    |> reload()
    |> assign(:landed, landed_message(merged))
    |> assign(:action_error, reason)
  end

  defp landed_message(merged) do
    "Pull request #{merged.number} was squash-merged with its branch deleted."
  end

  # The ticket's own record of a landing: who asked, what the judgement was, and what the merge did.
  # One line, because `Ticket.append_comment/4` flattens newlines -- a comment here cannot be a
  # document, so it says the three things a reader would otherwise have to ask for.
  defp landing_note(merged, terminal) do
    "#{@operator} asked to land pull request #{merged.number} (#{merged.url}). " <>
      "Land verdict: ok (exit 0). Result: squash-merged with the branch deleted. " <>
      "This ticket was moved to #{terminal}."
  end

  defp refused_landing(code, messages) do
    "The land verdict is #{verdict_name(code)} (exit #{code}), so nothing was merged and nothing was " <>
      "written on this ticket: #{Enum.join(messages, " ")}"
  end

  # The skill's own names for its codes, so a reader who knows the skill recognises the answer without
  # looking the number up.
  defp verdict_name(2), do: "feedback"
  defp verdict_name(3), do: "checks"
  defp verdict_name(4), do: "head moved"
  defp verdict_name(5), do: "conflict"

  defp land_failed(reason) do
    "The pull request could not be landed: #{land_reason(reason)}. Nothing was merged and nothing was " <>
      "written on this ticket."
  end

  defp land_reason({:merge_failed, reason}), do: "gh refused the merge: " <> land_reason(reason)

  defp land_reason({:branch_mismatch, recorded, actual}) do
    "the pull request's head branch is #{actual}, not the #{recorded} this ticket records"
  end

  defp land_reason({:not_a_pull_request, other}), do: "gh did not answer with a pull request: #{land_reason(other)}"
  defp land_reason(reason) when is_binary(reason), do: reason
  defp land_reason(reason), do: inspect(reason)

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

  # The ticket's own file, or why it has none. "not found beside the queue" is a claim about a queue,
  # and a ticket read from the service never came from one.
  defp file_note(%{tracker: :service}), do: "read from the ticket service, not from a file"
  defp file_note(_ticket), do: "not found beside the queue"

  # A ticket with no link is told so in its own tracker's words. The service keeps attachments rather
  # than the file tracker's `links:` entries, and this page does not read them: "no link is recorded"
  # would be a claim about a store this page never asked.
  defp no_link_note(%{tracker: :service}) do
    "No URL is recorded on this ticket by the ticket service; its attachments are not read by this page."
  end

  defp no_link_note(_ticket), do: "No link is recorded on this ticket."

  # Where a ticket's comments come from is not the same for both kinds: a service ticket's comments are
  # rows in the service's store, not a `## Discussion` section in a file.
  defp comments_note(%{tracker: :service}) do
    "The comments the ticket service holds for this ticket, oldest first, each with its author and its id."
  end

  defp comments_note(_ticket) do
    "The `## Discussion` section: the issue comments the janitor mirrored, each with its author and its stable id."
  end

  # An empty body means two different things, and only the tracker can say which. A file ticket keeps
  # the panel it has always had -- the file is the contract -- while a service ticket that holds no
  # description is told so in words rather than as an empty panel a reader would misread.
  defp blank_description?(%{tracker: :service, description: description}), do: description in [nil, ""]
  defp blank_description?(_ticket), do: false

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
