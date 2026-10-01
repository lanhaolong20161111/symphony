defmodule SymphonyElixir.AutoLand do
  @moduledoc """
  The land button's judgement, asked on a timer, for the tickets an operator marked safe to land
  unattended.

  A ticket an agent has finished sits in the workflow's review state with its pull request open until
  somebody presses the button on the ticket page. This is the same decision taken without the press,
  and it is deliberately narrow in four ways:

    * **the operator opts in per ticket.** Only a ticket carrying the configured label
      (`auto_land.label`, `auto-land` by default) is ever considered;
    * **the judgement is not re-implemented.** `SymphonyElixir.Land.land/2` is called -- the very
      function the page calls -- so the verdict, the four refusals, the branch check and the merge
      flags are the ones that already exist. Nothing here reads `gh` itself;
    * **a refusal changes nothing.** A conflict, unfinished or failed checks, outstanding feedback and
      a moved head all come back as `{:refused, code, messages}`; the ticket is left exactly as it was
      and the reason is said **once**, not on every pass;
    * **off unless the deployment says so.** `auto_land.enabled` defaults to false, and a disabled
      sweep is not a process at all: `init/1` answers `:ignore`, so there is no timer, no tracker read
      and no `gh`.

  ## What is read, and through which seam

  The pass reads the **deployment's own tracker**, through the console's presenter
  (`SymphonyElixirWeb.TicketPresenter`), which resolves `Config.settings!().tracker` and reads it with
  `SymphonyElixirWeb.TicketReader`. Neither the file tracker nor the ticket service is named here: one
  read serves both, and the sweep cannot disagree with the ticket page about what a ticket says,
  because it is the same read the page makes. The ticket-service transport can be injected with
  `:client`, exactly as the reader's own tests do it.

  Two seams exist for tests and for a caller that has already decided: `:tickets` replaces the read
  with a function of the pass options (`fn opts -> {:ok, [ticket]} | {:error, reason} end`), and
  `:land` replaces `Land.land/2`. Both are absent in production.

  ## What makes a ticket eligible

  Four conditions, each one a refusal rather than a guess:

    1. its state is the workflow's terminal-adjacent one -- `in-review`, the word the janitor's own
       publish sweep looks for;
    2. it carries the configured label;
    3. it records a pull request (the `links:` entry the janitor wrote);
    4. it records the branch of that pull request.

  Three and four are the land button's own condition, mirrored rather than re-invented: a ticket that
  records no pull request, or a pull request but no branch, is one whose pull request cannot be named,
  and nothing here searches for one. That is also why a ticket-service ticket is never landed by this
  sweep today: the service keeps the pull request as an attachment, and the reader this shares with
  the page does not read attachments, so such a ticket carries no pull request as far as this code can
  see and is left alone -- honestly, and in the log.

  ## How a duplicate merge is prevented

  A person may be pressing the same button while a pass runs, so the question is worth answering
  rather than assuming.

    * A pass is **serial and single-process**. The whole pass runs inside the served process, one
      ticket at a time, and the next tick is scheduled only after the pass returns -- so two passes
      cannot overlap and at most one `Land.land/2` is ever in flight. `max_per_pass` bounds how many
      tickets one pass lands at all.
    * The merge names a **pull request**, and a pull request that has already been merged is no
      longer open, so the second attempt cannot merge it again: GitHub refuses it and `Land` answers
      `{:error, {:merge_failed, reason}}`, which records nothing. The worst a race can therefore
      produce is one wasted attempt and one log line, never a second merge.
    * Across passes the ticket is gone from the candidate set as soon as either side records the
      merge, because its state is the workflow's terminal one by then.

  ## Recording

  A merge is recorded the way the page records it, through the presenter's writer for this deployment's
  tracker and never by writing ticket bytes here: the state first (the state is what the scheduler reads,
  so it is the half that has to land), then one comment naming the verdict and the result. For a file
  tracker that writer is the host's own (`SymphonyElixir.Janitor`); for a ticket-service tracker it is
  the tracker boundary, which asks the service to write the row -- so a sweep over a service-backed
  deployment records a merge through the same seam the ticket page's button does. A refusal and a
  failure write nothing at all.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Land
  alias SymphonyElixirWeb.TicketPresenter

  # The state an agent leaves a finished ticket in. It is the word the janitor's own publish sweep
  # looks for (`lib/symphony_elixir/janitor.ex`, `state: in-review`), and the file deployments declare
  # it in neither `active_states` nor `terminal_states` on purpose: it is the terminal-adjacent state
  # in which a run has stopped and a person is expected. A constant rather than a setting, because a
  # deployment that renamed it would have to rename it in the janitor too.
  @review_state "in-review"

  # What a landing made without a person is signed with. Deliberately not `operator`: the ticket's own
  # history is the only place that can say who merged, and a sweep and a press must be told apart
  # there.
  @author "auto-land"

  @first_delay_ms 5_000

  @typedoc """
  What one pass read and did.

  `reported` is the bookkeeping the next pass needs: it maps a ticket's identifier (or `:read` for a
  read that failed as a whole) to the reason already said about it, so a ticket refused or skipped for
  the same reason on every pass is reported once rather than on every pass.
  """
  @type report :: %{
          read: :ok | :disabled | {:error, term()},
          tickets: non_neg_integer(),
          candidates: non_neg_integer(),
          merged: non_neg_integer(),
          reported: %{optional(String.t() | :read) => term()}
        }

  # ---- one pass

  @doc """
  Runs one pass and reports what it did.

  Options:

    * `:settings` -- the `auto_land` block to run with; the workflow's own when absent;
    * `:reported` -- the previous pass's bookkeeping, so a repeated reason is said once;
    * `:tickets` -- replaces the read (see the module doc);
    * `:client` -- the ticket service's transport, passed to the reader;
    * `:land` -- replaces `SymphonyElixir.Land.land/2`.

  A disabled sweep answers without reading anything: no tracker, no `gh`, no log line. That is the
  one property a caller can rely on without knowing anything else about this module.
  """
  @spec run_once(keyword()) :: report()
  def run_once(opts \\ []) do
    settings = settings(opts)

    if settings.enabled do
      pass(opts, settings)
    else
      report(:disabled, 0, 0, 0, Keyword.get(opts, :reported, %{}))
    end
  end

  defp settings(opts), do: Keyword.get(opts, :settings) || Config.settings!().auto_land

  defp pass(opts, settings) do
    case read(opts) do
      {:ok, tickets} -> sweep(tickets, opts, settings)
      {:error, reason} -> unreadable(reason, opts)
    end
  end

  # A read that failed is not a ticket that was skipped: nothing was judged at all. Said once while
  # the same reason repeats, rather than once per pass.
  defp unreadable(reason, opts) do
    message =
      "auto-land: the tracker could not be read: #{TicketPresenter.describe(reason)}; " <>
        "nothing was judged and nothing was landed"

    report({:error, reason}, 0, 0, 0, note(opts, %{}, :read, reason, message, :warning))
  end

  defp sweep(tickets, opts, settings) do
    review = Enum.filter(tickets, &review_ticket?/1)
    {landable, reported} = plan(review, opts, settings)
    {merged, reported} = land_all(landable, opts, settings, reported)

    report(:ok, length(tickets), length(landable), merged, reported)
  end

  # One decision per ticket that is in the review state, and one log line per ticket per distinct
  # reason: skipping is the common answer, so it is the one that must not fill the log.
  defp plan(review, opts, settings) do
    {landable, reported} =
      Enum.reduce(review, {[], %{}}, fn ticket, {landable, reported} ->
        case skip_reason(ticket, settings) do
          nil ->
            {[ticket | landable], reported}

          reason ->
            message = skip_message(ticket, reason, settings)
            {landable, note(opts, reported, ticket.identifier, reason, message)}
        end
      end)

    {Enum.reverse(landable), reported}
  end

  defp review_ticket?(ticket), do: state_word(ticket) == @review_state

  defp state_word(ticket) do
    case Map.get(ticket, :state) do
      state when is_binary(state) -> state |> String.trim() |> String.downcase()
      _other -> nil
    end
  end

  defp skip_reason(ticket, settings) do
    cond do
      not labelled?(ticket, settings.label) -> :no_label
      not present?(ticket, :pr_url) -> :no_pull_request
      not present?(ticket, :branch_name) -> :no_branch
      true -> nil
    end
  end

  # Labels are compared the way the tracker contract compares them (`Tracker.Issue.routable?/2`): both
  # sides trimmed and downcased, because neither the store nor the file parse normalizes them.
  defp labelled?(ticket, label) do
    required = normalize_label(label)
    required != "" and Enum.any?(labels(ticket), &(normalize_label(&1) == required))
  end

  defp labels(ticket) do
    case Map.get(ticket, :labels) do
      labels when is_list(labels) -> labels
      _other -> []
    end
  end

  defp normalize_label(label) when is_binary(label), do: label |> String.trim() |> String.downcase()
  defp normalize_label(_label), do: ""

  defp present?(ticket, key) do
    case Map.get(ticket, key) do
      value when is_binary(value) -> String.trim(value) != ""
      _other -> false
    end
  end

  # Serialised by construction: one ticket at a time, in this process, and never more than
  # `max_per_pass` of them in one pass.
  defp land_all(landable, opts, settings, reported) do
    landable
    |> Enum.take(settings.max_per_pass)
    |> Enum.reduce({0, reported}, fn ticket, {merged, reported} ->
      {counted, reported} = land_one(ticket, opts, settings, reported)
      {merged + counted, reported}
    end)
  end

  defp land_one(ticket, opts, settings, reported) do
    case attempt(ticket, opts, settings) do
      {:ok, merged} ->
        record(ticket, merged, opts, reported)

      {:refused, code, messages} ->
        {0, note(opts, reported, ticket.identifier, {:refused, code}, refused_message(ticket, code, messages))}

      {:error, reason} ->
        {0, note(opts, reported, ticket.identifier, {:error, reason}, failed_message(ticket, reason))}

      other ->
        {0, note(opts, reported, ticket.identifier, {:failed, other}, failed_message(ticket, other))}
    end
  end

  defp record(ticket, merged, opts, reported) do
    case record_landing(ticket, merged, opts) do
      :ok ->
        {1, note(opts, reported, ticket.identifier, :merged, merged_message(ticket, merged))}

      {:error, reason} ->
        # The merge happened; the ticket does not say so yet. Counted as merged, because it was, and
        # said once -- the next pass would otherwise try to land a pull request that is already gone.
        {1, note(opts, reported, ticket.identifier, {:unrecorded, reason}, unrecorded_message(ticket, reason))}
    end
  end

  # The page's own write path in the page's own order, through the presenter's writer for this
  # deployment's tracker: the state first, because it is what the scheduler reads, then the one comment
  # that says what happened. Nothing here assembles ticket bytes, and nothing here names a tracker kind:
  # a file queue reaches the host's own writer, a service row reaches the tracker boundary.
  #
  # `:ref` is the ticket's own identifier, which is what both writers key on -- the file queue looks up
  # `<ref>.md`, and the service resolves it as the ticket's identifier rather than its numeric row id.
  defp record_landing(ticket, merged, opts) do
    writer_opts = [ref: ticket.identifier] ++ Keyword.take(opts, [:client])

    with {:ok, terminal} <- TicketPresenter.terminal_state(),
         {:ok, writer} <- TicketPresenter.writer(writer_opts),
         {:ok, _state} <- write(fn -> writer.(:state, terminal, []) end),
         {:ok, _comment} <-
           write(fn ->
             writer.(:comment, landing_note(merged, terminal), author: @author)
           end) do
      :ok
    end
  end

  # The same shape as the page's `host_write/1`, for the same reason: the last step of a write is a
  # filesystem call, and on Windows a ticket file another writer holds open raises `File.Error`. A
  # raise must leave the pass running rather than take the sweep down with it.
  defp write(write) do
    write.()
  rescue
    error -> {:error, {:write_raised, Exception.message(error)}}
  end

  # The deadline is a backstop, not the plan: `Land`'s own commands each carry a killable timeout and
  # rate-limit retries, and the worst legitimate attempt is a few minutes. The operation runs in a
  # task so that a `gh` which never answers cannot hold the pass (and therefore the server) forever.
  #
  # An attempt that runs out of time is fail-closed: it writes nothing, because whether its merge
  # happened is not knowable from this side, and the ticket's state is the one thing that must not be
  # guessed at.
  #
  # The operation is wrapped inside the task rather than at the caller because the task is linked: an
  # exception that escaped it would end the sweep, which is exactly what "a land operation that raises
  # must not stop the pass" forbids.
  defp attempt(ticket, opts, settings) do
    operation = Keyword.get(opts, :land, &Land.land/2)
    task = Task.async(fn -> guarded(operation, ticket) end)

    case Task.yield(task, settings.timeout_ms) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:land_exited, reason}}
      nil -> expired(task)
    end
  end

  defp expired(task) do
    Task.shutdown(task, :brutal_kill)
    {:error, :deadline_exceeded}
  end

  defp guarded(operation, ticket) do
    operation.(ticket.pr_url, ticket.branch_name)
  rescue
    error -> {:error, {:land_raised, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:land_threw, kind, reason}}
  end

  # ---- what the log says, once per ticket per reason

  # The one place a line is written, and the reason a line is written at most once: this pass's reason
  # for a ticket is compared with the reason the previous pass already said about it. The returned map
  # is what the next pass compares against.
  defp note(opts, reported, key, reason, message, level \\ :info) do
    if Map.get(Keyword.get(opts, :reported, %{}), key) == reason do
      reported
    else
      Logger.log(level, message)
      Map.put(reported, key, reason)
    end
  end

  defp skip_message(ticket, :no_label, settings) do
    "auto-land: #{ticket.identifier} is #{@review_state} but carries no #{settings.label} label; " <>
      "leaving it alone"
  end

  defp skip_message(ticket, :no_pull_request, _settings) do
    "auto-land: #{ticket.identifier} records no pull request, so there is nothing to land; " <>
      "nothing was searched for and nothing was merged"
  end

  defp skip_message(ticket, :no_branch, _settings) do
    "auto-land: #{ticket.identifier} records a pull request but no branch, so the pull request it " <>
      "names cannot be confirmed as the one opened for it; nothing was merged"
  end

  defp refused_message(ticket, code, messages) do
    "auto-land: #{ticket.identifier} was not landed: the land verdict is #{verdict_name(code)} " <>
      "(exit #{code}): #{Enum.join(messages, " ")}; nothing was merged and nothing was written on " <>
      "the ticket"
  end

  defp failed_message(ticket, reason) do
    "auto-land: #{ticket.identifier} was not landed: #{reason_text(reason)}; nothing was merged and " <>
      "nothing was written on the ticket"
  end

  defp merged_message(ticket, merged) do
    "auto-land: #{ticket.identifier} landed pull request #{merged.number} (#{merged.url}) and was " <>
      "moved to the workflow's terminal state"
  end

  defp unrecorded_message(ticket, reason) do
    "auto-land: pull request was merged for #{ticket.identifier}, but the ticket does not say so " <>
      "yet: #{TicketPresenter.describe(reason)}"
  end

  defp reason_text({:merge_failed, reason}), do: "gh refused the merge: " <> inspect(reason)

  defp reason_text({:branch_mismatch, recorded, actual}) do
    "the pull request's head branch is #{actual}, not the #{recorded} the ticket records"
  end

  defp reason_text(:deadline_exceeded), do: "the attempt did not finish inside its deadline"
  defp reason_text({:land_raised, message}), do: "the land operation raised: #{message}"
  defp reason_text(reason), do: inspect(reason)

  # The skill's own names for its codes, so a reader who knows the skill recognises the answer.
  defp verdict_name(2), do: "feedback"
  defp verdict_name(3), do: "checks"
  defp verdict_name(4), do: "head moved"
  defp verdict_name(5), do: "conflict"

  defp landing_note(merged, terminal) do
    "#{@author} landed pull request #{merged.number} (#{merged.url}). " <>
      "Land verdict: ok (exit 0). Result: squash-merged with the branch deleted. " <>
      "This ticket was moved to #{terminal}."
  end

  defp report(read, tickets, candidates, merged, reported) do
    %{read: read, tickets: tickets, candidates: candidates, merged: merged, reported: reported}
  end

  # ---- the read

  defp read(opts) do
    reader = Keyword.get(opts, :tickets, &default_tickets/1)
    reader.(opts)
  rescue
    error -> {:error, {:ticket_read_raised, Exception.message(error)}}
  end

  # The deployment's own tracker, read through the console's presenter -- the same read the ticket
  # page makes, so the button and the sweep cannot disagree about what a ticket records.
  defp default_tickets(opts), do: TicketPresenter.list(client: Keyword.get(opts, :client))

  # ---- the loop

  @doc """
  Starts the sweep.

  Options are the pass's own, plus `:enabled` (defaulting to the configured switch),
  `:interval_ms` (defaulting to the configured interval) and `:first_delay_ms` (5 seconds, so the
  process does not sweep while the application is still coming up).

  Answers `:ignore` when the workflow has not switched the sweep on, so a disabled deployment has no
  process, no timer and nothing to touch.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    settings = settings(opts)

    if Keyword.get(opts, :enabled, settings.enabled) do
      start(opts, settings)
    else
      :ignore
    end
  end

  defp start(opts, settings) do
    state = %{
      # Startup-only, exactly as the janitor's own settings are: the interval is the timer that was
      # armed here, and the label and bounds are captured with it. Changing them is a restart, which
      # is a decision for whoever runs the deployment.
      settings: settings,
      options: Keyword.take(opts, [:tickets, :client, :land]),
      interval_ms: Keyword.get(opts, :interval_ms, settings.interval_ms),
      first_delay_ms: Keyword.get(opts, :first_delay_ms, @first_delay_ms),
      reported: %{},
      timer: nil
    }

    Logger.info("auto-land: supervised, every #{state.interval_ms}ms, label=#{settings.label}")

    {:ok, schedule(state, state.first_delay_ms)}
  end

  @impl true
  def handle_info(:run, state) do
    {:noreply, schedule(pass_state(state), state.interval_ms)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{timer: timer}) do
    if is_reference(timer), do: Process.cancel_timer(timer)
    :ok
  end

  # The pass runs in this process, and the next tick is armed only once it has returned -- so two
  # passes cannot overlap, and neither can two land operations. A pass that crashes must not end the
  # loop: the reason is logged and the next tick is armed as usual.
  defp pass_state(state) do
    opts = state.options |> Keyword.put(:settings, state.settings) |> Keyword.put(:reported, state.reported)
    report = run_once(opts)
    %{state | reported: report.reported, timer: nil}
  rescue
    error ->
      Logger.error("auto-land pass crashed: #{Exception.message(error)}")
      %{state | timer: nil}
  catch
    kind, reason ->
      Logger.error("auto-land pass threw #{inspect(kind)}: #{inspect(reason)}")
      %{state | timer: nil}
  end

  defp schedule(state, delay_ms), do: %{state | timer: Process.send_after(self(), :run, delay_ms)}
end
