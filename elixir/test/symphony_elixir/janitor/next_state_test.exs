defmodule SymphonyElixir.Janitor.NextStateTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Janitor

  # `next_state/1` is the whole precedence rule for "what should this ticket's state be, given what
  # its issue says". It is pure precisely so that the two failures measured in the field can be
  # pinned here instead of being rediscovered against a live issue.

  test "a closed issue beats any label" do
    # The measured failure: the person closed the issue, the janitor wrote `done`, and then on the
    # very next line read the stale label straight back and returned the ticket to `ready`. It did
    # that every round, so the mirror never settled and the ticket never finished.
    assert Janitor.next_state(%{closed: true, claimed: "ready", last: nil, current: "ready"}) == "done"

    assert Janitor.next_state(%{
             closed: true,
             claimed: "in-review",
             last: "in-review",
             current: "in-review"
           }) == "done"
  end

  test "a closed issue leaves an already-terminal ticket alone" do
    assert Janitor.next_state(%{closed: true, claimed: nil, last: nil, current: "done"}) == :keep
    assert Janitor.next_state(%{closed: true, claimed: nil, last: nil, current: "cancelled"}) == :keep
  end

  test "the state we last pushed is not an instruction" do
    # Both sides write labels, so without this rule the ticket and the issue overwrite each other
    # every thirty seconds. Note it compares internal states: comparing an internal state with the
    # label a person sees is never equal, which is the same bug wearing a different hat.
    assert Janitor.next_state(%{closed: false, claimed: "ready", last: "ready", current: "ready"}) ==
             :keep
  end

  test "a label matching the ticket's own state is not an instruction" do
    assert Janitor.next_state(%{closed: false, claimed: "in-progress", last: nil, current: "in-progress"}) ==
             :keep
  end

  test "a label differing from both is a person's instruction" do
    assert Janitor.next_state(%{closed: false, claimed: "paused", last: "ready", current: "ready"}) ==
             "paused"

    assert Janitor.next_state(%{closed: false, claimed: "ready", last: nil, current: "done"}) ==
             "ready"
  end

  test "no label at all changes nothing" do
    assert Janitor.next_state(%{closed: false, claimed: nil, last: "ready", current: "ready"}) ==
             :keep
  end

  test "the agent advancing the ticket is not mistaken for a person's instruction" do
    # The agent writes `in-review` into the ticket while the issue still carries the `ready` label
    # the janitor itself put there; that must not be read back as "the person says ready".
    assert Janitor.next_state(%{closed: false, claimed: "ready", last: "ready", current: "in-review"}) ==
             :keep
  end
end
