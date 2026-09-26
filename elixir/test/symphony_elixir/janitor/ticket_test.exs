defmodule SymphonyElixir.Janitor.TicketTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Janitor.Ticket

  @ticket """
  ---
  id: SYM-6
  title: "Smoke test: add a marker line"
  state: in-review
  priority: 2
  ---

  Body line one.

  ## Validation

  - [ ] `findstr /C:"x" README.md` exits 0
  """

  describe "split/1" do
    test "parses front matter and body" do
      assert {:ok, %{front_matter: fm, body: body}} = Ticket.split(@ticket)
      assert fm =~ "id: SYM-6"
      assert body =~ "Body line one."
    end

    test "a file with no front matter is skipped -- this is what keeps boards out of the queue" do
      assert Ticket.split("# Tickets\n\n| [SYM-6](SYM-6.md) |\n") == :skip
      assert Ticket.split("") == :skip
    end

    test "a BOM before the opening --- also fails to parse (the silent-vanish case)" do
      # This is not a curiosity: the tracker's regex is the same, so a BOM'd ticket is invisible
      # to the queue. `problems/1` is what turns that silence into a warning.
      assert Ticket.split(<<0xEF, 0xBB, 0xBF>> <> @ticket) == :skip
    end
  end

  describe "get/2" do
    test "reads keys and strips quotes" do
      {:ok, %{front_matter: fm}} = Ticket.split(@ticket)
      assert Ticket.get(fm, "id") == "SYM-6"
      assert Ticket.get(fm, "title") == "Smoke test: add a marker line"
      assert Ticket.get(fm, "state") == "in-review"
    end

    test "a missing key is an empty string, never nil" do
      {:ok, %{front_matter: fm}} = Ticket.split(@ticket)
      assert Ticket.get(fm, "issue") == ""
      assert Ticket.get(fm, "assignee_id") == ""
    end
  end

  describe "set_key/3" do
    test "replaces an existing key in place" do
      updated = Ticket.set_key(@ticket, "state", "done")

      assert updated =~ "state: done"
      refute updated =~ "state: in-review"
      # everything else survives
      assert updated =~ ~s(title: "Smoke test: add a marker line")
      assert updated =~ "Body line one."
    end

    test "a brand-new key lands INSIDE the front matter" do
      updated = Ticket.set_key(@ticket, "issue", "19")

      assert {:ok, %{front_matter: fm}} = Ticket.split(updated)
      assert Ticket.get(fm, "issue") == "19"
      # The PowerShell version inserted before the opening `---`, which broke the front matter
      # entirely and made the ticket invisible. Assert the file still opens with it.
      assert String.starts_with?(updated, "---\n")
      assert String.starts_with?(fm, "issue: 19")
    end

    test "only the front matter is edited, even when the body repeats the key" do
      # The PowerShell version called the static [regex]::Replace($s,$p,$r,1); that trailing 1 was
      # read as RegexOptions (IgnoreCase), so EVERY match was replaced and a second copy of the key
      # appeared in the body. Restricting the edit to the front-matter section makes that
      # impossible, and this test pins it.
      text =
        """
        ---
        id: SYM-9
        state: ready
        ---

        issue: 999
        state: do-not-touch
        """

      updated = Ticket.set_key(text, "issue", "42")

      assert updated =~ "issue: 42"
      assert updated =~ "issue: 999"
      assert updated =~ "state: do-not-touch"
      assert length(String.split(updated, "issue: 42")) == 2
    end

    test "text without front matter is returned unchanged rather than corrupted" do
      assert Ticket.set_key("# not a ticket\n", "state", "done") == "# not a ticket\n"
    end
  end

  describe "build/4" do
    test "produces a ticket the tracker will read, with the issue number recorded" do
      text = Ticket.build("SYM-21", "Add a marker", "21", "  Do the thing.\n")
      assert {:ok, %{front_matter: fm, body: body}} = Ticket.split(text)
      assert Ticket.get(fm, "id") == "SYM-21"
      assert Ticket.get(fm, "issue") == "21"
      assert Ticket.get(fm, "state") == "ready"
      assert body =~ "Do the thing."
    end

    test "escapes a quote in the title so the YAML stays valid" do
      text = Ticket.build("SYM-22", ~s(Fix the "broken" label), "22", "body")
      assert {:ok, %{front_matter: fm}} = Ticket.split(text)
      assert Ticket.get(fm, "title") == ~s(Fix the "broken" label)
    end
  end

  describe "problems/1" do
    test "a healthy ticket has none" do
      assert Ticket.problems(@ticket) == []
    end

    test "reports a BOM, missing front matter and an unquoted colon in the title" do
      assert :bom in Ticket.problems(<<0xEF, 0xBB, 0xBF>> <> @ticket)
      assert :no_front_matter in Ticket.problems("just prose\n")
      assert :unquoted_colon_in_title in Ticket.problems("---\ntitle: Smoke test: add a line\n---\n")
    end

    test "a quoted title with a colon is fine" do
      refute :unquoted_colon_in_title in
               Ticket.problems("---\ntitle: \"Smoke test: add a line\"\n---\n")
    end
  end
end
