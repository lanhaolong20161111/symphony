defmodule SymphonyElixirWeb.ControlTicketLandTest do
  # async: false -- every test moves the workflow file path, points a queue at a temp directory and
  # starts the endpoint under test.
  use ExUnit.Case, async: false

  alias SymphonyElixir.Workflow

  # Before `import Phoenix.ConnTest`: its helpers resolve the endpoint from this attribute.
  @endpoint SymphonyElixirWeb.Endpoint

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @pull_request "https://github.com/me/repo/pull/7"
  @branch "symphony/SYM-7"

  # Bytes that are not valid UTF-8, spelled in ASCII so this file stays ASCII: `0xE3 0x80` opens a
  # three-byte sequence and `0x3F` is not its third byte. Same fixture as the other action test's.
  @damaged_tail <<0xE3, 0x80, 0x3F, 0x0A>>

  # The body deliberately repeats the front matter's `state: ready` line: the landing's state write is
  # compared against a single-occurrence replacement, so a writer that replaced every match cannot pass.
  @body "Ship the picker and keep every other byte.\n\n" <>
          "## Notes\n\nstate: ready is what the front matter said; this line must not be the one that changes.\n"

  # The four verdicts that stop a landing, with the skill's own name for each code and one of its own
  # lines -- the page has to render the reason, not a paraphrase of it.
  @refusals [
    %{code: 5, name: "conflict", message: "PR has merge conflicts."},
    %{code: 2, name: "feedback", message: "Review comments detected. Address before merge."},
    %{code: 4, name: "head moved", message: "PR head updated"},
    %{code: 3, name: "checks", message: "Checks failed:"}
  ]

  setup do
    previous = Workflow.workflow_file_path()
    on_exit(fn -> Workflow.set_workflow_file_path(previous) end)

    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    root = Path.join(System.tmp_dir!(), "control-ticket-land-#{System.unique_integer([:positive])}")
    tickets = Path.join(root, "tickets")
    File.mkdir_p!(tickets)
    on_exit(fn -> File.rm_rf(root) end)

    path = write_ticket!(tickets, "SYM-7", ticket_text())
    write_workflow!(root, tickets)
    start_test_endpoint()

    {:ok, tickets: tickets, path: path, root: root}
  end

  test "the land action is offered on a ticket that records a pull request and a branch, and runs nothing until it is submitted",
       %{path: path} do
    before = File.read!(path)
    {view, html, calls} = land_view({:ok, %{number: 7, url: @pull_request}})

    # Offered, and it says where the pull request comes from: the ticket's own record, not a search.
    assert html =~ ~s(phx-submit="land")
    assert html =~ "Land pull request"
    assert html =~ @pull_request
    assert html =~ "branch_name"

    # Mounting, rendering and refreshing run no operation and write nothing.
    assert land_calls(calls) == []
    assert render(view) |> then(&(&1 =~ "SYM-7"))
    view |> element("button[phx-click=refresh]") |> render_click()

    assert land_calls(calls) == []
    assert File.read!(path) == before
  end

  test "a verdict of ok merges, moves the ticket to the workflow's terminal state and records the outcome",
       %{path: path} do
    before = File.read!(path)
    {view, _html, calls} = land_view({:ok, %{number: 7, url: @pull_request}})

    html = view |> form("form[phx-submit=land]") |> render_submit()
    after_text = File.read!(path)

    # The operation was handed exactly what the ticket records -- and the ticket is the only thing it
    # was told, so no pull request could have been invented or searched for.
    assert land_calls(calls) == [%{pr_url: @pull_request, branch: @branch}]

    # The state: the workflow's own terminal state, and every other byte the byte it was -- including
    # the body line that repeats `state: ready`, which a replace-every-match writer would have changed.
    assert String.starts_with?(after_text, String.replace(before, "state: ready", "state: done", global: false))
    assert after_text =~ "state: ready is what the front matter said"

    # And the trace the ticket has to carry: who asked, the verdict, and the merge's result.
    assert after_text =~ "## Discussion"
    assert after_text =~ "- **operator** ("
    assert after_text =~ "id=local-1"
    assert after_text =~ "operator asked to land pull request 7 (#{@pull_request})"
    assert after_text =~ "Land verdict: ok (exit 0)"
    assert after_text =~ "squash-merged with the branch deleted"
    assert after_text =~ "This ticket was moved to done."

    # The page: the landing is announced and there is no refusal on it, and the new state is shown
    # without a manual refresh.
    assert html =~ "The pull request was landed"
    assert html =~ "Pull request 7 was squash-merged"
    refute html =~ "That change was not written"
    assert render(view) =~ "done"
  end

  for refusal <- @refusals do
    test "a #{refusal.name} verdict renders the skill's own reason and leaves the ticket byte-identical",
         %{path: path} do
      refusal = unquote(Macro.escape(refusal))
      before = File.read!(path)
      {view, html, calls} = land_view({:refused, refusal.code, [refusal.message]})

      refute html =~ "The pull request was landed"

      html = view |> form("form[phx-submit=land]") |> render_submit()

      # The skill's number, the skill's name for it, and the skill's own line -- not a paraphrase.
      assert html =~ "The land verdict is #{refusal.name} (exit #{refusal.code})"
      assert html =~ refusal.message
      assert html =~ "nothing was merged"

      # The operation was asked once, with the ticket's own two facts, and a refusal writes nothing at
      # all: no state, no comment, not one byte different.
      assert land_calls(calls) == [%{pr_url: @pull_request, branch: @branch}]
      assert File.read!(path) == before
      refute File.read!(path) =~ "## Discussion"
      refute html =~ "The pull request was landed"
    end
  end

  test "a merge that succeeded but could not be recorded is reported as both, and the ticket is left as it was",
       %{path: path} do
    {view, _html, calls} = land_view({:ok, %{number: 7, url: @pull_request}})

    # The ticket is damaged *after* the page has read it. The merge still happens -- the pull request
    # is not the ticket -- and it is the recording of it that fails, which is the one case the page has
    # to report in two halves rather than as a failure of the whole action.
    damaged = "---\nid: SYM-7\nstate: ready\n---\n" <> "body\n" <> @damaged_tail
    File.write!(path, damaged)
    refute String.valid?(damaged)

    html = view |> form("form[phx-submit=land]") |> render_submit()

    # Both halves: the merge is announced, and the ticket does not say so.
    assert html =~ "The pull request was landed"
    assert html =~ "Pull request 7 was squash-merged"
    assert html =~ "That change was not written"
    assert html =~ "was not moved to done"
    assert html =~ "ticket_not_utf8"

    # A damaged ticket is not rewritten, so the merge did not touch it either.
    assert File.read!(path) == damaged

    # And the operation was still asked exactly once: the failure is the recording's, not the land's.
    assert land_calls(calls) == [%{pr_url: @pull_request, branch: @branch}]
  end

  test "a ticket that records no pull request is not offered the action, says why, and refuses a crafted submit",
       %{tickets: tickets, path: path} do
    no_link = write_ticket!(tickets, "SYM-8", ticket_text(%{id: "SYM-8", links: "", branch: ""}))
    before = File.read!(no_link)
    {fake, calls} = land_fake({:ok, %{number: 7, url: @pull_request}})
    put_endpoint_config(ticket_land: fake)

    {:ok, view, html} = live(build_conn(), "/control/tickets/SYM-8")

    # Not offered, and the page says which half of the record is missing rather than looking for one.
    refute html =~ ~s(phx-submit="land")
    assert html =~ "records no pull request"
    assert html =~ "nothing was searched for"

    # A submit that arrives anyway is refused the same way, and the file is untouched.
    refused = render_submit(view, "land", %{})

    assert refused =~ "That change was not written"
    assert refused =~ "records no pull request"
    assert File.read!(no_link) == before
    assert land_calls(calls) == []

    # The other ticket's own file -- which does record a pull request -- is untouched too.
    assert File.read!(path) == ticket_text()
  end

  test "a ticket that records a pull request but no branch refuses instead of guessing which branch it is",
       %{tickets: tickets} do
    no_branch = write_ticket!(tickets, "SYM-9", ticket_text(%{id: "SYM-9", branch: ""}))
    before = File.read!(no_branch)
    {fake, calls} = land_fake({:ok, %{number: 7, url: @pull_request}})
    put_endpoint_config(ticket_land: fake)

    {:ok, view, html} = live(build_conn(), "/control/tickets/SYM-9")

    refute html =~ ~s(phx-submit="land")
    assert html =~ "records no branch"

    refused = render_submit(view, "land", %{})

    assert refused =~ "records no branch"
    assert File.read!(no_branch) == before
    assert land_calls(calls) == []
  end

  # Mounts the ticket page with this test's land operation in the endpoint config, so the page is the
  # only thing under test and not one `gh` call is ever made. The agent records what the operation was
  # handed, which is how "no pull request was invented" is checked rather than asserted.
  defp land_view(reply) do
    {fake, calls} = land_fake(reply)
    put_endpoint_config(ticket_land: fake)

    {:ok, view, html} = live(build_conn(), "/control/tickets/SYM-7")
    {view, html, calls}
  end

  defp land_fake(reply) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    fake = fn pr_url, branch ->
      Agent.update(agent, &(&1 ++ [%{pr_url: pr_url, branch: branch}]))
      reply
    end

    {fake, agent}
  end

  defp land_calls(agent), do: Agent.get(agent, & &1)

  defp put_endpoint_config(extra) do
    config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(extra)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, config)
  end

  defp ticket_text(overrides \\ %{}) do
    id = Map.get(overrides, :id, "SYM-7")
    links = Map.get(overrides, :links, ~s(links: [{url: "#{@pull_request}", title: "PR #7", kind: pr}]))
    branch = Map.get(overrides, :branch, @branch)

    # The body starts directly after the closing delimiter, which is the shape the host's round trip
    # preserves byte for byte: `Ticket.split/1` owns the newlines that follow `---`, so a fixture with a
    # blank line there would be measuring that delimiter instead of the one-key write these tests are
    # about. An empty section is dropped rather than left as a dangling key.
    [
      "---\n",
      "id: #{id}\n",
      "issue: 7\n",
      ~s(title: "Cache the git roots lookup"\n),
      "state: ready\n",
      "labels: [perf, windows]\n",
      "priority: 2\n",
      "assignee_id: lhl20\n",
      present("branch_name: ", branch),
      present("", links),
      "---\n",
      @body
    ]
    |> Enum.join()
  end

  defp present(_prefix, ""), do: ""
  defp present(prefix, value), do: prefix <> value <> "\n"

  defp write_ticket!(dir, id, text) do
    path = Path.join(dir, "#{id}.md")
    File.write!(path, text)
    path
  end

  # The workflow's own terminal state is `done`, and its first entry is the one a landing takes, so a
  # landing that moved the ticket to `cancelled` (or to an invented state) cannot pass.
  defp write_workflow!(root, tickets) do
    path = Path.join(root, "WORKFLOW.md")

    File.write!(path, """
    ---
    tracker:
      kind: file
      provider:
        path: "#{slash(tickets)}"
      active_states: [ready, in-progress]
      terminal_states: [done, cancelled]
    janitor:
      tickets_path: "#{slash(tickets)}"
    ---

    Test prompt.
    """)

    Workflow.set_workflow_file_path(path)
    :ok
  end

  defp slash(path), do: String.replace(path, "\\", "/")

  defp start_test_endpoint do
    config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end
end
