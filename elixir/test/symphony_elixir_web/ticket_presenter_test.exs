defmodule SymphonyElixirWeb.TicketPresenterTest do
  # async: false -- the file-tracker cases write real tickets in a temp queue and move the global
  # workflow file path, exactly as the page tests do.
  use ExUnit.Case, async: false

  alias SymphonyElixir.Workflow
  alias SymphonyElixirWeb.TicketPresenter

  @service_url "http://127.0.0.1:4997"

  setup do
    previous = Workflow.workflow_file_path()
    on_exit(fn -> Workflow.set_workflow_file_path(previous) end)

    root = Path.join(System.tmp_dir!(), "ticket-presenter-#{System.unique_integer([:positive])}")
    tickets = Path.join(root, "tickets")
    File.mkdir_p!(tickets)
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, root: root, tickets: tickets}
  end

  # The seam's two kinds. A ticket page never names one: it asks for a writer and submits through it.
  describe "writer/1: which tracker writes" do
    test "a file deployment writes through the host's writer, to its own queue", %{root: root, tickets: tickets} do
      path = write_ticket!(tickets, "SYM-7", ticket_text("ready"))
      write_workflow!(root, file_tracker(tickets))
      before = File.read!(path)

      assert {:ok, write} = TicketPresenter.writer(ref: "SYM-7")

      assert {:ok, %{ticket: "SYM-7", state: "in-progress"}} = write.(:state, "in-progress", [])
      assert File.read!(path) == String.replace(before, "state: ready", "state: in-progress", global: false)

      assert {:ok, %{ticket: "SYM-7", comment: %{author: "operator"}}} =
               write.(:comment, "Please also cover the Windows path.", author: "operator")

      assert File.read!(path) =~ "- **operator** ("
    end

    test "the file writer refuses the same things the host does, unchanged", %{root: root, tickets: tickets} do
      write_ticket!(tickets, "SYM-7", ticket_text("ready"))
      write_workflow!(root, file_tracker(tickets))

      {:ok, write} = TicketPresenter.writer(ref: "SYM-9")

      # The host's own refusal, with its own atom: this is the vocabulary the page renders, and the seam
      # does not paraphrase it.
      assert {:error, {:no_such_ticket, "SYM-9"}} = write.(:state, "done", [])
    end

    test "a service deployment writes through the tracker boundary, over the service's API", %{root: root} do
      write_workflow!(root, service_tracker())

      {:ok, agent} = Agent.start_link(fn -> [] end)

      client = fn method, url, payload ->
        Agent.update(agent, &(&1 ++ [%{method: method, url: url, payload: payload}]))
        {:ok, %{status: 200, body: service_answer(method)}}
      end

      assert {:ok, write} = TicketPresenter.writer(ref: "SYM-7", client: client)

      assert {:ok, %{"ticket" => "SYM-7", "state" => "done"}} = write.(:state, "done", [])

      assert {:ok, %{"ticket" => "SYM-7", "comment" => %{"author" => "operator"}}} =
               write.(:comment, "hello", author: "operator")

      assert Agent.get(agent, & &1) == [
               %{method: :patch, url: "#{@service_url}/tickets/SYM-7", payload: %{"state" => "done"}},
               %{
                 method: :post,
                 url: "#{@service_url}/tickets/SYM-7/comments",
                 payload: %{"author" => "operator", "body" => "hello"}
               }
             ]
    end

    test "a tracker kind this console cannot write answers a reason, not a raise", %{root: root} do
      # `memory` is a real, registered kind that implements only the read callbacks -- the shape every
      # read-only tracker has. Asking for a writer succeeds; the write itself is the refusal.
      write_workflow!(root, other_tracker("memory"))

      assert {:ok, write} = TicketPresenter.writer(ref: "SYM-7")

      assert {:error, {:ticket_kind_not_writable, "memory"}} = write.(:state, "done", [])

      assert {:error, {:ticket_kind_not_writable, "memory"}} =
               write.(:comment, "hello", author: "operator")

      # And the page has a sentence for it, so the reason renders rather than an inspected tuple.
      assert TicketPresenter.describe({:ticket_kind_not_writable, "memory"}) =~
               "configured as \"memory\""

      assert TicketPresenter.describe({:ticket_kind_not_writable, "memory"}) =~
               "ticket_kind_not_writable"
    end

    test "the boundary's own refusal is rendered as the same sentence", %{root: root} do
      # What `SymphonyElixir.Tracker.write_state/3` answers for an adapter that does not implement the
      # callback. A page reaches it the same way it reaches the writer's own refusal, and it reads the
      # same, because both are "this tracker cannot write".
      write_workflow!(root, other_tracker("memory"))

      assert TicketPresenter.describe({:tracker_write_unsupported, "memory", :write_state}) ==
               TicketPresenter.describe({:ticket_kind_not_writable, "memory"})
    end

    test "a named project that declares no file queue has nowhere to write", %{root: root, tickets: tickets} do
      write_ticket!(tickets, "SYM-7", ticket_text("ready"))
      write_workflow!(root, file_tracker(tickets))

      # A registry with one project whose workflow declares a file tracker and no provider path: there
      # is no queue in it a write could land in, and this instance's own queue is not a substitute.
      registry = Path.join(root, "projects")
      File.mkdir_p!(registry)

      File.write!(Path.join(registry, "queue-less.md"), """
      ---
      tracker:
        kind: file
        active_states: [ready]
        terminal_states: [done]
      ---

      No queue declared.
      """)

      previous = Application.get_env(:symphony_elixir, :projects_dir)
      Application.put_env(:symphony_elixir, :projects_dir, registry)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:symphony_elixir, :projects_dir, previous),
          else: Application.delete_env(:symphony_elixir, :projects_dir)
      end)

      assert {:error, {:no_writable_queue, "queue-less"}} =
               TicketPresenter.writer(project: "queue-less")

      assert TicketPresenter.describe({:no_writable_queue, "queue-less"}) =~ "no_writable_queue"

      # This instance's own ticket is untouched: the write had nowhere to go and wrote nowhere.
      assert File.read!(Path.join(tickets, "SYM-7.md")) =~ "state: ready"
    end
  end

  # ---- fixtures -------------------------------------------------------------------------------

  defp ticket_text(state) do
    "---\nid: SYM-7\ntitle: \"A ticket\"\nstate: #{state}\n---\nBody text.\n"
  end

  defp write_ticket!(dir, id, text) do
    path = Path.join(dir, "#{id}.md")
    File.write!(path, text)
    path
  end

  defp write_workflow!(root, tracker) do
    path = Path.join(root, "WORKFLOW.md")

    File.write!(path, """
    ---
    #{tracker}---

    Test prompt.
    """)

    Workflow.set_workflow_file_path(path)
    :ok
  end

  defp file_tracker(tickets) do
    """
    tracker:
      kind: file
      provider:
        path: "#{slash(tickets)}"
      active_states: [ready, in-progress]
      terminal_states: [done, cancelled]
    """
  end

  defp service_tracker do
    """
    tracker:
      kind: ticket_service
      provider:
        url: "#{@service_url}"
      active_states: [ready, in-progress]
      terminal_states: [done, cancelled]
    """
  end

  defp other_tracker(kind) do
    """
    tracker:
      kind: #{kind}
      active_states: [ready]
      terminal_states: [done]
    """
  end

  defp service_answer(:patch) do
    %{"id" => "7", "identifier" => "SYM-7", "state" => %{"name" => "done", "display_name" => "done"}}
  end

  defp service_answer(_post), do: %{"id" => 11, "author" => "operator", "body" => "hello"}

  defp slash(path), do: String.replace(path, "\\", "/")
end
