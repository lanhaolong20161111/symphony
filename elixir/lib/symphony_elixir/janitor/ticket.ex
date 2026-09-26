defmodule SymphonyElixir.Janitor.Ticket do
  @moduledoc """
  Reads and edits ticket files: Markdown with YAML front matter, the same shape
  `SymphonyElixir.Tracker.File` polls.

  ## The front-matter regex is deliberately the tracker's

  `@front_matter` below is character-for-character the one in `tracker/file.ex`. That is not
  duplication for its own sake: if the two ever disagree, the janitor starts boarding files the
  tracker refuses to read (or worse, ignoring files it would dispatch), and the queue and the board
  silently tell different stories. Change one, change both.

  ## Things this module refuses to do quietly

  A `.md` file whose front matter does not match is **skipped**, and with a leading UTF-8 BOM it
  never matches: `\\A---` cannot see past `EF BB BF`, so a BOM'd ticket disappears from the queue
  with no error anywhere. That is the failure this project fears most, and it is one `Set-Content`
  away in Windows PowerShell. `problems/1` exists so the janitor can be the thing that says it out
  loud instead of the thing that shrugs.
  """

  @front_matter ~r/\A---\s*\r?\n(.*?)\r?\n---\s*\r?\n?(.*)\z/s
  @bom <<0xEF, 0xBB, 0xBF>>

  @typedoc "One ticket, as the janitor sees it."
  @type t :: %{
          path: String.t(),
          id: String.t(),
          title: String.t(),
          state: String.t(),
          priority: String.t(),
          assignee: String.t(),
          blocked_by: String.t(),
          issue: String.t(),
          body: String.t(),
          mtime: DateTime.t() | nil
        }

  @doc """
  Parses a ticket file's text.

  Returns `{:ok, %{front_matter: fm, body: body}}` when the text opens with front matter, or
  `:skip` when it does not (a board file, a guide, or -- the dangerous case -- a BOM'd ticket).
  """
  @spec split(String.t()) :: {:ok, %{front_matter: String.t(), body: String.t()}} | :skip
  def split(text) when is_binary(text) do
    case Regex.run(@front_matter, text) do
      [_, front_matter, body] -> {:ok, %{front_matter: front_matter, body: body}}
      _ -> :skip
    end
  end

  @doc """
  Reads one front-matter key, unquoting it.

  Missing keys come back as `""`, never `nil`, so callers can compare and interpolate freely.
  Quotes are removed symmetrically with `build/4`, which escapes a `"` inside a title as `\\"`:
  a reader that only stripped the outer quotes would hand callers the backslash too.
  """
  @spec get(String.t(), String.t()) :: String.t()
  def get(front_matter, key) when is_binary(front_matter) and is_binary(key) do
    case Regex.run(~r/^\s*#{Regex.escape(key)}\s*:\s*(.+?)\s*$/m, front_matter) do
      [_, value] -> unquote_value(value)
      _ -> ""
    end
  end

  defp unquote_value(value) do
    value = String.trim(value)

    cond do
      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        value
        |> String.trim_leading("\"")
        |> String.trim_trailing("\"")
        |> String.replace("\\\"", "\"")

      String.starts_with?(value, "'") and String.ends_with?(value, "'") ->
        value |> String.trim_leading("'") |> String.trim_trailing("'")

      true ->
        value
    end
  end

  @doc """
  Sets a front-matter key, adding it when absent.

  A present key is replaced **once** (`global: false`). The PowerShell original called the static
  `[regex]::Replace($s, $p, $r, 1)`, which has no count parameter -- the trailing `1` became
  `RegexOptions` (1 = IgnoreCase) and every match was replaced, so a ticket ended up with a second
  copy of the key inside its body. Elixir makes the count explicit, and this module only ever edits
  the front-matter section, so the body cannot be touched at all.

  A new key is inserted directly after the opening `---`. Inserting it before instead would leave
  the file no longer starting with `---`, the tracker's `\\A---` would stop matching, and the ticket
  would vanish.
  """
  @spec set_key(String.t(), String.t(), String.t()) :: String.t()
  def set_key(text, key, value) when is_binary(text) do
    case split(text) do
      {:ok, %{front_matter: fm, body: body}} ->
        "---\n" <> put_key(fm, key, value) <> "\n---\n" <> body

      :skip ->
        text
    end
  end

  @doc "Builds the text of a brand-new ticket."
  @spec build(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def build(id, title, issue_number, body) do
    quoted = title |> to_string() |> String.replace("\"", "\\\"")

    "---\n" <>
      "id: #{id}\n" <>
      "issue: #{issue_number}\n" <>
      "title: \"#{quoted}\"\n" <>
      "state: ready\n" <>
      "---\n\n" <> String.trim(body) <> "\n"
  end

  @doc """
  Reports conditions that make a file a bad ticket, without changing anything.

  * `:bom` -- a leading UTF-8 BOM, which hides the ticket from the tracker entirely.
  * `:no_front_matter` -- nothing to parse; fine for prose, fatal for an intended ticket.
  * `:unquoted_colon_in_title` -- `title: Smoke test: add a line` is invalid YAML; the tracker
    answers with `{:file_tracker_invalid_yaml, ..}` and the ticket never dispatches.
  """
  @spec problems(String.t()) :: [atom()]
  def problems(text) when is_binary(text) do
    []
    |> add_if(String.starts_with?(text, @bom), :bom)
    |> add_if(split(text) == :skip, :no_front_matter)
    |> add_if(unquoted_colon_in_title?(text), :unquoted_colon_in_title)
  end

  defp add_if(list, true, problem), do: list ++ [problem]
  defp add_if(list, _false, _problem), do: list

  # An unquoted colon inside the title's scalar is the one YAML mistake a person is most likely to
  # make, and it has already happened once here.
  defp unquoted_colon_in_title?(text) do
    case Regex.run(~r/^\s*title\s*:\s*(.+)$/m, text) do
      [_, value] ->
        trimmed = String.trim(value)
        not String.starts_with?(trimmed, "\"") and String.contains?(String.trim_trailing(trimmed, "\""), ": ")

      _ ->
        false
    end
  end

  defp put_key(front_matter, key, value) do
    pattern = ~r/^\s*#{Regex.escape(key)}\s*:.*$/m

    if Regex.match?(pattern, front_matter) do
      Regex.replace(pattern, front_matter, "#{key}: #{value}", global: false)
    else
      "#{key}: #{value}\n" <> front_matter
    end
  end
end
