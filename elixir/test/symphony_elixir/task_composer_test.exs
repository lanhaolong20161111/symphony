defmodule SymphonyElixir.TaskComposerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Janitor.Ticket
  alias SymphonyElixir.TaskComposer

  describe "build_issue_body/1" do
    test "produces the form headings the janitor parses" do
      body = TaskComposer.build_issue_body(%{title: "T", description: "Do the thing."})

      assert body =~ "### 要做什么"
      assert body =~ "Do the thing."
      assert body =~ "### 怎么算做完了"
      assert body =~ "_No response_"
    end

    test "includes validation when provided" do
      body =
        TaskComposer.build_issue_body(%{
          title: "T",
          description: "Add a line.",
          validation: "README has the marker."
        })

      assert body =~ "README has the marker."
      refute body =~ "_No response_"
    end

    test "includes a human-readable dependency note when blocked_by is set" do
      body =
        TaskComposer.build_issue_body(%{
          title: "T",
          description: "Depends on another task.",
          blocked_by: ["SYM-1", "SYM-2"]
        })

      assert body =~ "#SYM-1"
      assert body =~ "#SYM-2"
      assert body =~ "依赖"
    end

    test "omits the dependency note when blocked_by is empty" do
      body = TaskComposer.build_issue_body(%{title: "T", description: "No deps."})

      refute body =~ "依赖"
    end
  end

  describe "build_ticket_text/3" do
    test "produces a ticket the tracker will read, with the issue number recorded" do
      text =
        TaskComposer.build_ticket_text("SYM-42", %{title: "Add a marker", description: "Do it."}, "42")

      assert {:ok, %{front_matter: fm, body: body}} = Ticket.split(text)
      assert Ticket.get(fm, "id") == "SYM-42"
      assert Ticket.get(fm, "issue") == "42"
      assert Ticket.get(fm, "state") == "ready"
      assert body =~ "Do it."
    end

    test "escapes a quote in the title so the YAML stays valid" do
      text =
        TaskComposer.build_ticket_text("SYM-9", %{title: ~s(Fix the "broken" thing), description: "x"}, "9")

      assert {:ok, %{front_matter: fm}} = Ticket.split(text)
      assert Ticket.get(fm, "title") == ~s(Fix the "broken" thing)
    end

    test "adds a Validation section when validation is provided" do
      text =
        TaskComposer.build_ticket_text(
          "SYM-1",
          %{title: "T", description: "Do it.", validation: "Run the check."},
          "1"
        )

      assert text =~ "## Validation"
      assert text =~ "Run the check."
    end

    test "omits the Validation section when validation is blank" do
      text = TaskComposer.build_ticket_text("SYM-1", %{title: "T", description: "Do it."}, "1")

      refute text =~ "## Validation"
    end

    test "writes blocked_by as a YAML flow sequence the file tracker parses as a list" do
      text =
        TaskComposer.build_ticket_text(
          "SYM-3",
          %{title: "T", description: "x", blocked_by: ["SYM-1", "SYM-2"]},
          "3"
        )

      assert {:ok, %{front_matter: fm}} = Ticket.split(text)
      assert Ticket.get(fm, "blocked_by") == "[SYM-1, SYM-2]"

      # The file tracker parses the YAML with YamlElixir; the flow sequence must
      # decode to a list of strings, not a single string.
      assert {:ok, decoded} = YamlElixir.read_from_string(fm)
      assert decoded["blocked_by"] == ["SYM-1", "SYM-2"]
    end

    test "omits blocked_by when no dependencies are given" do
      text = TaskComposer.build_ticket_text("SYM-1", %{title: "T", description: "x"}, "1")

      assert {:ok, %{front_matter: fm}} = Ticket.split(text)
      assert Ticket.get(fm, "blocked_by") == ""
    end
  end

  describe "format_blocked_by/1" do
    test "formats a list as a YAML flow sequence" do
      assert TaskComposer.format_blocked_by(["SYM-1", "SYM-2"]) == "[SYM-1, SYM-2]"
    end

    test "a single dependency is still a flow sequence" do
      assert TaskComposer.format_blocked_by(["SYM-1"]) == "[SYM-1]"
    end

    test "an empty list is an empty flow sequence" do
      assert TaskComposer.format_blocked_by([]) == "[]"
    end
  end

  describe "parse_issue_number/1" do
    test "extracts the number from a gh issue create URL" do
      output = "https://github.com/owner/repo/issues/42\n"

      assert TaskComposer.parse_issue_number(output) == {:ok, "42"}
    end

    test "returns :error for output without an issues URL" do
      assert TaskComposer.parse_issue_number("some error message") == :error
      assert TaskComposer.parse_issue_number("") == :error
    end
  end

  describe "create_task/1" do
    test "rejects a missing title" do
      assert TaskComposer.create_task(%{title: nil}) == {:error, :missing_title}
      assert TaskComposer.create_task(%{title: ""}) == {:error, :missing_title}
    end
  end
end
