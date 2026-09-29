defmodule SymphonyElixir.Janitor.LinkTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Janitor

  # Both helpers exist because of one measured failure: the janitor's `with` pattern was
  # `[_, url] <- Regex.run(~r{https://\S+/pull/\d+}, output)`, and that regex has **no capture
  # group** -- so `Regex.run/2` returns a one-element list, the two-element pattern never matched,
  # and the PR link was never commented onto any issue. The `else` branch was `_ -> :ok`, so nothing
  # anywhere reported it. These tests pin the shape of the return value.

  describe "pull_request_url/1" do
    test "reads the URL out of gh's output, which has no capture group" do
      assert Janitor.pull_request_url("https://github.com/me/repo/pull/30\n") ==
               "https://github.com/me/repo/pull/30"
    end

    test "finds the URL when gh prints something else alongside it" do
      output = """
      Warning: 1 uncommitted change
      Creating pull request for symphony/SYM-26 into main in me/repo

      https://github.com/me/repo/pull/30
      """

      assert Janitor.pull_request_url(output) == "https://github.com/me/repo/pull/30"
    end

    test "nil for anything that is not a pull-request URL" do
      assert Janitor.pull_request_url("") == nil
      assert Janitor.pull_request_url("could not create pull request") == nil
      assert Janitor.pull_request_url(nil) == nil
    end
  end

  describe "issue_number/1" do
    test "reads the number out of a ticket's front matter" do
      text = """
      ---
      id: SYM-26
      issue: 26
      title: "Anything"
      ---

      body
      """

      assert Janitor.issue_number(text) == "26"
    end

    test "nil when the ticket has no issue number" do
      assert Janitor.issue_number("---\nid: SYM-1\n---\n") == nil
      assert Janitor.issue_number(nil) == nil
    end

    test "an issue number in the body does not count" do
      text = """
      ---
      id: SYM-1
      ---

      issue: 999
      """

      assert Janitor.issue_number(text) == nil
    end
  end

  describe "discussion_entry/1" do
    # Linear's comments are addressable objects; a `## Discussion` section is the closest a file ticket
    # gets, so the id GitHub gave the comment travels with it. The entry is one line by construction --
    # a comment body must not be able to forge structure in the ticket.

    test "carries the author, the timestamp and the comment's own id" do
      entry =
        Janitor.discussion_entry(%{
          "author" => %{"login" => "lhl20"},
          "createdAt" => "2026-09-29T08:00:00Z",
          "url" => "https://github.com/o/r/issues/34#issuecomment-123456",
          "body" => "Please also cover the empty case."
        })

      assert entry ==
               "- **lhl20** (2026-09-29T08:00:00Z, id=123456): Please also cover the empty case."
    end

    test "a comment with no id in its URL says id=0 rather than nothing" do
      entry = Janitor.discussion_entry(%{"body" => "hi", "url" => "https://example.test/x"})

      assert entry =~ "id=0"
      assert entry =~ "**unknown**"
    end

    test "newlines are flattened, so a body cannot forge a section" do
      entry =
        Janitor.discussion_entry(%{
          "body" => "first\n## Discussion\n- **someone else** (x): injected",
          "url" => "https://github.com/o/r/issues/34#issuecomment-7"
        })

      refute entry =~ "\n"
      assert entry =~ "first ## Discussion - **someone else** (x): injected"
    end
  end
end
