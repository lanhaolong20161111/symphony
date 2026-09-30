defmodule SymphonyElixir.Janitor.Labels do
  @moduledoc """
  Translates between the ticket's internal `state` and the label a person sees on the GitHub issue.

  The state vocabulary inside the files is machine-facing (`ready`, `in-review`, ...). The labels are
  the one part of this system a person picks from a menu, so they are written the way that person
  would say it, minus any character this host cannot hand to a child process. Keeping the two
  vocabularies separate is what lets the state machine stay exact while the human surface stays plain.

  ## Why every label name here is ASCII

  A label name leaves this host as an **argument** to `gh`, and on Windows Erlang encodes the
  arguments of a spawned process through the process's ANSI code page (`CP936` on this machine). A
  non-ASCII label is therefore mangled before `gh` ever sees it, and `gh` answers with the label it
  *did* receive:

      could not add label: '<mangled bytes>' not found

  Measured on ALPHA-2, where the intended label was three CJK characters and every one of them
  arrived as the wrong byte. The mirror asked for a label that did not exist under that name, every
  round, for every state change, and the ticket's state never reached its issue. The same codec
  family rewrote a ticket file on the same ticket, which is why the rule is stated once here and
  obeyed everywhere a process argument is built:

      no string this host hands to a child process may contain a non-ASCII byte.

  So the label *text* is ASCII and the *meaning* is unchanged: the same six states map to the same
  six labels, in the same order, and one issue still carries exactly one of them per state. Only the
  GitHub-facing spelling moved; the ticket states, the boards and the control console keep the
  vocabulary they had.

  `symphony:` is on every name for two reasons: `internal/1` can never mistake a label a person made
  for one of ours, and the six sort together in GitHub's label list.

  ## A label also has to exist before it can be put on an issue

  `gh` refuses a whole `issue edit` -- and a whole `issue create` -- over one label the repository
  does not have, and a fresh repository has none of these. So a missing label is not treated as a
  mirror failure anywhere: `SymphonyElixir.Janitor` creates ours on demand (`ensure_label/2`) and
  says one line when it cannot. This module itself never runs a process: it is the vocabulary, and
  the arguments are built where the arguments are run.
  """

  @pairs [
    {"ready", "symphony:ready"},
    {"in-progress", "symphony:in-progress"},
    {"in-review", "symphony:in-review"},
    {"paused", "symphony:paused"},
    {"done", "symphony:done"},
    {"cancelled", "symphony:cancelled"}
  ]

  @doc "Every label the janitor manages, in board order."
  @spec all() :: [String.t()]
  def all, do: Enum.map(@pairs, &elem(&1, 1))

  @doc "The label for an internal state, or `nil` when the state has no label."
  @spec friendly(String.t()) :: String.t() | nil
  def friendly(state) do
    Enum.find_value(@pairs, fn {internal, label} -> if internal == state, do: label end)
  end

  @doc "The internal state for a label, or `nil` when the label is not one of ours."
  @spec internal(String.t()) :: String.t() | nil
  def internal(label) do
    Enum.find_value(@pairs, fn {internal, friendly} -> if friendly == label, do: internal end)
  end

  @doc """
  Picks our state out of a list of labels, if any.

  Used on the read path: whatever the issue currently carries, this is the state it claims.

  An issue labelled before the names became ASCII carries a name that is not in `@pairs`, so it
  claims no state here and `internal/1` does not claim it as ours. That is deliberate rather than
  overlooked: the old names cannot be written into this file as literals (see the module doc), and a
  lookup table of escape sequences would be a second, invisible copy of a vocabulary that -- on this
  machine -- never successfully reached an issue in the first place.
  """
  @spec state_from_labels([String.t()]) :: String.t() | nil
  def state_from_labels(labels) do
    Enum.find_value(labels, fn label -> internal(label) end)
  end
end
