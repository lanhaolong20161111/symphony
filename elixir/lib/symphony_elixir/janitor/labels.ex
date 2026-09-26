defmodule SymphonyElixir.Janitor.Labels do
  @moduledoc """
  Translates between the ticket's internal `state` and the GitHub label a person reads.

  The state vocabulary inside the files is machine-facing (`ready`, `in-review`, ...). The labels
  are the one part of this system a non-technical person picks from a menu, so they are written the
  way that person would say it. Keeping the two vocabularies separate is what lets the state machine
  stay exact while the human surface stays plain.
  """

  @pairs [
    {"ready", "等 agent 做"},
    {"in-progress", "正在做"},
    {"in-review", "等你看"},
    {"paused", "暂停"},
    {"done", "已完成"},
    {"cancelled", "已取消"}
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
  """
  @spec state_from_labels([String.t()]) :: String.t() | nil
  def state_from_labels(labels) do
    Enum.find_value(labels, fn label -> internal(label) end)
  end
end
