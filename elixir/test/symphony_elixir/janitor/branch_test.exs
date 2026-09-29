defmodule SymphonyElixir.Janitor.BranchTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Janitor

  # The branch name is the ticket's business: `branch_name` is the tracker-provided branch metadata
  # the spec's normalized issue carries, and the file tracker already parses it. These tests pin both
  # directions -- read it, and record it only when absent -- because the second one is what keeps the
  # derived default from overwriting a person's edit on every 30-second round.

  describe "ticket_branch/2" do
    test "defaults to symphony/<id> when the ticket does not name a branch" do
      text = """
      ---
      id: SYM-26
      title: "Anything"
      state: in-review
      ---

      body
      """

      assert Janitor.ticket_branch(text, "SYM-26") == "symphony/SYM-26"
    end

    test "a branch_name in the front matter wins" do
      text = """
      ---
      id: SYM-26
      branch_name: feat/keep-it
      ---

      body
      """

      assert Janitor.ticket_branch(text, "SYM-26") == "feat/keep-it"
    end

    test "the value is unquoted the way the tracker unquotes it" do
      text = "---\nid: SYM-1\nbranch_name: \"feat/quoted\"\n---\n"

      assert Janitor.ticket_branch(text, "SYM-1") == "feat/quoted"
    end

    test "an empty branch_name falls back" do
      text = "---\nid: SYM-1\nbranch_name:\n---\n"

      assert Janitor.ticket_branch(text, "SYM-1") == "symphony/SYM-1"
    end

    test "a branch_name in the body does not count" do
      text = """
      ---
      id: SYM-1
      ---

      branch_name: feat/from-the-body
      """

      assert Janitor.ticket_branch(text, "SYM-1") == "symphony/SYM-1"
    end

    test "a file without front matter falls back" do
      assert Janitor.ticket_branch("# notes\n", "SYM-1") == "symphony/SYM-1"
    end
  end

  describe "with_branch_name/2" do
    test "adds the key, keeping the front matter the tracker matches on" do
      text = "---\nid: SYM-26\nstate: in-review\n---\n\nbody\n"

      updated = Janitor.with_branch_name(text, "symphony/SYM-26")

      assert updated =~ "branch_name: symphony/SYM-26"
      assert String.starts_with?(updated, "---\n")
    end

    test "keeps the name a person already put there" do
      text = "---\nid: SYM-26\nbranch_name: feat/keep-it\n---\n\nbody\n"

      assert Janitor.with_branch_name(text, "symphony/SYM-26") == text
    end

    test "a file without front matter is returned untouched" do
      assert Janitor.with_branch_name("# notes\n", "symphony/SYM-1") == "# notes\n"
    end
  end
end
