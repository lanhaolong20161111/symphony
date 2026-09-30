defmodule SymphonyElixir.Janitor.TicketWriteTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Janitor
  alias SymphonyElixir.Janitor.Ticket

  # The host's two writes to a ticket file: a comment and a state change. Both exist so that a run
  # never has to rewrite a ticket itself, and both therefore have to be exactly as safe as that claim
  # says -- the body, the front matter and every non-ASCII character in them come back byte for byte.
  #
  # The failure this pins is measured. On 2026-09-30 an agent moved ALPHA-2 to `in-progress` with
  # Windows PowerShell 5.1 -- `Get-Content -Raw`, a `-replace` on one line, `Set-Content -NoNewline` --
  # whose read and write default to the ANSI code page. The whole file was re-encoded through CP936,
  # 15 characters of readable Chinese became `?`, and the ticket stopped being valid UTF-8.

  @chinese_body "只做这一件事，不要探索仓库、不要跑测试套件（省 token ✓）。\n\n在 `README.md` 最后追加**一行**：\n"

  @damaged "---\nid: ALPHA-2\nstate: ready\n---\n" <> "中文" <> <<0xE3, 0x80, 0x3F, 0x0A>>

  defp tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "symphony-ticket-write-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp write_ticket(dir, text) do
    path = Path.join(dir, "ALPHA-2.md")
    File.write!(path, text)
    path
  end

  defp chinese_ticket do
    "---\n" <>
      "id: ALPHA-2\n" <>
      "title: \"E2E e2e-alpha ticket 2 中文标题\"\n" <>
      "state: ready\n" <>
      "priority: 2\n" <>
      "---\n" <> @chinese_body
  end

  test "a state change leaves every other byte of a Chinese ticket alone" do
    dir = tmp_dir()
    before = chinese_ticket()
    path = write_ticket(dir, before)

    assert {:ok, %{ticket: "ALPHA-2", state: "in-review"}} =
             Janitor.set_ticket_state("ALPHA-2", "in-review", tickets: dir)

    after_text = File.read!(path)

    assert String.valid?(after_text)
    # Byte for byte: the state line is the only difference between the file and what it was.
    assert after_text == String.replace(before, "state: ready", "state: in-review")
    assert String.contains?(after_text, @chinese_body)
    assert String.contains?(after_text, "中文标题")
  end

  test "a Chinese comment is appended and the ticket is still valid UTF-8" do
    dir = tmp_dir()
    path = write_ticket(dir, chinese_ticket())

    comment = "提交 420cc28、push 退出码 0、PR 链接 ✓、**凭据前 4 字符** ✓（ghs_ = App 令牌 ✓）"

    assert {:ok, %{ticket: "ALPHA-2", comment: %{id: "local-1", author: "agent"}}} =
             Janitor.comment_on_ticket("ALPHA-2", comment, tickets: dir)

    after_text = File.read!(path)

    assert String.valid?(after_text)
    assert String.contains?(after_text, comment)
    assert String.contains?(after_text, @chinese_body)
    assert String.contains?(after_text, "## Discussion")
  end

  test "both writes round-trip, and the tracker reads back the same characters" do
    dir = tmp_dir()
    path = write_ticket(dir, chinese_ticket())
    comment = "开始做了，先看 README。"

    assert {:ok, _} = Janitor.set_ticket_state("ALPHA-2", "in-progress", tickets: dir)
    assert {:ok, _} = Janitor.comment_on_ticket("ALPHA-2", comment, tickets: dir)

    read_back = File.read!(path)

    assert String.valid?(read_back)
    assert {:ok, %{front_matter: fm, body: body}} = Ticket.split(read_back)
    assert Ticket.get(fm, "state") == "in-progress"
    assert String.starts_with?(body, @chinese_body)
    assert String.contains?(body, comment)

    # And the way the system actually reads a ticket: the dispatcher's own decoder, whose description
    # is what the next run is handed. The characters have to be the same ones, not lookalikes.
    settings = %{
      provider: %{"path" => dir},
      active_states: ["in-progress"],
      terminal_states: ["done"]
    }

    assert {:ok, [issue]} = SymphonyElixir.Tracker.File.tickets(settings)
    assert issue.identifier == "ALPHA-2"
    assert issue.state == "in-progress"
    assert String.valid?(issue.description)
    assert String.starts_with?(issue.description, @chinese_body)
    assert String.contains?(issue.description, comment)
  end

  test "a ticket whose bytes are already broken is refused, not rewritten" do
    dir = tmp_dir()
    path = write_ticket(dir, @damaged)

    refute String.valid?(@damaged)

    assert {:error, {:ticket_not_utf8, "ALPHA-2"}} =
             Janitor.set_ticket_state("ALPHA-2", "in-review", tickets: dir)

    assert {:error, {:ticket_not_utf8, "ALPHA-2"}} =
             Janitor.comment_on_ticket("ALPHA-2", "hello", tickets: dir)

    # Refusing means refusing: the file is the byte it was, so a human can still recover it and the
    # host is not the second writer to push the damage along.
    assert File.read!(path) == @damaged
  end

  test "a missing ticket and a name that is not a ticket identifier fail closed" do
    dir = tmp_dir()

    assert {:error, {:no_such_ticket, "ALPHA-9"}} =
             Janitor.set_ticket_state("ALPHA-9", "done", tickets: dir)

    for id <- ["../escape", "a/b", "..", ""] do
      assert {:error, {:invalid_ticket_id, ^id}} =
               Janitor.set_ticket_state(id, "done", tickets: dir)
    end
  end
end
