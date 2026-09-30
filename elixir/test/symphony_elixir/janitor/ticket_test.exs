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

  # Chinese text from the ticket that started this: ALPHA-2's description and the comment its run left.
  # Both are the point of the tests below -- a shell editor destroys exactly these characters.
  @chinese_body "只做这一件事，不要探索仓库、不要跑测试套件、不要读别的文件（省 token ✓）。\n\n在 `README.md` 最后追加**一行**：\n"
  @chinese_comment "提交 420cc28、push 退出码 0、PR 链接 ✓、**凭据前 4 字符** ✓（ghs_ = App 令牌 ✓）"

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

    test "a BOM is tolerated when parsing, and still reported as a smell" do
      # Measured on SYM-48: a run edited its own ticket with a Windows shell, the BOM stopped the file
      # being a ticket at all, and the queue lost it mid-run. Parsing now tolerates the BOM; `problems/1`
      # still says so, because whatever wrote it may have changed more than the BOM.
      text = <<0xEF, 0xBB, 0xBF>> <> @ticket

      assert {:ok, %{front_matter: fm}} = Ticket.split(text)
      assert fm =~ "id: SYM-6"
      assert :bom in Ticket.problems(text)
      refute :no_front_matter in Ticket.problems(text)
    end
  end

  describe "add_link/4" do
    # The file tracker's counterpart of Linear's attachmentLinkGitHubPR: the pull request a ticket
    # produced belongs on the ticket, where the next reader finds it without asking GitHub.

    test "records a link in the inline links list" do
      updated = Ticket.add_link(@ticket, "https://github.com/o/r/pull/7", "PR 7", "pr")

      {:ok, %{front_matter: fm}} = Ticket.split(updated)
      assert Ticket.get(fm, "links") =~ ~s(url: "https://github.com/o/r/pull/7")
      assert Ticket.get(fm, "links") =~ ~s(title: "PR 7")
      assert Ticket.get(fm, "links") =~ "kind: pr"
    end

    test "is idempotent for the same link" do
      once = Ticket.add_link(@ticket, "https://github.com/o/r/pull/7", "PR 7", "pr")
      twice = Ticket.add_link(once, "https://github.com/o/r/pull/7", "PR 7", "pr")

      assert twice == once
    end

    test "appends a second link instead of replacing the first" do
      once = Ticket.add_link(@ticket, "https://github.com/o/r/pull/7", "PR 7", "pr")
      twice = Ticket.add_link(once, "https://example.test/spec", "Spec", "url")

      {:ok, %{front_matter: fm}} = Ticket.split(twice)
      links = Ticket.get(fm, "links")

      assert links =~ "pull/7"
      assert links =~ "example.test/spec"
      assert String.starts_with?(links, "[")
      assert String.ends_with?(links, "]")
    end

    test "a block-form links list is left alone rather than clobbered" do
      text = """
      ---
      id: SYM-7
      links:
        - url: "https://example.test/one"
      ---

      Body
      """

      assert Ticket.add_link(text, "https://github.com/o/r/pull/8", "PR 8", "pr") == text
    end

    test "a ticket with no front matter is returned untouched" do
      assert Ticket.add_link("# notes\n", "https://github.com/o/r/pull/7", "PR 7", "pr") ==
               "# notes\n"
    end
  end

  describe "append_comment/4 and next_local_id/1" do
    # A comment is the one thing an agent cannot safely do by editing the body, which is why the host
    # writes it. The id is local so it cannot collide with the GitHub ids the janitor mirrors in.

    test "appends to an existing Discussion section" do
      text = """
      ---
      id: SYM-8
      state: in-review
      ---

      Body

      ## Discussion
      - **lhl20** (2026-09-29T08:00:00Z, id=123456): first
      """

      updated = Ticket.append_comment(text, "agent", "second", "local-1")

      assert updated =~ "id=123456): first"
      assert updated =~ "- **agent** ("
      assert updated =~ "id=local-1): second"
      assert length(String.split(updated, "## Discussion")) == 2
    end

    test "creates the section when there is none" do
      updated = Ticket.append_comment(@ticket, "agent", "a note", "local-1")

      assert updated =~ "## Discussion"
      assert updated =~ "id=local-1): a note"
      # The body above it is untouched.
      assert updated =~ "Body line one."
      assert updated =~ "## Validation"
    end

    test "ids count up from the ones already present" do
      assert Ticket.next_local_id(@ticket) == "local-1"

      once = Ticket.append_comment(@ticket, "agent", "one", Ticket.next_local_id(@ticket))
      assert Ticket.next_local_id(once) == "local-2"

      twice = Ticket.append_comment(once, "agent", "two", Ticket.next_local_id(once))
      assert Ticket.next_local_id(twice) == "local-3"
    end

    test "newlines are flattened, so a comment cannot forge a section" do
      updated = Ticket.append_comment(@ticket, "agent", "one\n## Discussion\ninjected", "local-1")

      assert updated =~ "id=local-1): one ## Discussion injected"
    end

    test "a file with no front matter is returned untouched" do
      assert Ticket.append_comment("# notes\n", "agent", "x", "local-1") == "# notes\n"
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

  describe "form_answer/2" do
    # The body GitHub produces for the issue form in this repository. The second heading carries a
    # parenthetical hint, which is exactly what an exact-match pattern chokes on.
    @form_body """
    ### 要做什么

    在 README.md 末尾加一行。

    ### 怎么算做完了（可以不填）

    README 里有标记

    ### 急不急（可以不填）

    不急
    """

    test "reads an answer whose heading is exactly the label" do
      assert Ticket.form_answer(@form_body, "要做什么") == "在 README.md 末尾加一行。"
    end

    test "reads an answer whose heading carries a parenthetical hint" do
      # Measured bug: the pattern required the label to be followed by end-of-line, so this answer
      # was never found and the ticket never got a Validation section.
      assert Ticket.form_answer(@form_body, "怎么算做完了") == "README 里有标记"
      assert Ticket.form_answer(@form_body, "急不急") == "不急"
    end

    test "an absent section is nil, and a body that is not a form is nil" do
      assert Ticket.form_answer(@form_body, "不存在的栏") == nil
      assert Ticket.form_answer("just a sentence\n", "要做什么") == nil
    end

    test "answers do not bleed into each other" do
      refute Ticket.form_answer(@form_body, "要做什么") =~ "README 里有标记"
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

    test "reports bytes that are not UTF-8, which is what a lossy writer leaves behind" do
      # Measured shape (ALPHA-2, 2026-09-30): an agent moved the ticket's state with Windows
      # PowerShell 5.1, whose Get-Content/Set-Content default to the ANSI code page. The file was
      # re-encoded through CP936, and every byte pair that decoder rejected came back as `?` with the
      # byte after it consumed -- so `。\n` (E3 80 82 0A) became E3 80 3F. The surrounding Chinese is
      # fine, which is exactly why this has to be reported: the file looks like a ticket.
      damaged = "---\nid: ALPHA-2\nstate: ready\n---\n" <> "中文" <> <<0xE3, 0x80, 0x3F, 0x0A>>

      refute String.valid?(damaged)
      assert :invalid_utf8 in Ticket.problems(damaged)
      refute :no_front_matter in Ticket.problems(damaged)
    end
  end

  describe "the ticket write path and multi-byte text" do
    # The rule every writer here keeps: a ticket is UTF-8, and its only safe writer is one that never
    # re-encodes it. These tests pin the path the host owns -- the one an agent must use instead of
    # editing the file itself -- against the characters a shell round trip destroys.

    test "a description and a comment of Chinese text round-trip byte for byte" do
      ticket =
        "---\n" <>
          "id: ALPHA-2\n" <>
          "title: \"E2E e2e-alpha ticket 2 中文标题\"\n" <>
          "state: ready\n" <>
          "---\n" <> @chinese_body

      updated =
        ticket
        |> Ticket.set_key("state", "in-review")
        |> Ticket.add_link("https://example.test/pull/2", "PR 2", "pr")
        |> Ticket.append_comment("agent", @chinese_comment, "local-1")

      assert String.valid?(updated)

      # Read it back the way the tracker does: the state moved, and nothing else did.
      assert {:ok, %{front_matter: fm, body: body}} = Ticket.split(updated)
      assert Ticket.get(fm, "state") == "in-review"
      assert Ticket.get(fm, "title") == "E2E e2e-alpha ticket 2 中文标题"
      assert binary_part(body, 0, byte_size(@chinese_body)) == @chinese_body
      assert body =~ @chinese_comment
    end

    test "every character survives the state change itself" do
      ticket = "---\nid: ALPHA-2\nstate: ready\n---\n" <> @chinese_body

      read_back = Ticket.set_key(ticket, "state", "in-review")

      # The only difference between the two is the state line.
      before = String.replace(ticket, "state: ready", "state: in-review")
      assert read_back == before
      assert String.valid?(read_back)
    end
  end
end
