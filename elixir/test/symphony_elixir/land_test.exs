defmodule SymphonyElixir.LandTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Land

  @codex "chatgpt-codex-connector[bot]"

  describe "checks/1" do
    test "a check that is still running is pending, and the same check passing is not" do
      running = [%{"name" => "ci", "status" => "in_progress"}]
      assert %{pending: true, failed: false, failures: []} = Land.checks(running)

      passed = [%{"name" => "ci", "status" => "completed", "conclusion" => "success"}]
      assert %{pending: false, failed: false, failures: []} = Land.checks(passed)
    end

    test "a failed check is named together with its conclusion" do
      failed = [%{"name" => "build", "status" => "completed", "conclusion" => "failure"}]

      assert %{pending: false, failed: true, failures: ["build: failure"]} = Land.checks(failed)
    end

    test "skipped and neutral conclusions are not failures" do
      runs = [
        %{"name" => "docs", "status" => "completed", "conclusion" => "skipped"},
        %{"name" => "lint", "status" => "completed", "conclusion" => "neutral"}
      ]

      assert Land.checks(runs) == %{pending: false, failed: false, failures: []}
    end

    test "an empty list reports that no checks were reported" do
      assert Land.checks([]) == %{pending: false, failed: false, failures: ["no checks reported"]}
    end

    test "duplicate check names keep the newest entry, in either order" do
      older = check("ci", "failure", "2024-05-01T00:00:00Z")
      newer = check("ci", "success", "2024-05-02T00:00:00Z")

      assert Land.checks([older, newer]) == %{pending: false, failed: false, failures: []}
      assert Land.checks([newer, older]) == %{pending: false, failed: false, failures: []}
    end

    test "an entry with no timestamp loses to one that has one" do
      stamped = check("ci", "success", "2024-05-01T00:00:00Z")
      unstamped = %{"name" => "ci", "status" => "queued"}

      assert Land.checks([unstamped, stamped]).pending == false
      assert Land.checks([stamped, unstamped]).pending == false
    end

    test "when neither entry has a timestamp the first one stays" do
      first = %{"name" => "ci", "status" => "completed", "conclusion" => "failure"}
      second = %{"name" => "ci", "status" => "completed", "conclusion" => "success"}

      assert Land.checks([first, second]).failures == ["ci: failure"]
    end
  end

  describe "author predicates and time filters" do
    test "codex_bot?/1 knows the Codex logins, bot?/1 knows GitHub's two bot markers" do
      assert Land.codex_bot?(%{"login" => @codex})
      assert Land.codex_bot?(%{"login" => "github-actions[bot]"})
      assert Land.codex_bot?(%{"login" => "app/codex-gc-app"})
      refute Land.codex_bot?(%{"login" => "dependabot[bot]"})

      assert Land.bot?(%{"login" => "dependabot", "type" => "Bot"})
      assert Land.bot?(%{"login" => "some-app[bot]"})
      assert Land.bot?(%{"login" => "github-actions[bot]"})
      refute Land.bot?(%{"login" => "octocat", "type" => "User"})
    end

    test "the latest @codex review request wins, and a Codex bot's request does not count" do
      first = comment(1, "@codex review", "2024-05-01T00:00:00Z", "octocat")
      second = comment(2, "please @codex review again", "2024-05-02T00:00:00Z", "hubot")
      from_bot = comment(3, "@codex review", "2024-05-03T00:00:00Z", @codex)

      assert Land.latest_review_request([first, second, from_bot]) == ~U[2024-05-02 00:00:00Z]
      assert Land.latest_review_request([comment(4, "plain note", "2024-05-01T00:00:00Z", "octocat")]) == nil
    end

    test "the latest [codex] reply is tracked per thread root, or per comment id when top level" do
      threaded = thread_reply(2, "[codex] answered", "2024-05-02T00:00:00Z", 7)
      top_level = comment(5, "[codex] note", "2024-05-02T00:00:05Z", @codex)

      assert Land.latest_codex_reply_by_thread([threaded]) == %{7 => ~U[2024-05-02 00:00:00Z]}
      assert Land.latest_codex_reply_by_thread([top_level]) == %{5 => ~U[2024-05-02 00:00:05Z]}
    end

    test "a human issue comment after the latest [codex] reply is feedback" do
      ack = comment(2, "[codex] on it", "2024-05-02T00:00:00Z", @codex)
      human = comment(1, "please rename this", "2024-05-02T00:00:05Z", "octocat")

      assert Land.human_issue_comments([ack, human]) == [human]
    end

    test "a human issue comment older than the latest [codex] reply is not feedback" do
      ack = comment(2, "[codex] on it", "2024-05-02T00:00:10Z", @codex)
      human = comment(1, "please rename this", "2024-05-02T00:00:05Z", "octocat")

      assert Land.human_issue_comments([ack, human]) == []
    end

    test "a [codex] reply, a review body and a review request are not human feedback" do
      ack = comment(1, "[codex] fixed", "2024-05-02T00:00:00Z", @codex)
      assert Land.codex_reply?(ack)
      assert Land.human_issue_comments([ack]) == []

      review = comment(2, "## Codex Review", "2024-05-02T00:00:00Z", @codex)
      assert Land.codex_review?(review)
      assert Land.codex_review_comments([review]) == [review]
      assert Land.human_issue_comments([review]) == []

      request = comment(3, "run @codex review please", "2024-05-02T00:00:00Z", "octocat")
      assert Land.human_issue_comments([request]) == []
    end

    test "a human review reply counts only when it is newer than its thread's [codex] reply" do
      question = thread_reply_from(1, "why is this here?", "2024-05-02T00:00:00Z", 7, "octocat")
      ack = thread_reply(2, "[codex] because reasons", "2024-05-02T00:00:01Z", 7)
      follow_up = thread_reply_from(3, "still unclear", "2024-05-02T00:00:02Z", 7, "octocat")

      assert Land.human_review_comments([question, ack, follow_up]) == [follow_up]
    end
  end

  describe "codex_comments/1" do
    test "only Codex-bot comments written after the review request survive" do
      request = comment(1, "@codex review", "2024-05-02T00:00:00Z", "octocat")
      stale = comment(2, "[codex] yesterday", "2024-05-01T23:00:00Z", @codex)
      fresh = comment(3, "[codex] just now", "2024-05-02T00:00:01Z", @codex)
      human = comment(4, "unrelated", "2024-05-02T00:00:02Z", "octocat")
      request_at = Land.latest_review_request([request, stale, fresh, human])
      context = %{issue: [request, stale, fresh, human], review: [fresh], request_at: request_at}

      assert request_at == ~U[2024-05-02 00:00:00Z]
      assert Land.codex_comments(context) == {[fresh], [fresh]}
    end

    test "a threaded reply older than its thread's latest [codex] reply is dropped" do
      request = comment(1, "@codex review", "2024-05-02T00:00:00Z", "octocat")
      ack = thread_reply(2, "[codex] answered", "2024-05-02T00:00:05Z", 7)
      earlier = thread_reply(3, "[codex] older", "2024-05-02T00:00:01Z", 7)

      {issue, review} =
        Land.codex_comments(%{
          issue: [request, ack, earlier],
          review: [],
          request_at: ~U[2024-05-02 00:00:00Z]
        })

      assert issue == [ack]
      assert review == []
    end
  end

  describe "blocking_reviews/2" do
    test "a Codex-bot CHANGES_REQUESTED review blocks" do
      review = review("CHANGES_REQUESTED", @codex, "2024-05-02T00:00:00Z", "")

      assert Land.blocking_reviews([review], nil) == [review]
    end

    test "an APPROVED review does not block" do
      review = review("APPROVED", "octocat", "2024-05-02T00:00:00Z", "lgtm")

      assert Land.blocking_reviews([review], nil) == []
    end

    test "a DISMISSED review does not block" do
      review = review("DISMISSED", "octocat", "2024-05-02T00:00:00Z", "never mind")

      assert Land.blocking_reviews([review], nil) == []
    end

    test "a COMMENTED review blocks only when it carries a body" do
      with_body = review("COMMENTED", "octocat", "2024-05-02T00:00:00Z", "please rename this")
      empty = review("COMMENTED", "hubot", "2024-05-02T00:00:00Z", "")

      assert Land.blocking_reviews([with_body, empty], nil) == [with_body]
    end

    test "a Codex-bot review at or before the latest @codex review does not block" do
      requested = ~U[2024-05-02 00:00:00Z]
      stale = review("CHANGES_REQUESTED", @codex, "2024-05-02T00:00:00Z", "")
      fresh = review("CHANGES_REQUESTED", @codex, "2024-05-02T00:00:01Z", "")

      assert Land.blocking_reviews([stale], requested) == []
      assert Land.blocking_reviews([fresh], requested) == [fresh]
    end

    test "only each author's latest review counts" do
      earlier = review("CHANGES_REQUESTED", "octocat", "2024-05-01T00:00:00Z", "")
      later = review("APPROVED", "octocat", "2024-05-02T00:00:00Z", "")

      assert Land.blocking_reviews([earlier, later], nil) == []
      assert Land.blocking_reviews([later, earlier], nil) == []
    end

    test "a [codex] body from a non-bot author never blocks" do
      review = review("COMMENTED", "octocat", "2024-05-02T00:00:00Z", "[codex] note")

      assert Land.blocking_reviews([review], nil) == []
    end
  end

  describe "conflicting?/1 and verdict/1" do
    test "a conflicting pull request gives 5" do
      pr = %{"mergeable" => "CONFLICTING", "mergeStateStatus" => "DIRTY"}

      assert Land.conflicting?(pr)
      assert Land.conflicting?(%{"mergeStateStatus" => "DIRTY"})
      assert Land.conflicting?(%{"mergeable" => "CONFLICTING"})
      refute Land.conflicting?(%{"mergeable" => "MERGEABLE", "mergeStateStatus" => "CLEAN"})
      assert Land.verdict(verdict_input(conflicting: Land.conflicting?(pr))) == 5
    end

    test "a moved head gives 4" do
      assert Land.verdict(verdict_input(head_moved: true)) == 4
    end

    test "unanswered feedback gives 2" do
      comments = [comment(1, "please rename this", "2024-05-02T00:00:00Z", "octocat")]
      feedback = Land.human_issue_comments(comments) != []

      assert feedback
      assert Land.verdict(verdict_input(feedback: feedback)) == 2
    end

    test "no checks for 120 seconds gives 3, and 119 seconds is still fine" do
      assert Land.verdict(verdict_input(checks_absent_seconds: 119)) == :ok
      assert Land.verdict(verdict_input(checks_absent_seconds: 120)) == 3
    end

    test "failed checks give 3" do
      runs = [%{"name" => "build", "status" => "completed", "conclusion" => "failure"}]

      assert Land.verdict(verdict_input(checks: Land.checks(runs))) == 3
    end

    test "everything clear gives :ok" do
      passed = [%{"name" => "ci", "status" => "completed", "conclusion" => "success"}]

      assert Land.verdict(verdict_input(checks: Land.checks(passed))) == :ok
    end

    test "a conflict outranks a moved head, feedback and failed checks" do
      input = verdict_input(conflicting: true, head_moved: true, feedback: true, checks: %{failed: true})

      assert Land.verdict(input) == 5
    end

    test "a moved head outranks feedback and failed checks" do
      assert Land.verdict(verdict_input(head_moved: true, feedback: true, checks: %{failed: true})) == 4
    end

    test "feedback outranks failed checks" do
      assert Land.verdict(verdict_input(feedback: true, checks: %{failed: true})) == 2
    end

    test "the verdict reads string keys too, for a caller holding GitHub's JSON" do
      input = %{
        "conflicting" => false,
        "head_moved" => false,
        "feedback" => true,
        "checks" => %{"failed" => false},
        "checks_absent_seconds" => 0
      }

      assert Land.verdict(input) == 2
    end
  end

  defp check(name, conclusion, completed_at) do
    %{
      "name" => name,
      "status" => "completed",
      "conclusion" => conclusion,
      "completed_at" => completed_at
    }
  end

  defp comment(id, body, created_at, login) do
    %{
      "id" => id,
      "body" => body,
      "created_at" => created_at,
      "user" => %{"login" => login}
    }
  end

  defp thread_reply(id, body, created_at, root), do: thread_reply_from(id, body, created_at, root, @codex)

  defp thread_reply_from(id, body, created_at, root, login) do
    comment(id, body, created_at, login) |> Map.put("in_reply_to_id", root)
  end

  defp review(state, login, submitted_at, body) do
    %{
      "state" => state,
      "body" => body,
      "submitted_at" => submitted_at,
      "user" => %{"login" => login}
    }
  end

  defp verdict_input(overrides) do
    defaults = %{
      conflicting: false,
      head_moved: false,
      feedback: false,
      checks: %{pending: false, failed: false, failures: []},
      checks_absent_seconds: 0
    }

    Map.merge(defaults, Map.new(overrides))
  end

  # Nothing below reaches `gh`: `:run_gh` is the transport, so the retry rules and
  # the loop can be driven from a script. The script is one queue per endpoint
  # kind; when a queue runs out, a list endpoint answers `[]` (which is how a page
  # loop ends) and a one-element queue keeps repeating, which is what holds the
  # head sha still from poll to poll.
  describe "run_gh/2" do
    test "a rate-limited command is retried and the retry's answer is returned" do
      replies = [{:error, "HTTP 429: rate limit exceeded"}, {:ok, "payload"}]
      opts = [run_gh: sequence(replies), backoff_base_ms: 0]

      assert Land.run_gh(["pr", "view"], opts) == {:ok, "payload"}
    end

    test "any other failure is returned on the first attempt" do
      opts = [run_gh: sequence([{:error, "could not resolve to a Repository"}]), backoff_base_ms: 0]

      assert Land.run_gh(["pr", "view"], opts) == {:error, "could not resolve to a Repository"}
    end

    test "a command that stays rate-limited gives up after five attempts" do
      replies = List.duplicate({:error, "rate limit exceeded"}, 5)
      opts = [run_gh: sequence(replies), backoff_base_ms: 0]

      assert Land.run_gh(["pr", "view"], opts) == {:error, {:rate_limited, "rate limit exceeded"}}
    end
  end

  describe "watch/1" do
    test "a pending check that passes ends the watch with the pull request" do
      queues = %{
        pr: [pr_reply("sha1")],
        checks: [checks_reply([run("ci", "in_progress")]), checks_reply([run("ci", "completed", "success")])]
      }

      assert {:ok, %{"number" => 7, "headRefOid" => "sha1"}} = Land.watch(watch_opts(queues))
    end

    test "a failed check exits 3 and names the check and its conclusion" do
      queues = %{pr: [pr_reply("sha1")], checks: [checks_reply([run("build", "completed", "failure")])]}

      assert {:verdict, 3, ["Checks failed:", "- build: failure"]} = Land.watch(watch_opts(queues))
    end

    test "checks that never appear exit 3 once the 120s window has passed" do
      opts = watch_opts(%{pr: [pr_reply("sha1")]}, now: fake_clock(60_000))

      assert {:verdict, 3, ["No checks detected after 120s; check CI configuration"]} = Land.watch(opts)
    end

    test "a human comment exits 2" do
      issue = [comment(1, "please handle the nil case", "2024-05-01T00:00:00Z", "alice")]
      checks = checks_reply([run("ci", "completed", "success")])
      queues = %{pr: [pr_reply("sha1")], checks: [checks], issue: [{:ok, JSON.encode!(issue)}, {:ok, "[]"}]}

      assert {:verdict, 2, ["Review comments detected. Address before merge."]} = Land.watch(watch_opts(queues))
    end

    test "a conflicting pull request exits 5 without fetching anything else" do
      queues = %{pr: [pr_reply("sha1", "CONFLICTING")]}

      assert {:verdict, 5, [message]} = Land.watch(watch_opts(queues))

      assert message ==
               "PR has merge conflicts. Resolve/rebase against main and push before running land_watch again."
    end

    test "a head that moves while waiting exits 4" do
      queues = %{
        pr: [pr_reply("sha1"), pr_reply("sha1"), pr_reply("sha2")],
        checks: [checks_reply([run("ci", "in_progress")])]
      }

      assert {:verdict, 4, ["PR head updated; pull/amend/force-push to retrigger CI"]} = Land.watch(watch_opts(queues))
    end

    test "a watch that never settles gives up at the deadline" do
      queues = %{pr: [pr_reply("sha1")], checks: [checks_reply([run("ci", "in_progress")])]}
      opts = watch_opts(queues, now: fake_clock(60_000), deadline_ms: 300_000)

      assert Land.watch(opts) == {:error, :deadline_exceeded}
    end
  end

  defp watch_opts(queues, overrides \\ []) do
    Keyword.merge([run_gh: gh_stub(queues), interval_ms: 0, now: fake_clock(60_000)], overrides)
  end

  # A clock that jumps a minute per reading, so the absent-checks window and the
  # deadline are reached in a few polls instead of in real time.
  defp fake_clock(step_ms) do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    fn -> Agent.get_and_update(agent, fn now -> {now, now + step_ms} end) end
  end

  defp gh_stub(queues) do
    {:ok, agent} = Agent.start_link(fn -> %{} end)

    fn args -> Agent.get_and_update(agent, fn state -> next_reply(queues, state, gh_key(args)) end) end
  end

  defp next_reply(queues, state, key) do
    remaining = Map.get(state, key, Map.get(queues, key, []))

    case remaining do
      [only] -> {only, Map.put(state, key, [only])}
      [reply | rest] -> {reply, Map.put(state, key, rest)}
      [] -> {empty_reply(key), state}
    end
  end

  defp empty_reply(:pr), do: {:error, "no pull request reply scripted"}
  defp empty_reply(_list_endpoint), do: {:ok, "[]"}

  defp gh_key(["pr" | _rest]), do: :pr

  defp gh_key(["api", "--method", "GET", endpoint | _rest]) do
    cond do
      String.ends_with?(endpoint, "check-runs") -> :checks
      String.ends_with?(endpoint, "/reviews") -> :reviews
      String.contains?(endpoint, "/issues/") -> :issue
      true -> :review_comments
    end
  end

  defp sequence(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)

    fn _args -> Agent.get_and_update(agent, fn [reply | rest] -> {reply, rest} end) end
  end

  defp pr_reply(head_sha, mergeable \\ "MERGEABLE") do
    merge_state = if mergeable == "CONFLICTING", do: "DIRTY", else: "CLEAN"

    {:ok,
     JSON.encode!(%{
       "number" => 7,
       "url" => "https://github.com/me/repo/pull/7",
       "headRefOid" => head_sha,
       "mergeable" => mergeable,
       "mergeStateStatus" => merge_state
     })}
  end

  defp checks_reply(runs) do
    {:ok, JSON.encode!(%{"total_count" => length(runs), "check_runs" => runs})}
  end

  defp run(name, status, conclusion \\ nil) do
    %{
      "name" => name,
      "status" => status,
      "conclusion" => conclusion,
      "completed_at" => "2024-05-01T00:00:00Z"
    }
  end
end
