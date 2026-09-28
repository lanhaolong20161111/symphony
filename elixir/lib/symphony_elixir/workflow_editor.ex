defmodule SymphonyElixir.WorkflowEditor do
  @moduledoc """
  Edits scalar keys in `WORKFLOW.md`'s front matter **in place, without losing comments**.

  ## Why not decode and re-emit

  `WORKFLOW.file*.md` carries a comment above nearly every setting, and those comments are the
  record of *why* each value is what it is -- measured traps, per-machine paths, the reasoning
  behind a timeout. Decoding the YAML and writing it back would delete all of it, and the file
  would still validate and still work, so nothing would report the loss.

  So this works line by line, the way `SymphonyElixir.Janitor.Ticket.set_key/3` does for tickets:
  find the key's line and replace its value, or insert a new key directly under its section
  header. Comments, blank lines, ordering and the prompt body are copied through untouched.

  ## Scope

  Scalars only, and only ones a one-line replacement cannot corrupt. A list is refused rather
  than collapsed, because a multi-line `[...]` replaced by one line would silently drop entries.

  ## Failure is explicit

  A path whose parent section is missing is created (appended, since a section that does not
  exist has no position to preserve). Anything else returns `{:error, reason}` rather than a
  best-effort edit: the caller writes the result to the live workflow file, and `WorkflowStore`
  picks up whatever is there within about a second.
  """

  @delimiter "---"

  @typedoc ~s(A key path, e.g. `["janitor", "issues_repo"]`.)
  @type path :: [String.t()]

  @doc """
  Sets `path` to `value`, returning the whole file text with only that value changed.

  `value` may be a binary, an integer or a boolean. A one-segment path targets a top-level key.
  """
  @spec put_scalar(String.t(), path(), String.t() | integer() | boolean()) ::
          {:ok, String.t()} | {:error, term()}
  def put_scalar(text, path, value)
      when is_binary(text) and is_list(path) and path != [] do
    with :ok <- validate_path(path),
         {:ok, front, body} <- split(text) do
      {parents, [key]} = Enum.split(path, length(path) - 1)

      case put_in_lines(front, parents, key, value) do
        {:ok, updated} ->
          {:ok, Enum.join([@delimiter | updated] ++ [@delimiter | body], "\n")}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp validate_path(path) do
    if Enum.all?(path, &(is_binary(&1) and String.trim(&1) != "")) do
      :ok
    else
      {:error, {:invalid_path, path}}
    end
  end

  # Line-based, exactly like `SymphonyElixir.Workflow.split_front_matter/1`: the file is known to
  # open with `---` and the front matter ends at the next one.
  defp split(text) do
    case String.split(text, ~r/\R/, trim: false) do
      [@delimiter | tail] ->
        {front, rest} = Enum.split_while(tail, &(&1 != @delimiter))

        case rest do
          [@delimiter | body] -> {:ok, front, body}
          _ -> {:error, :unterminated_front_matter}
        end

      _ ->
        {:error, :missing_front_matter}
    end
  end

  defp put_in_lines(lines, parents, key, value) do
    indent = 2 * length(parents)

    case locate_section(lines, parents) do
      {:ok, header_index, range} -> put_in_section(lines, header_index, range, key, value, indent)
      :error -> {:ok, lines ++ create_chain(parents, key, value, indent)}
    end
  end

  defp put_in_section(lines, header_index, range, key, value, indent) do
    case locate_key(lines, range, key, indent) do
      {:ok, index} -> {:ok, replace_scalar(lines, index, key, value)}
      :error -> insert_scalar(lines, header_index, range, key, value, indent)
    end
  end

  # Keep the line's own indentation, not the computed one: this file's convention is two spaces, but
  # rewriting a key at the depth *this module* expects would restructure a file that happens to use
  # four. Replacing a value should not move the key.
  defp replace_scalar(lines, index, key, value) do
    existing_indent = indent_of(Enum.at(lines, index))
    List.replace_at(lines, index, "#{pad(existing_indent)}#{key}: #{format_value(value)}")
  end

  defp insert_scalar(lines, header_index, range, key, value, indent) do
    # Refuse to turn a section into a scalar: replacing `tracker:` with `tracker: x` would orphan
    # everything nested under it, and the file would still parse.
    #
    # `match?/2`, not `if locate_header(...)`: both `:error` and `{:ok, _}` are truthy, so a plain
    # `if` refused every insert instead of only the section case (surfaced by a compiler type
    # warning, which is why that warning is worth reading).
    if match?({:ok, _}, locate_header(lines, range, key)) do
      {:error, {:would_overwrite_section, key}}
    else
      {:ok, List.insert_at(lines, header_index + 1, "#{pad(indent)}#{key}: #{format_value(value)}")}
    end
  end

  defp create_chain(parents, key, value, indent) do
    sections = Enum.map(Enum.with_index(parents), fn {seg, depth} -> "#{pad(2 * depth)}#{seg}:" end)
    sections ++ ["#{pad(indent)}#{key}: #{format_value(value)}"]
  end

  # Top level: there is no header line to insert under, so `-1` puts an inserted key first.
  defp locate_section(_lines, []), do: {:ok, -1, {0, :all}}

  defp locate_section(lines, [first | rest]) do
    case locate_header(lines, {0, :all}, first) do
      {:ok, index} ->
        locate_section(lines, rest, index)

      :error ->
        :error
    end
  end

  defp locate_section(lines, [next | rest], header_index) do
    range = {header_index + 1, block_end(lines, header_index)}

    case locate_header(lines, range, next) do
      {:ok, index} -> locate_section(lines, rest, index)
      :error -> :error
    end
  end

  defp locate_section(lines, [], header_index) do
    {:ok, header_index, {header_index + 1, block_end(lines, header_index)}}
  end

  # The block of a section header runs until the first non-blank line indented no deeper than it.
  defp block_end(lines, header_index) do
    header_indent = indent_of(Enum.at(lines, header_index))

    lines
    |> Enum.with_index()
    |> Enum.drop(header_index + 1)
    |> Enum.find_value(length(lines), fn {line, index} ->
      if String.trim(line) != "" and indent_of(line) <= header_indent, do: index
    end)
  end

  defp locate_header(lines, range, segment) do
    lines
    |> indexed_slice(range)
    |> Enum.find_value(fn {line, index} ->
      if key_of(line) == segment and value_of(line) == "", do: index
    end)
    |> ok_or_error()
  end

  # A scalar key. A line with the right name and indentation but no value counts only when it has
  # no children -- otherwise it is a section header and overwriting it would orphan them.
  defp locate_key(lines, range, key, indent) do
    lines
    |> indexed_slice(range)
    |> Enum.find_value(fn {line, index} ->
      cond do
        key_of(line) != key -> nil
        indent_of(line) != indent -> nil
        value_of(line) != "" -> index
        has_children?(lines, index) -> nil
        true -> index
      end
    end)
    |> ok_or_error()
  end

  defp ok_or_error(nil), do: :error
  defp ok_or_error(index), do: {:ok, index}

  defp indexed_slice(lines, {from, :all}), do: indexed_slice(lines, {from, length(lines)})

  defp indexed_slice(lines, {from, to}) do
    lines |> Enum.with_index() |> Enum.slice(from, max(to - from, 0))
  end

  defp has_children?(lines, index) do
    lines
    |> Enum.drop(index + 1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> List.first()
    |> case do
      nil -> false
      next -> indent_of(next) > indent_of(Enum.at(lines, index))
    end
  end

  defp key_of(line) do
    case Regex.run(~r/^\s*([A-Za-z0-9_.-]+)\s*:/, line) do
      [_, key] -> key
      _ -> nil
    end
  end

  defp value_of(line) do
    case Regex.run(~r/^\s*[A-Za-z0-9_.-]+\s*:\s*(.*)$/, line) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end

  defp indent_of(line), do: String.length(line) - String.length(String.trim_leading(line))

  defp pad(0), do: ""
  defp pad(indent), do: String.duplicate(" ", indent)

  defp format_value(value) when is_boolean(value), do: Atom.to_string(value)
  defp format_value(value) when is_integer(value), do: Integer.to_string(value)

  defp format_value(value) when is_binary(value) do
    trimmed = String.trim(value)

    if quote?(trimmed) do
      ~s("#{String.replace(trimmed, "\"", "\\\"")}")
    else
      trimmed
    end
  end

  defp quote?(""), do: true

  defp quote?(value) do
    String.contains?(value, ": ") or
      String.starts_with?(value, ~w(# - ? : ! & * { } [ ] , % @ ` | > ' ")) or
      String.ends_with?(value, [" ", ":"]) or
      value != String.trim(value)
  end
end
