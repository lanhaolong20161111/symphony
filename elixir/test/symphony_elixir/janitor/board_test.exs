defmodule SymphonyElixir.Janitor.BoardTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Janitor.Board

  defp row(id, state, opts \\ []) do
    %{
      id: id,
      title: Keyword.get(opts, :title, "A ticket"),
      state: state,
      priority: Keyword.get(opts, :priority, "2"),
      assignee: Keyword.get(opts, :assignee, ""),
      blocked_by: Keyword.get(opts, :blocked_by, ""),
      updated: Keyword.get(opts, :updated, "09-26 20:00")
    }
  end

  describe "render_index/2" do
    test "the view bar counts each state, including zero" do
      rows = [row("SYM-1", "in-review"), row("SYM-2", "in-review"), row("SYM-3", "done")]

      index = Board.render_index(rows, repo: "me/tickets")

      # The PowerShell original printed 0 for every view here while the view files were right:
      # its count ran inside a nested pipeline where $_ was the row, not the view.
      assert index =~ "[all (3)](README.md)"
      assert index =~ "[in-review (2)](BOARD-in-review.md)"
      assert index =~ "[done (1)](BOARD-done.md)"
      assert index =~ "[ready (0)](BOARD-ready.md)"
      assert index =~ "[cancelled (0)](BOARD-cancelled.md)"
    end

    test "an empty queue still renders a valid board" do
      index = Board.render_index([], repo: "me/tickets")
      assert index =~ "[all (0)](README.md)"
      assert index =~ "| _none_ |"
    end

    test "the board must not look like a ticket" do
      # If a board ever gained front matter the tracker would try to read it as a ticket, and the
      # janitor's own `split/1` would agree. Both are regex-based on `\A---`, so starting with a
      # heading is the invariant that keeps them out of the queue.
      index = Board.render_index([row("SYM-1", "ready")], repo: "me/tickets")
      view = Board.render_view(%{state: "ready", title: "Queued"}, [row("SYM-1", "ready")])

      refute String.starts_with?(index, "---")
      refute String.starts_with?(view, "---")
      assert String.starts_with?(index, "# Tickets")
    end

    test "the orientation note points a person at the issue form" do
      index = Board.render_index([], repo: "me/tickets")
      assert index =~ "https://github.com/me/tickets/issues"
      assert index =~ "fill-in-the-blank form"
    end
  end

  describe "render_view/2" do
    test "carries its own count and only its own rows" do
      rows = [row("SYM-1", "in-review"), row("SYM-2", "done")]

      view = Board.render_view(%{state: "in-review", title: "Waiting on you"}, rows)

      assert view =~ "# Waiting on you -- `in-review` (1)"
      assert view =~ "[SYM-1](SYM-1.md)"
      refute view =~ "[SYM-2](SYM-2.md)"
    end

    test "a terminal view is capped, and says so" do
      rows = Enum.map(1..25, &row("SYM-#{&1}", "done"))
      view = Board.render_view(%{state: "done", title: "Done"}, rows)

      assert view =~ "(25)"
      assert view =~ "Showing the 20 most recent of 25"
      assert view =~ "[SYM-1](SYM-1.md)"
      refute view =~ "[SYM-21](SYM-21.md)"
    end

    test "a non-terminal view is never capped" do
      rows = Enum.map(1..25, &row("SYM-#{&1}", "ready"))
      view = Board.render_view(%{state: "ready", title: "Queued"}, rows)

      assert view =~ "[SYM-25](SYM-25.md)"
      refute view =~ "most recent of"
    end
  end

  describe "sort/1" do
    test "orders by view order, then priority, then id" do
      rows = [
        row("SYM-9", "done"),
        row("SYM-8", "ready", priority: "1"),
        row("SYM-7", "in-review", priority: "5"),
        row("SYM-6", "ready", priority: "1"),
        row("SYM-5", "in-review", priority: "1")
      ]

      assert Enum.map(Board.sort(rows), & &1.id) == ~w(SYM-5 SYM-7 SYM-6 SYM-8 SYM-9)
    end

    test "an unknown state sorts after the known ones and a missing priority last" do
      rows = [row("SYM-1", "weird"), row("SYM-2", "ready", priority: ""), row("SYM-3", "ready", priority: "3")]
      assert Enum.map(Board.sort(rows), & &1.id) == ~w(SYM-3 SYM-2 SYM-1)
    end
  end
end
