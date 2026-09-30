defmodule SymphonyElixir.Janitor.LabelMirrorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Janitor
  alias SymphonyElixir.Janitor.Labels

  # The mirror's label path. Two measured facts shape every test here:
  #
  #   * the label names used to be CJK, and on Windows Erlang encodes a spawned process's arguments
  #     through the ANSI code page -- so `gh` was asked for a label that was never the one in the
  #     ticket, and answered `could not add label: ... not found` every round;
  #   * `gh` refuses a whole `issue edit` (and a whole `issue create`) over one label the repository
  #     does not have, so a fresh repository failed every round too.
  #
  # Both are exercised through the injected runner (`:runner`), the same seam
  # `Projects.create_repo/2` and `Land.run_gh/2` offer: the argv is observed argument by argument,
  # and neither `gh` nor a socket is involved. The runner is handed the argv and answers what
  # `Shell.run/3` answers.
  describe "the label vocabulary" do
    test "every label name is ASCII, and the six states keep the meanings they had" do
      assert Labels.all() == [
               "symphony:ready",
               "symphony:in-progress",
               "symphony:in-review",
               "symphony:paused",
               "symphony:done",
               "symphony:cancelled"
             ]

      # The rule itself, not just today's names: nothing a process receives may carry a non-ASCII
      # byte, because on this host it would arrive as a different string.
      assert Enum.all?(Labels.all(), &ascii?/1)
      assert Labels.friendly("in-progress") == "symphony:in-progress"
      assert Labels.internal("symphony:done") == "done"
      assert Labels.state_from_labels(["agent-task", "symphony:paused"]) == "paused"

      # A label a person made is not one of ours, in either vocabulary.
      assert Labels.internal("agent-task") == nil
      assert Labels.internal("done") == nil
      assert Labels.state_from_labels(["agent-task", "bug"]) == nil
    end
  end

  describe "a ticket the issue has never labelled" do
    test "its state label is created in the repository first, added second, and every label argument is ASCII" do
      dir = scratch_dir()
      write_ticket!(dir, [[:id, "SYM-1"], [:state, "in-progress"], [:issue, "42"]])

      log =
        mirror(dir, fn
          ["issue", "list" | _rest] -> {:ok, "[]", 0}
          ["issue", "view" | _rest] -> {:ok, issue_json([]), 0}
          ["label", "create" | _rest] -> {:ok, "Created label\n", 0}
          ["issue", "edit" | _rest] -> {:ok, "", 0}
        end)

      # The order is the point: a label the repository does not have is created *before* it is added,
      # which is what makes a fresh repository work on the first state change instead of every round.
      calls = label_calls(gh_calls())
      assert [create, add] = calls

      assert ["label", "create", "symphony:in-progress" | create_rest] = create
      assert "--force" in create_rest
      assert ["issue", "edit", "42", "--repo", "me/repo", "--add-label", "symphony:in-progress"] == add

      # The pin this change exists for: no label argument handed to the process runner is non-ASCII.
      arguments = label_arguments(calls)
      assert arguments != []
      assert Enum.all?(arguments, &ascii?/1)

      # And the state we put on the issue is recorded, so the next round reads it back as ours.
      assert state_file(dir)["SYM-1"]["state"] == "in-progress"
      refute log =~ "mirror failed"
    end

    test "a state change leaves exactly one label of ours on the issue" do
      # Closing the issue is the clearest state change there is: the ticket says `in-progress`, the
      # issue is closed, so the ticket becomes `done` -- and the label that was there is replaced
      # rather than joined, which is what "one label per state" means.
      dir = scratch_dir()
      write_ticket!(dir, [[:id, "SYM-1"], [:state, "in-progress"], [:issue, "42"]])

      log =
        mirror(dir, fn
          ["issue", "list" | _rest] -> {:ok, "[]", 0}
          ["issue", "view" | _rest] -> {:ok, issue_json(["symphony:in-progress"], "CLOSED"), 0}
          ["label", "create" | _rest] -> {:ok, "Created label\n", 0}
          ["issue", "edit" | _rest] -> {:ok, "", 0}
        end)

      assert log =~ "janitor: SYM-1 state -> done"

      assert label_calls(gh_calls()) == [
               ["label", "create", "symphony:done", "--repo", "me/repo", "--color", "1D76DB", "--description", "symphony ticket state", "--force"],
               ["issue", "edit", "42", "--repo", "me/repo", "--add-label", "symphony:done"],
               ["issue", "edit", "42", "--repo", "me/repo", "--remove-label", "symphony:in-progress"]
             ]

      assert state_file(dir)["SYM-1"]["state"] == "done"
    end

    test "a label that cannot be created is one logged line, not a failed mirror" do
      dir = scratch_dir()
      write_ticket!(dir, [[:id, "SYM-1"], [:state, "in-progress"], [:issue, "42"]])

      log =
        mirror(dir, fn
          ["issue", "list" | _rest] -> {:ok, "[]", 0}
          ["issue", "view" | _rest] -> {:ok, issue_json([]), 0}
          ["label", "create" | _rest] -> {:ok, "HTTP 403: Resource not accessible by token\n", 1}
        end)

      assert log =~ "janitor: label symphony:in-progress is not in me/repo and could not be created"
      assert log =~ "leaving the label off"
      refute log =~ "mirror failed"

      # Tried once, skipped, and attempted again by the *next round* rather than in a loop here: the
      # add is not attempted at all once the label is known to be missing, and nothing is repeated.
      assert [["label", "create" | _rest]] = label_calls(gh_calls())
    end
  end

  describe "a genuine mirror failure" do
    test "still fails the mirror" do
      dir = scratch_dir()
      write_ticket!(dir, [[:id, "SYM-1"], [:state, "in-progress"], [:issue, "42"]])

      log =
        mirror(dir, fn
          ["issue", "list" | _rest] -> {:ok, "[]", 0}
          ["issue", "view" | _rest] -> {:ok, "gh: Not Found (HTTP 404)\n", 1}
        end)

      assert log =~ "janitor: mirror failed for SYM-1"
      assert log =~ "HTTP 404"
      # Nothing was written onto the issue, and no state was recorded for it.
      assert label_calls(gh_calls()) == []
      refute state_file(dir)["SYM-1"]
    end
  end

  describe "a ticket with no issue yet (the adopt path)" do
    test "the issue is created carrying both labels, and both are ASCII" do
      dir = scratch_dir()
      write_ticket!(dir, [[:id, "SYM-1"], [:state, "ready"]])

      log =
        mirror(dir, fn
          ["issue", "list" | _rest] -> {:ok, "[]", 0}
          ["label", "create" | _rest] -> {:ok, "Created label\n", 0}
          ["issue", "create" | _rest] -> {:ok, "https://github.com/me/repo/issues/42\n", 0}
        end)

      calls = gh_calls()
      created = Enum.find(calls, &match?(["issue", "create" | _rest], &1))
      assert created

      # `agent-task` is not here on purpose: it is the label a person adds to ask for work, not one the
      # janitor puts on the issue it just made.
      assert flag_values([created], "--label") == ["symphony", "symphony:ready"]
      assert Enum.all?(label_arguments(label_calls(calls)), &ascii?/1)

      # The created issue's number is written back into the ticket, so the link is stable both ways.
      assert File.read!(Path.join(dir, "SYM-1.md")) =~ "issue: 42"
      assert log =~ "janitor: SYM-1 adopted into issue #42"
    end

    test "a label that does not exist does not cost the issue" do
      # This is the reported failure, at the call that produced it: `gh issue create` refuses the
      # whole issue over one label it cannot find, so the mirror logged `mirror failed for ALPHA-2:
      # {:exit, 1, "could not add label: ... not found"}` every round and the ticket never got an
      # issue. The label is left off instead, named once, and the next round's mirror adds it.
      dir = scratch_dir()
      write_ticket!(dir, [[:id, "SYM-1"], [:state, "ready"]])

      log =
        mirror(dir, fn
          ["issue", "list" | _rest] -> {:ok, "[]", 0}
          ["label", "create" | _rest] -> {:ok, "could not create label: HTTP 404\n", 1}
          ["issue", "create" | _rest] -> {:ok, "https://github.com/me/repo/issues/42\n", 0}
        end)

      created = Enum.find(gh_calls(), &match?(["issue", "create" | _rest], &1))
      assert created
      assert flag_values([created], "--label") == []
      assert File.read!(Path.join(dir, "SYM-1.md")) =~ "issue: 42"
      assert log =~ "could not be created"
      refute log =~ "mirror failed"
    end
  end

  # ── the mirror, driven through an injected runner ─────────────────────────────

  defp mirror(dir, responder) do
    parent = self()

    runner = fn args ->
      send(parent, {:gh, args})
      responder.(args)
    end

    capture_log(fn ->
      assert :ok =
               Janitor.run_once(
                 tickets: dir,
                 workspace_root: Path.join(dir, "workspaces"),
                 repo: "me/repo",
                 state_file: Path.join(dir, "state.json"),
                 runner: runner
               )
    end)
  end

  # Everything the round handed to the runner, in the order it was called. The mailbox is the test
  # process's, and `run_once/1` runs in it.
  defp gh_calls(acc \\ []) do
    receive do
      {:gh, args} -> gh_calls([args | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp label_calls(calls), do: Enum.filter(calls, &label_call?/1)
  defp label_call?(["label", "create" | _rest]), do: true
  defp label_call?(["issue", "edit" | _rest]), do: true
  defp label_call?(_args), do: false

  # Every argument this round used to *name* a label, whichever flag carried it.
  defp label_arguments(calls) do
    flag_values(calls, "--label") ++
      flag_values(calls, "--add-label") ++
      flag_values(calls, "--remove-label") ++ created_labels(calls)
  end

  defp flag_values(calls, flag) do
    calls
    |> Enum.flat_map(&Enum.chunk_every(&1, 2, 1))
    |> Enum.flat_map(fn
      [^flag, value] -> [value]
      _other -> []
    end)
  end

  defp created_labels(calls) do
    for ["label", "create", name | _rest] <- calls, do: name
  end

  defp ascii?(string), do: string |> :binary.bin_to_list() |> Enum.all?(&(&1 < 128))

  # ── scratch tickets ───────────────────────────────────────────────────────────

  defp scratch_dir do
    dir = Path.join(System.tmp_dir!(), "symphony-janitor-labels-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "workspaces"))
    # A repository of its own: this round ends with `git add -A` / `commit` / `push`, and a temp
    # directory sitting inside some other checkout would have that checkout staged instead.
    {_, 0} = System.cmd("git", ["init", "-q", dir])
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp write_ticket!(dir, fields) do
    front_matter = Enum.map(fields, fn [key, value] -> "#{key}: #{value}" end)

    text = Enum.join(["---" | front_matter] ++ ["---", "", "body", ""], "\n")
    File.write!(Path.join(dir, "SYM-1.md"), text)
  end

  defp state_file(dir) do
    path = Path.join(dir, "state.json")
    if File.exists?(path), do: JSON.decode!(File.read!(path)), else: %{}
  end

  defp issue_json(labels, state \\ "OPEN") do
    JSON.encode!(%{
      "state" => state,
      "labels" => Enum.map(labels, &%{"name" => &1}),
      "assignees" => [],
      "comments" => []
    })
  end
end
