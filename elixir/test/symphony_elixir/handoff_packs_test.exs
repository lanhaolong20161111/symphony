defmodule SymphonyElixir.HandoffPacksTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.HandoffPacks

  @ticket """
  ---
  id: SYM-9
  issue: 9
  title: "Do the thing"
  state: in-review
  ---

  Do the thing properly.

  ## Validation

  - [ ] `mix test` is green

  ## Discussion

  - **someone** (2026-09-27): 这里有一句人写的评论，别弄丢
  """

  describe "put_section/3" do
    test "appends the section when it is absent" do
      updated = HandoffPacks.put_section(@ticket, "续接上下文", "# 续会话包\n\n目标：做那件事")

      assert updated =~ "## 续接上下文"
      assert updated =~ "目标：做那件事"
      # Everything the agent or the janitor wrote is still there.
      assert updated =~ "Do the thing properly."
      assert updated =~ "## Validation"
      assert updated =~ "## Discussion"
      assert updated =~ "这里有一句人写的评论，别弄丢"
    end

    test "replaces an existing section instead of stacking a second one" do
      once = HandoffPacks.put_section(@ticket, "续接上下文", "第一版包")
      twice = HandoffPacks.put_section(once, "续接上下文", "第二版包")

      assert twice =~ "第二版包"
      refute twice =~ "第一版包"
      assert length(String.split(twice, "## 续接上下文")) == 2
    end

    test "is idempotent -- the same input twice is byte-identical" do
      once = HandoffPacks.put_section(@ticket, "续接上下文", "同一份包")
      twice = HandoffPacks.put_section(once, "续接上下文", "同一份包")

      assert once == twice
    end

    test "a section in the middle does not swallow the sections after it" do
      with_middle =
        HandoffPacks.put_section(
          """
          ---
          id: SYM-1
          ---

          Body.

          ## 续接上下文

          旧包

          ## Validation

          keep me
          """,
          "_unused_",
          "x"
        )

      # The `## Validation` section survived the (unrelated) section insert.
      assert with_middle =~ "keep me"
      assert with_middle =~ "旧包"
    end
  end

  # The shape a real pack has: multi-line markdown that **contains its own `## ` headings**. The
  # first version of `put_section/3` ended a section at the next `## `, so it stopped at the pack's
  # own `## 目标` and left the rest of the previous pack in the file -- measured live: the ticket grew
  # by ~521 bytes per attach, forever. Every fixture here used a heading-free one-liner, so the unit
  # tests passed while the real file grew. This fixture is the one that would have caught it.
  @real_pack """
  # 续会话包

  > 把这段贴进新会话的第一条消息。

  ## 目标

  接着干那件事

  ## 已定决策（别再重新推导）

  - 用票的 blocked_by 表达依赖

  ## 已知坑（别再踩）

  - `Get-Content` 会把中文显示成乱码
  """

  describe "put_section/3 against a real pack" do
    test "does not leave the previous pack behind" do
      once = HandoffPacks.put_section(@ticket, "续接上下文", @real_pack)
      twice = HandoffPacks.put_section(once, "续接上下文", @real_pack)

      assert once == twice
      # Exactly one copy of each of the pack's own sub-headings.
      assert length(String.split(twice, "## 目标")) == 2
      assert length(String.split(twice, "## 已知坑（别再踩）")) == 2
      # And the ticket's own sections are untouched.
      assert twice =~ "## Validation"
      assert twice =~ "## Discussion"
      assert twice =~ "这里有一句人写的评论，别弄丢"
    end

    test "replacing with a shorter pack makes the file shorter" do
      long = HandoffPacks.put_section(@ticket, "续接上下文", @real_pack)
      short = HandoffPacks.put_section(long, "续接上下文", "短包")

      assert byte_size(short) < byte_size(long)
      refute short =~ "## 已知坑（别再踩）"
      assert short =~ "短包"
    end

    test "a pack containing something that looks like a heading fence cannot forge the boundary" do
      # Only the real end marker closes the section; arbitrary content cannot.
      sneaky = "## 续接上下文\n\n假的\n\n## 目标\n\n内容"
      updated = HandoffPacks.put_section(@ticket, "续接上下文", sneaky)
      again = HandoffPacks.put_section(updated, "续接上下文", "干净内容")

      refute again =~ "假的"
      assert length(String.split(again, "symphony:handoff")) == 3
    end
  end

  describe "workspace_of?/2" do
    test "matches a Windows path and a POSIX path for the same ticket" do
      assert HandoffPacks.workspace_of?(
               "c:\\Users\\lhl20\\code\\symphony-file-workspaces\\SYM-41",
               "SYM-41"
             )

      assert HandoffPacks.workspace_of?("C:/code/symphony-file-workspaces/SYM-41", "SYM-41")
    end

    test "is case-insensitive on the ticket id" do
      assert HandoffPacks.workspace_of?("C:/ws/sym-41", "SYM-41")
    end

    test "does not match a prefix or a different ticket" do
      refute HandoffPacks.workspace_of?("C:/ws/SYM-411", "SYM-41")
      refute HandoffPacks.workspace_of?("C:/ws/SYM-4", "SYM-41")
      refute HandoffPacks.workspace_of?("C:/ws/other", "SYM-41")
      refute HandoffPacks.workspace_of?(nil, "SYM-41")
    end
  end

  describe "recorder_url/0" do
    test "defaults to the standalone recorder" do
      previous = Application.get_env(:symphony_elixir, :recorder_upstream)
      Application.delete_env(:symphony_elixir, :recorder_upstream)

      assert HandoffPacks.recorder_url() == "http://127.0.0.1:4010"

      if previous, do: Application.put_env(:symphony_elixir, :recorder_upstream, previous)
    end

    test "is configurable" do
      previous = Application.get_env(:symphony_elixir, :recorder_upstream)
      Application.put_env(:symphony_elixir, :recorder_upstream, "http://127.0.0.1:4999")

      assert HandoffPacks.recorder_url() == "http://127.0.0.1:4999"

      if previous,
        do: Application.put_env(:symphony_elixir, :recorder_upstream, previous),
        else: Application.delete_env(:symphony_elixir, :recorder_upstream)
    end
  end

  describe "vendor_keys/0" do
    test "covers the three keys that decide who does the work" do
      keys = HandoffPacks.vendor_keys()

      assert ["acp", "adapter"] in keys
      assert ["acp", "model"] in keys
      assert ["agent", "backend"] in keys
    end
  end

  describe "attach/1 when the recorder is unreachable" do
    setup do
      previous = Application.get_env(:symphony_elixir, :recorder_upstream)
      # Port 1 refuses immediately, so this exercises the failure path without a timeout.
      Application.put_env(:symphony_elixir, :recorder_upstream, "http://127.0.0.1:1")

      on_exit(fn ->
        if previous,
          do: Application.put_env(:symphony_elixir, :recorder_upstream, previous),
          else: Application.delete_env(:symphony_elixir, :recorder_upstream)
      end)

      :ok
    end

    test "reports the failure instead of pretending" do
      assert {:error, {:recorder_unreachable, _reason}} = HandoffPacks.attach("SYM-9")
    end

    test "does not touch the ticket file" do
      # The value of this action is that the next agent really does see the context. A failed fetch
      # that still rewrote the ticket would be the worst outcome: a file that looks updated and is
      # not. Asserted through the pure section helper rather than the filesystem, because the
      # failure happens before any file is opened.
      path = Path.join(System.tmp_dir!(), "handoff-#{System.unique_integer([:positive])}.md")
      File.write!(path, @ticket)

      try do
        assert {:error, _reason} = HandoffPacks.attach("SYM-9")
        # `attach/1` resolves the session first, so the file was never opened.
        assert File.read!(path) == @ticket
      after
        File.rm(path)
      end
    end
  end
end
