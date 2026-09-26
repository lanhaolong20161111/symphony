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
end
