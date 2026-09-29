defmodule SymphonyElixir.Land do
  @moduledoc """
  The pure half of the `land` skill: given what GitHub answered about a pull
  request, decide whether it is safe to land, and if not, what stands in the way.

  Everything here is arithmetic over maps. The watcher that drives it is a
  long-running loop -- it polls `gh`, sleeps, watches a clock and kills runs --
  and every rule that loop enforces on the way is a pure question: which check
  runs still count, which comments are unanswered, which review blocks. Those
  questions live here so they can be asked without a repository, a token, a
  clock, or a process; a rule that can only be tested by waiting is a rule that
  stops being tested.

  ## The exit codes are the contract

  `verdict/1` is the one place that turns the facts into the skill's numbers:
  `5` conflict, `4` head moved, `2` feedback, `3` checks failed or never
  appeared, `:ok` otherwise. The skill's instructions, whoever reads the
  watcher's exit status, and the transcript all read those numbers, so a second
  copy of the mapping is how the watcher starts reporting the wrong thing with
  confidence.
  """

  @codex_bot_logins [
    "chatgpt-codex-connector[bot]",
    "github-actions[bot]",
    "codex-gc-app[bot]",
    "app/codex-gc-app"
  ]

  @passing_conclusions ["success", "skipped", "neutral"]
  @check_time_keys ["completed_at", "started_at", "run_started_at", "created_at"]
  @review_time_keys ["submitted_at", "created_at"]

  @doc """
  Summarizes a pull request's check runs.

  GitHub keeps every run of a check, so a re-run leaves two entries under one
  name; only the newest of them describes the commit that will be merged, which
  is why entries are deduped by name and the newest timestamp wins. A check that
  is not `completed` is pending rather than passing: "we have not heard yet" and
  "it passed" must not be the same answer, or a landing starts before CI does.
  An empty list is not a pass either -- it means the report is missing, and the
  caller is told so in `failures`.
  """
  @spec checks([map()]) :: %{pending: boolean(), failed: boolean(), failures: [String.t()]}
  def checks(check_runs) when is_list(check_runs) do
    case check_runs do
      [] -> %{pending: false, failed: false, failures: ["no checks reported"]}
      runs -> runs |> dedupe_check_runs() |> summarize_checks()
    end
  end

  @doc """
  True when the author is one of the Codex bots the skill talks to.

  The logins are matched exactly rather than by a `[bot]` suffix: the skill needs
  to tell *its own* agent apart from every other automation on the repository.
  """
  @spec codex_bot?(map()) :: boolean()
  def codex_bot?(user) when is_map(user), do: login(user) in @codex_bot_logins

  @doc """
  True for any bot account, Codex's included.

  GitHub marks the account with `type: "Bot"` and/or a `[bot]` login suffix; both
  spellings appear in the wild, so both are treated as "not a person" -- a bot's
  comment is never the human feedback the watcher is waiting for.
  """
  @spec bot?(map()) :: boolean()
  def bot?(user) when is_map(user) do
    codex_bot?(user) or Map.get(user, "type") == "Bot" or String.ends_with?(login(user), "[bot]")
  end

  @doc """
  True when a body is one of this agent's replies (`[codex] ...`).

  The marker is what tells the watcher which comments the agent already
  answered; guessing from the author instead would misread a Codex review posted
  through a different account.
  """
  @spec codex_reply?(String.t() | map()) :: boolean()
  def codex_reply?(value), do: value |> body_text() |> String.starts_with?("[codex]")

  @doc """
  True when a body is a Codex review (`## Codex Review`).

  A review the agent posts as an issue comment is still the agent's answer, so
  it must not be mistaken for a person asking for something.
  """
  @spec codex_review?(String.t() | map()) :: boolean()
  def codex_review?(value), do: value |> body_text() |> String.starts_with?("## Codex Review")

  @doc """
  The time of the latest `@codex review` request in a list of comments.

  A person asking again supersedes their earlier request: everything the agent
  said before the newest request answers an older question.
  """
  @spec latest_review_request([map()]) :: DateTime.t() | nil
  def latest_review_request(comments) when is_list(comments) do
    comments
    |> Enum.reject(&codex_bot?(author(&1)))
    |> Enum.filter(&String.contains?(body(&1), "@codex review"))
    |> times()
  end

  @doc """
  The latest `[codex]` reply in each review thread, keyed by the thread's root
  comment.

  A thread is identified by its root, because a reply and the comment it answers
  have different ids: without the root a reply cannot be compared with the
  conversation it belongs to, and the watcher would re-report answers it already
  gave.
  """
  @spec latest_codex_reply_by_thread([map()]) :: %{optional(term()) => DateTime.t()}
  def latest_codex_reply_by_thread(comments) when is_list(comments) do
    comments
    |> Enum.filter(&codex_reply?(body(&1)))
    |> Enum.reduce(%{}, &put_thread_reply/2)
  end

  @doc """
  The issue comments a person wrote that still want an answer.

  Bots do not want answers, and a comment the agent already replied to at or
  after it was written has been answered -- reporting it again would make the
  watcher ask for the same thing forever.
  """
  @spec human_issue_comments([map()]) :: [map()]
  def human_issue_comments(comments) when is_list(comments) do
    latest_ack = latest_codex_issue_reply(comments)
    Enum.filter(comments, &human_issue_comment?(&1, latest_ack))
  end

  @doc """
  The Codex review bodies (posted as issue comments) that are still current.

  A review older than the agent's own latest `[codex]` reply has been superseded
  by that reply, so re-reading it would report the same finding twice.
  """
  @spec codex_review_comments([map()]) :: [map()]
  def codex_review_comments(comments) when is_list(comments) do
    latest_ack = latest_codex_issue_reply(comments)
    Enum.filter(comments, &codex_review_comment?(&1, latest_ack))
  end

  @doc """
  The review comments a person wrote in a thread the agent has not answered.

  The comparison is per thread, not global: an answer in one thread says nothing
  about a question in another, and a global latest-reply rule would silently
  swallow every other conversation.
  """
  @spec human_review_comments([map()]) :: [map()]
  def human_review_comments(comments) when is_list(comments) do
    latest_replies = latest_codex_reply_by_thread(comments)
    Enum.filter(comments, &human_review_comment?(&1, latest_replies))
  end

  @doc """
  Splits Codex-bot comments into the issue ones and the review ones that are new
  enough to matter, as `{issue, review}`.

  Only comments written after the latest `@codex review` request count as
  answers to *that* request; a threaded reply additionally has to be at least as
  new as the last reply in its own thread, so an old answer inside a live thread
  is not replayed as if it were fresh.

  The Python original also dropped an issue-level Codex reply that was itself the
  newest `[codex]` reply, which made the newest answer impossible to report; the
  request time and the thread are the only gates this port keeps.
  """
  @spec codex_comments(map()) :: {[map()], [map()]}
  def codex_comments(context) when is_map(context) do
    request_at = field(context, :request_at, nil)
    issue = context |> field(:issue, []) |> codex_after_request(request_at)
    review = context |> field(:review, []) |> codex_after_request(request_at)

    {issue, review}
  end

  @doc """
  The reviews that still stand in the way of landing.

  Only each author's latest review counts: a reviewer who asked for changes and
  then approved has changed their mind, and the earlier verdict is history. A
  Codex review blocks only when it asked for changes, and only when it was
  written after the newest `@codex review` request -- a stale Codex rejection of
  code that has since been rewritten must not block forever.
  """
  @spec blocking_reviews([map()], DateTime.t() | nil) :: [map()]
  def blocking_reviews(reviews, review_requested_at) when is_list(reviews) do
    reviews
    |> dedupe_reviews()
    |> Enum.filter(&blocking_review?(&1, review_requested_at))
  end

  @doc """
  True when the pull request cannot be merged as it stands.

  GitHub reports a conflict twice, once as `mergeable` and once as
  `mergeStateStatus`; either spelling means the branch has to be rebased before
  any of the other checks matter.
  """
  @spec conflicting?(map()) :: boolean()
  def conflicting?(pr) when is_map(pr) do
    Map.get(pr, "mergeable") == "CONFLICTING" or Map.get(pr, "mergeStateStatus") == "DIRTY"
  end

  @doc """
  Turns the watcher's facts into the skill's exit code.

  The order is the point: a conflict is not worth waiting through, a moved head
  invalidates everything observed before it, feedback is the agent's work to do,
  and a failed or missing check is the last thing to act on. The numbers `5`,
  `4`, `2`, `3` and `:ok` are the skill's own contract -- see the module doc.
  """
  @spec verdict(map()) :: 2 | 3 | 4 | 5 | :ok
  def verdict(input) when is_map(input) do
    cond do
      present?(field(input, :conflicting, false)) -> 5
      present?(field(input, :head_moved, false)) -> 4
      present?(field(input, :feedback, false)) -> 2
      checks_failed?(field(input, :checks, %{})) -> 3
      absent_too_long?(field(input, :checks_absent_seconds, 0)) -> 3
      true -> :ok
    end
  end

  ## Check runs

  defp dedupe_check_runs(check_runs) do
    {names, by_name} = Enum.reduce(check_runs, {[], %{}}, &put_latest_check/2)

    names
    |> Enum.reverse()
    |> Enum.map(&Map.fetch!(by_name, &1))
  end

  defp put_latest_check(check, {names, by_name}) do
    name = check_name(check)

    case Map.fetch(by_name, name) do
      :error -> {[name | names], Map.put(by_name, name, check)}
      {:ok, existing} -> {names, replace_if_newer(by_name, name, existing, check)}
    end
  end

  defp replace_if_newer(by_name, name, existing, check) do
    if keep_new?(check_timestamp(check), check_timestamp(existing)) do
      Map.put(by_name, name, check)
    else
      by_name
    end
  end

  defp summarize_checks(check_runs) do
    Enum.reduce(check_runs, %{pending: false, failed: false, failures: []}, &accumulate_check/2)
  end

  defp accumulate_check(check, acc) do
    case Map.get(check, "status") do
      "completed" -> accumulate_conclusion(check, acc)
      _other -> %{acc | pending: true}
    end
  end

  defp accumulate_conclusion(check, acc) do
    conclusion = Map.get(check, "conclusion")

    if conclusion in @passing_conclusions do
      acc
    else
      %{acc | failed: true, failures: acc.failures ++ ["#{check_name(check)}: #{conclusion}"]}
    end
  end

  defp check_name(check) do
    case Map.get(check, "name") do
      name when is_binary(name) -> name
      _other -> "unknown"
    end
  end

  defp check_timestamp(check), do: check |> first_value(@check_time_keys) |> parse_time()

  ## Comments

  defp human_issue_comment?(comment, latest_ack) do
    not bot?(author(comment)) and
      not codex_reply?(comment) and
      not codex_review?(comment) and
      not String.contains?(body(comment), "@codex review") and
      not stale?(comment_time(comment), latest_ack)
  end

  defp codex_review_comment?(comment, latest_ack) do
    codex_review?(comment) and not stale?(comment_time(comment), latest_ack)
  end

  defp human_review_comment?(comment, latest_replies) do
    not bot?(author(comment)) and
      not codex_reply?(comment) and
      not stale?(comment_time(comment), Map.get(latest_replies, thread_root_id(comment)))
  end

  defp codex_after_request(comments, request_at) do
    comments = List.wrap(comments)
    latest_replies = latest_codex_reply_by_thread(comments)

    Enum.filter(comments, &codex_comment_for(&1, request_at, latest_replies))
  end

  defp codex_comment_for(comment, request_at, latest_replies) do
    codex_bot?(author(comment)) and codex_comment_kept?(comment, request_at, latest_replies)
  end

  defp codex_comment_kept?(comment, request_at, latest_replies) do
    time = comment_time(comment)

    cond do
      is_nil(time) -> false
      stale?(time, request_at) -> false
      threaded?(comment) -> not superseded?(time, Map.get(latest_replies, thread_root_id(comment)))
      true -> true
    end
  end

  defp threaded?(comment) do
    present?(Map.get(comment, "in_reply_to_id")) or
      present?(Map.get(comment, "pull_request_review_id"))
  end

  defp put_thread_reply(comment, acc) do
    root = thread_root_id(comment)
    time = comment_time(comment)

    if is_nil(root) or is_nil(time) do
      acc
    else
      Map.update(acc, root, time, &later(time, &1))
    end
  end

  defp latest_codex_issue_reply(comments) do
    comments
    |> Enum.filter(&codex_reply?(body(&1)))
    |> times()
  end

  defp thread_root_id(comment), do: first_present(comment, ["in_reply_to_id", "id"])

  defp comment_time(comment), do: comment |> first_value(["updated_at", "created_at"]) |> parse_time()

  ## Reviews

  defp dedupe_reviews(reviews) do
    {logins, by_login} = Enum.reduce(reviews, {[], %{}}, &put_latest_review/2)

    logins
    |> Enum.reverse()
    |> Enum.map(&Map.fetch!(by_login, &1))
  end

  defp put_latest_review(review, {logins, by_login}) do
    login = nil_if_blank(review |> author() |> login())

    cond do
      is_nil(login) -> {logins, by_login}
      not Map.has_key?(by_login, login) -> {[login | logins], Map.put(by_login, login, review)}
      true -> {logins, replace_review_if_newer(by_login, login, review)}
    end
  end

  defp replace_review_if_newer(by_login, login, review) do
    existing = Map.fetch!(by_login, login)

    if keep_new?(review_timestamp(review), review_timestamp(existing)) do
      Map.put(by_login, login, review)
    else
      by_login
    end
  end

  defp blocking_review?(review, review_requested_at) do
    time = review_timestamp(review)
    codex? = review |> author() |> codex_bot?()

    cond do
      is_nil(time) -> false
      codex? -> not stale?(time, review_requested_at) and Map.get(review, "state") == "CHANGES_REQUESTED"
      true -> human_review_blocking?(review)
    end
  end

  defp human_review_blocking?(review) do
    state = Map.get(review, "state")
    body = body(review)

    cond do
      String.starts_with?(body, "[codex]") -> false
      state in ["APPROVED", "DISMISSED"] -> false
      body != "" or state == "CHANGES_REQUESTED" -> true
      state == "COMMENTED" -> false
      is_binary(state) -> true
      true -> false
    end
  end

  defp review_timestamp(review), do: review |> first_value(@review_time_keys) |> parse_time()

  ## Verdict

  defp checks_failed?(checks) do
    is_map(checks) and (present?(Map.get(checks, :failed)) or present?(Map.get(checks, "failed")))
  end

  defp absent_too_long?(seconds), do: is_integer(seconds) and seconds >= 120

  ## Shared helpers

  defp later(candidate, current) do
    cond do
      is_nil(current) -> candidate
      DateTime.compare(candidate, current) == :gt -> candidate
      true -> current
    end
  end

  # True when `time` is at or before `reference`: GitHub's answer is already in,
  # so the thing being compared has been superseded.
  defp stale?(time, reference) do
    not is_nil(reference) and not is_nil(time) and DateTime.compare(time, reference) != :gt
  end

  # True when someone answered strictly later than `time` -- the same comparison
  # as `stale?/2` but ties keep the newer comment, because a reply is its own
  # thread's latest reply.
  defp superseded?(time, latest_reply) do
    not is_nil(latest_reply) and not is_nil(time) and DateTime.compare(latest_reply, time) == :gt
  end

  defp keep_new?(new, existing) do
    cond do
      is_nil(new) -> false
      is_nil(existing) -> true
      true -> DateTime.compare(new, existing) == :gt
    end
  end

  defp times(comments), do: comments |> Enum.map(&comment_time/1) |> Enum.reduce(nil, &later/2)

  defp body_text(value) do
    cond do
      is_binary(value) -> String.trim(value)
      is_map(value) -> body(value)
      true -> ""
    end
  end

  defp body(map), do: map |> Map.get("body") |> to_string() |> String.trim()

  defp author(map) do
    case Map.get(map, "user") do
      user when is_map(user) -> user
      _other -> %{}
    end
  end

  defp login(user) do
    case Map.get(user, "login") do
      login when is_binary(login) -> login
      _other -> ""
    end
  end

  defp nil_if_blank(value) do
    if value == "", do: nil, else: value
  end

  defp first_value(map, keys) do
    keys
    |> Enum.map(&Map.get(map, &1))
    |> Enum.find(&(is_binary(&1) and &1 != ""))
  end

  defp first_present(map, keys) do
    keys
    |> Enum.map(&Map.get(map, &1))
    |> Enum.find(&present?/1)
  end

  defp present?(value), do: not is_nil(value) and value != false and value != ""

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> naive_to_utc(value)
    end
  end

  defp parse_time(_value), do: nil

  defp naive_to_utc(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
      {:error, _reason} -> nil
    end
  end

  # Reads a key that may have been written as an atom or as the string GitHub
  # uses, so the watcher can pass either shape without a translation step.
  defp field(map, key, default) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end
end
