defmodule SymphonyElixir.Janitor.Board do
  @moduledoc """
  Renders the ticket repository's landing page and its per-state views.

  The point of these files is that a person who does not know git can see the state of everything
  by opening the repository, and can narrow to "what is waiting on me" with one tap on a phone.
  So the index leads with counts, not with prose.

  ## Why the generated files are safe to keep in the repository

  They carry **no front matter**. `tracker/file.ex` skips a `.md` without front matter, so a board
  can never be mistaken for a ticket, and this module can never be asked to render one.
  """

  @views [
    %{state: "in-review", title: "Waiting on you"},
    %{state: "in-progress", title: "Agent working"},
    %{state: "ready", title: "Queued"},
    %{state: "paused", title: "Paused"},
    %{state: "done", title: "Done"},
    %{state: "cancelled", title: "Cancelled"}
  ]

  @terminal ~w(done cancelled)
  @terminal_cap 20

  @header "| Ticket | Title | State | Pri | Assignee | Blocked by | Updated |\n" <>
            "|---|---|---|---|---|---|---|"

  @typedoc "One row of a board; the keys `Parser` fills in from a ticket file."
  @type row :: %{
          id: String.t(),
          title: String.t(),
          state: String.t(),
          priority: String.t(),
          assignee: String.t(),
          blocked_by: String.t(),
          updated: String.t()
        }

  @doc "The views, in the order a person cares about them: what is waiting on them comes first."
  @spec views() :: [map()]
  def views, do: @views

  @doc """
  Renders the index: a view bar with counts, a short orientation note, then every ticket.

  The counts in the bar are computed **once, per view**, before any rendering. The PowerShell
  original computed them inside a nested pipeline where `$_` referred to the row rather than to the
  view, so every count read zero while the view files themselves were correct -- a wrong number on
  the page a person checks first.
  """
  @spec render_index([row()], keyword()) :: String.t()
  def render_index(rows, opts \\ []) do
    repo = Keyword.get(opts, :repo, "")
    interval = Keyword.get(opts, :interval_seconds, 30)
    by_state = group_by_state(rows)

    bar =
      [
        link("all", length(rows), "README.md")
        | Enum.map(
            @views,
            &link(&1.state, length(Map.get(by_state, &1.state, [])), "BOARD-#{&1.state}.md")
          )
      ]
      |> Enum.join(" - ")

    """
    # Tickets

    **Views:** #{bar}

    > Auto-generated every #{interval} seconds by the host janitor; do not edit these boards.
    > **You never need to touch these files.** To ask for work, open an issue at
    > https://github.com/#{repo}/issues -- there is a fill-in-the-blank form. Everything here is the
    > mechanical half: the issue is what a person owns, and the `state` above mirrors its label.

    #{@header}
    #{render_rows(rows, "_none_")}
    """
  end

  @doc "Renders one state's view file, with its count in the heading."
  @spec render_view(map(), [row()]) :: String.t()
  def render_view(%{state: state, title: title}, rows) do
    selected = Enum.filter(rows, &(&1.state == state))
    {shown, note} = cap(selected, state)

    """
    # #{title} -- `#{state}` (#{length(selected)})

    [<- all views](README.md)
    #{note}
    #{@header}
    #{render_rows(shown, "_none_")}
    """
  end

  @doc "Groups rows by state, so counts and views read from one place."
  @spec group_by_state([row()]) :: %{optional(String.t()) => [row()]}
  def group_by_state(rows) do
    Enum.group_by(rows, & &1.state)
  end

  @doc "Sorts rows the way a board reads: by view order, then priority, then id."
  @spec sort([row()]) :: [row()]
  def sort(rows) do
    Enum.sort_by(rows, fn row -> {view_order(row.state), priority(row.priority), row.id} end)
  end

  defp cap(rows, state) when state in @terminal and length(rows) > @terminal_cap do
    {Enum.take(rows, @terminal_cap), "\n_Showing the #{@terminal_cap} most recent of #{length(rows)}._\n"}
  end

  defp cap(rows, _state), do: {rows, ""}

  defp render_rows(rows, empty_label)

  defp render_rows([], empty_label), do: "| #{empty_label} | | | | | | |"

  defp render_rows(rows, _empty_label) do
    Enum.map_join(rows, "\n", fn row ->
      "| [#{row.id}](#{row.id}.md) | #{row.title} | `#{row.state}` | #{row.priority} | " <>
        "#{row.assignee} | #{row.blocked_by} | #{row.updated} |"
    end)
  end

  defp link(name, count, path), do: "[#{name} (#{count})](#{path})"

  defp view_order(state) do
    case Enum.find_index(@views, &(&1.state == state)) do
      nil -> 7
      index -> index
    end
  end

  defp priority(value) do
    case Integer.parse(to_string(value)) do
      {number, _rest} -> number
      :error -> 999
    end
  end
end
