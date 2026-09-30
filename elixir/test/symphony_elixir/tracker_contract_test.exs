defmodule SymphonyElixir.TrackerContractTest do
  @moduledoc """
  The tracker contract, run against every adapter in `Tracker`'s registry.

  This is the executable form of `docs/ticket-service-spec.md` section 3: one suite that any adapter
  -- including the ticket service's future adapter -- has to pass. The rules live in
  `SymphonyElixir.TrackerContract`; this module runs them once per registered adapter and states, in
  the test that covers it, what each adapter actually does.

  Two kinds of statement appear here, and they are kept apart on purpose:

    * assertions the code satisfies, which freeze the contract;
    * assertions of a *difference* -- `memory` is the one adapter that is expected to disagree in
      place -- which are recorded so the difference is visible rather than hidden behind a branch.

  Nowhere is an adapter changed to make a rule pass. Provider request behaviour (what a 404 or a
  malformed provider payload does) is pinned by each adapter's own test file; this suite only
  asserts what can be shown without a provider: `github_adapter_test.exs:200-238` for GitHub,
  `gitlab_adapter_test.exs`, `jira_adapter_test.exs`, `asana_adapter_test.exs` for the rest.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Asana.Adapter, as: AsanaAdapter
  alias SymphonyElixir.Asana.Client, as: AsanaClient
  alias SymphonyElixir.GitHub.Adapter, as: GitHubAdapter
  alias SymphonyElixir.GitHub.Client, as: GitHubClient
  alias SymphonyElixir.GitLab.Adapter, as: GitLabAdapter
  alias SymphonyElixir.GitLab.Client, as: GitLabClient
  alias SymphonyElixir.Jira.Adapter, as: JiraAdapter
  alias SymphonyElixir.Jira.Client, as: JiraClient
  alias SymphonyElixir.Linear.Adapter, as: LinearAdapter
  alias SymphonyElixir.Tracker.File, as: FileTracker
  alias SymphonyElixir.Tracker.Memory
  alias SymphonyElixir.Tracker.TicketService
  alias SymphonyElixir.TrackerContract, as: Contract

  # The tools each adapter advertises **itself**, pinned by name. This is not the list a run is
  # offered: that is the composed list, `Tracker.bind_agent_tools/0`'s `tool_specs`, which is this
  # list followed by the host's tools (`Tracker.compose_agent_tool_specs/1`) for every kind. Composing
  # it in one adapter is what left a service-backed project with no tools at all, so where the
  # composition happens is itself pinned, in the tests below.
  #
  # `memory` and `ticket_service` advertise none, which is a value: `tracker.ex:161-167` turns the
  # missing callback into an empty list, and `tracker.ex:190-196` answers every tool call such an
  # adapter does not own with a structured failure.
  @advertised_tools %{
    "asana" => ["asana_api"],
    "file" => ["symphony_publish", "ticket_comment", "ticket_state"],
    "github" => ["github_api"],
    "gitlab" => ["gitlab_api"],
    "jira" => ["jira_rest"],
    "linear" => ["linear_graphql"],
    "memory" => [],
    "ticket_service" => []
  }

  # The host's own tools, pinned by name. They belong to no adapter, so they are not in
  # `@advertised_tools`; they are advertised beside whatever the adapter offers, for every kind, and
  # this table is what makes a host tool being dropped (or doubled) a failure rather than a silent
  # change to every kind's list.
  @host_tools ["symphony_gate"]

  # A gate a project could declare. Nothing in this suite runs it: the gate tool is only advertised
  # here, and its execution is pinned in `janitor/gate_tool_test.exs` with an injected runner.
  @gate_command "mix lint && mix test"

  # `tracker.ex:27-36`, pinned as text: a kind added to the registry and not to this list fails
  # `registered_kinds/0 == @registered_kinds` instead of being skipped by the loop below.
  @registered_kinds ~w(asana file github gitlab jira linear memory ticket_service)

  # The four REST clients expose an injected-request-function hook (`github/client.ex:64`,
  # `gitlab/client.ex:66`, `jira/client.ex:71`, `asana/client.ex:77`, and the `_by_ids` twin beside
  # each). Linear has no such hook, which is why its empty-request proof goes through the workflow.
  @rest_clients [AsanaClient, GitHubClient, GitLabClient, JiraClient]
  @rest_hooks [:fetch_issues_by_states_for_test, :fetch_issues_by_ids_for_test]

  # The adapters read their client through these keys (`linear/adapter.ex:49`,
  # `github/adapter.ex:48`, `gitlab/adapter.ex:48`, `jira/adapter.ex:35`, `asana/adapter.ex:35`).
  # They are cleared for the duration of a test so an adapter is measured, not another test's stub.
  @client_module_keys [
    :linear_client_module,
    :github_client_module,
    :gitlab_client_module,
    :jira_client_module,
    :asana_client_module
  ]

  setup do
    saved = Enum.map(@client_module_keys, &{&1, Application.get_env(:symphony_elixir, &1)})
    Enum.each(@client_module_keys, &Application.delete_env(:symphony_elixir, &1))
    on_exit(fn -> restore_client_modules(saved) end)
    :ok
  end

  describe "rule 1: the adapter registry" do
    test "holds exactly the adapters this suite was written for" do
      assert Contract.registered_kinds() == @registered_kinds
    end

    test "every registered kind round-trips to a module implementing the required callbacks" do
      adapters = Contract.registered_adapters()
      assert Enum.map(adapters, &elem(&1, 0)) == @registered_kinds

      Enum.each(adapters, fn {kind, adapter} ->
        assert {:ok, ^adapter} = Tracker.adapter_for_kind(kind)
        assert Contract.assert_registered_adapter(adapter) == :ok
      end)
    end

    test "an unknown kind is refused rather than coerced or matched by another spelling" do
      Contract.assert_unknown_kind_refused("future-tracker")
      Contract.assert_unknown_kind_refused("File")
      Contract.assert_unknown_kind_refused("Linear")
      Contract.assert_unknown_kind_refused("Elixir.SymphonyElixir.Tracker.File")
      Contract.assert_unknown_kind_refused("")
      Contract.assert_unknown_kind_refused(nil)
    end
  end

  describe "rule 2: an empty request is answered by nothing" do
    test "every adapter answers {:ok, []} for empty states and empty ids" do
      # For the five providers this call reads the configured settings and then short-circuits inside
      # the client (`linear/client.ex:111-113`, `github/client.ex:80-82`, and so on); the proofs that
      # it reaches neither the settings nor the wire are the three tests below.
      Enum.each(Contract.registered_adapters(), fn {_kind, adapter} ->
        Contract.assert_empty_answer(adapter.fetch_issues_by_states([]), "#{inspect(adapter)} states")
        Contract.assert_empty_answer(adapter.fetch_issues_by_ids([]), "#{inspect(adapter)} ids")
      end)
    end

    test "the file adapter answers before the path is resolved, even when it does not exist" do
      missing = missing_dir()
      unusable = %{provider: %{"path" => missing}, active_states: ["ready"], terminal_states: ["done"]}

      refute File.exists?(missing)

      # `{"error", ...}` for a non-empty request is asserted inside the rule, so passing it here
      # cannot happen by ignoring the settings (file.ex:103-115, file.ex:136-148).
      assert Contract.assert_empty_request_skips_settings(FileTracker, unusable) == :ok

      # The configured entry points short-circuit ahead of Config as well (file.ex:90, file.ex:123).
      Contract.assert_empty_answer(FileTracker.fetch_issues_by_states([]), "file states")
      Contract.assert_empty_answer(FileTracker.fetch_issues_by_ids([]), "file ids")

      # Asking for something against the same path still fails closed (file.ex:203-209).
      assert {:error, {:file_tracker_path_not_found, ^missing}} =
               FileTracker.fetch_issues_by_states(["ready"], unusable)
    end

    test "the REST clients answer before settings validation and before the wire" do
      # `%{}` cannot satisfy a real request, and the request function fails the test if it is ever
      # called -- so the empty branch provably runs ahead of both (the citations are on @rest_hooks).
      Enum.each(@rest_clients, fn client ->
        Enum.each(@rest_hooks, &Contract.assert_empty_request_skips_settings_and_provider(client, &1))
      end)
    end

    test "linear answers an empty request before it resolves any config" do
      # `linear/client.ex:111-113` (states) and `:127-129` (ids) return before
      # `configured_tracker_for_read/0` at `:556-564`. With no Linear credentials, a non-empty
      # request proves that path does consult them; so {:ok, []} for the empty one means the
      # short-circuit ran first. The credentials are absent on purpose -- nothing else is stubbed.
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_api_token: nil,
        tracker_project_slug: nil
      )

      # Asserted, not assumed: a workflow that failed to load is answered with the previous
      # configuration (`workflow_store.ex:98-105`), and the non-empty assertions below would then be
      # aimed at a tracker that still has credentials.
      assert Config.settings!().tracker.kind == "memory"
      assert Config.settings!().tracker.api_key == nil

      Contract.assert_empty_answer(LinearAdapter.fetch_issues_by_states([]), "linear states")
      Contract.assert_empty_answer(LinearAdapter.fetch_issues_by_ids([]), "linear ids")
      assert {:error, :missing_linear_api_token} = LinearAdapter.fetch_issues_by_states(["Todo"])
      assert {:error, :missing_linear_api_token} = LinearAdapter.fetch_issues_by_ids(["ISSUE-1"])
    end
  end

  describe "rule 3: a malformed record fails rather than disappears" do
    test "the file adapter fails a by-id request when a record in the store cannot be read" do
      dir = tmp_dir()
      write_ticket(dir, "T-1.md", ticket("id: T-1\nstate: ready", "Body\n"))
      # A YAML file is an explicit claim to be a ticket, so an unparseable one is an error for the
      # whole read (file.ex:60-66, file.ex:262-275, file.ex:334-339) -- including for a request that
      # never named it. The requested record is readable; the answer is still an error.
      write_ticket(dir, "broken.yaml", "id: [unclosed\n")

      settings = file_settings(dir)

      assert {:error, {:file_tracker_invalid_yaml, path, _reason}} =
               FileTracker.fetch_issues_by_ids(["T-1"], settings)

      assert Path.basename(path) == "broken.yaml"

      assert {:error, {:file_tracker_invalid_yaml, _, _}} =
               FileTracker.fetch_issues_by_states(["ready"], settings)
    end

    test "an absent record is not an unreadable one" do
      dir = tmp_dir()
      settings = file_settings(dir)

      # Nothing in the store claims to be the requested ticket: {:ok, []} is the honest answer.
      assert {:ok, []} = FileTracker.fetch_issues_by_ids(["NO-SUCH-TICKET"], settings)

      # A `.md` with no front matter in a directory is skipped, not an error (file.ex:319-321), so a
      # note beside the tickets looks absent rather than unreadable. A `.yaml` is the shape that must
      # not look absent, which the test above shows.
      write_ticket(dir, "notes.md", "just notes\n")
      assert {:ok, []} = FileTracker.fetch_issues_by_ids(["notes"], settings)
    end

    test "a requested record that cannot be read is an error, not an absent one" do
      dir = tmp_dir()

      # When the configured path is a single file, that file *is* the requested ticket: there is no
      # directory to skip it in, so a `.md` with no front matter is refused rather than reported
      # absent (`file.ex:203-208`; the skip at `file.ex:319-321` is written for a directory only).
      # The same bytes in a directory look absent instead, which the test above shows -- so what
      # decides is the shape of the request, not the contents of the file.
      path = write_ticket(dir, "SOLO-1.md", "no front matter here\n")

      solo = %{provider: %{"path" => path}, active_states: ["ready"], terminal_states: ["done"]}

      assert {:error, {:file_tracker_missing_front_matter, ^path}} =
               FileTracker.fetch_issues_by_ids(["SOLO-1"], solo)

      assert {:error, {:file_tracker_missing_front_matter, ^path}} =
               FileTracker.fetch_issues_by_states(["ready"], solo)
    end

    test "memory cannot fail at all: a malformed entry is dropped instead" do
      good = %Issue{id: "M-1", identifier: "M-1", state: "ready", dispatchable: true}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [good, %{"id" => "not-an-issue"}])

      # `memory.ex:47-49` filters to `%Issue{}` and the adapter has no error path at all, so
      # "unreadable" and "absent" are the same answer here -- exactly what rule 3 forbids.
      assert {:ok, [^good]} = Memory.fetch_issues_by_ids(["M-1"])
      assert {:ok, []} = Memory.fetch_issues_by_ids(["not-an-issue"])
    end
  end

  describe "rule 4: fields" do
    test "the Issue struct's field names and defaults are frozen" do
      assert Contract.assert_issue_struct() == :ok
    end

    test "the file adapter fills absent collections with [] and absent scalars with nil" do
      dir = tmp_dir()
      write_ticket(dir, "F-1.md", ticket("id: F-1\nstate: ready", "Body one\n"))

      assert {:ok, [issue]} = FileTracker.fetch_issues_by_ids(["F-1"], file_settings(dir))

      assert %Issue{} = issue
      assert issue.id == "F-1"
      assert issue.identifier == "F-1"
      # The title falls back to the identifier and the description to the Markdown body
      # (file.ex:372-373); both are populated, so neither is asserted as nil.
      assert issue.title == "F-1"
      assert issue.description == "Body one\n"
      assert issue.labels == []
      assert issue.blocked_by == []
      assert issue.priority == nil
      assert issue.created_at == nil
      assert issue.updated_at == nil
      assert issue.native_ref == nil
      assert issue.url == nil
      assert issue.branch_name == nil
      assert issue.assignee_id == nil
      assert issue.adapter == nil
      assert issue.model == nil
      assert is_boolean(issue.dispatchable)
    end

    test "the fields the file adapter does populate keep their declared types" do
      dir = tmp_dir()

      front_matter =
        "id: uuid-2\nidentifier: F-2\nstate: ready\npriority: 2\nlabels: [Perf]\n" <>
          "blocked_by: [F-3]\ncreated_at: 2026-01-02T03:04:05Z\nupdated_at: 2026-01-03T04:05:06Z\n" <>
          "branch_name: feature/f-2\nurl: https://example.test/F-2"

      write_ticket(dir, "F-2.md", ticket(front_matter, "Body two\n"))
      write_ticket(dir, "F-3.md", ticket("id: F-3\nstate: done", "Body three\n"))

      assert {:ok, [issue]} = FileTracker.fetch_issues_by_ids(["F-2"], file_settings(dir))

      assert issue.id == "uuid-2"
      assert issue.identifier == "F-2"
      assert is_integer(issue.priority)
      assert is_list(issue.labels)
      assert is_boolean(issue.dispatchable)
      assert %DateTime{} = issue.created_at
      assert %DateTime{} = issue.updated_at
      assert is_binary(issue.branch_name)
      assert is_binary(issue.url)

      # A blocker is the ref shape {id, identifier, state}, never a bare name (file.ex:395-415).
      assert [%{id: "F-3", identifier: "F-3", state: "done"}] = issue.blocked_by
      # F-3 is terminal, so it does not hold F-2 back (file.ex:217-225).
      assert issue.dispatchable
    end
  end

  describe "rule 5: normalisation" do
    test "Issue.routable?/2 normalises labels and treats dispatchable as its own gate" do
      assert Contract.assert_routable_rules() == :ok
    end

    test "the file adapter normalises labels at parse time, both front-matter shapes alike" do
      dir = tmp_dir()
      write_ticket(dir, "L-1.md", ticket(~s(id: L-1\nstate: ready\nlabels: [Perf, "  UX ", perf, ""]), "b\n"))
      write_ticket(dir, "L-2.md", ticket(~s(id: L-2\nstate: ready\nlabels: "Perf, ux ,, PERF"), "b\n"))

      assert {:ok, [first, second]} = FileTracker.fetch_issues_by_ids(["L-1", "L-2"], file_settings(dir))

      # SPEC 1266-1267: trim, downcase, drop blanks, uniq (file.ex:455-479). The stored labels are
      # already normalised, so routable?/2's own normalisation is a second, independent line.
      assert first.labels == ["perf", "ux"]
      assert second.labels == ["perf", "ux"]
    end

    test "the memory adapter normalises nothing and derives no dispatchable gate" do
      issue = %Issue{id: "uuid-1", identifier: "M-1", state: "ready", labels: [" Perf ", "perf"]}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      # `memory.ex:11-31` returns the configured struct verbatim: labels are not trimmed or downcased
      # (file.ex:474-479 does that) and `dispatchable` is not derived (file.ex:217-225 does that).
      assert {:ok, [answered]} = Memory.fetch_issues_by_states([" READY "])
      assert answered.labels == [" Perf ", "perf"]
      assert answered.dispatchable == false
      refute Issue.routable?(answered, [])

      # routable?/2 still matches those labels once the caller sets the gate itself.
      assert Issue.routable?(%{answered | dispatchable: true}, ["perf"])

      # by-ids matches `id` only (memory.ex:28-29), where the file adapter accepts id or identifier
      # (file.ex:145): a caller quoting the identifier cannot ask memory for it.
      assert {:ok, []} = Memory.fetch_issues_by_ids(["M-1"])
      assert {:ok, [^issue]} = Memory.fetch_issues_by_ids(["uuid-1"])
    end

    test "the file adapter can be asked by identifier, not only by id" do
      dir = tmp_dir()
      write_ticket(dir, "T-9.md", ticket("id: uuid-9\nidentifier: T-9\nstate: ready", "b\n"))

      assert {:ok, [issue]} = FileTracker.fetch_issues_by_ids(["T-9"], file_settings(dir))
      assert issue.id == "uuid-9"
      assert {:ok, [^issue]} = FileTracker.fetch_issues_by_ids(["uuid-9"], file_settings(dir))
    end
  end

  describe "rule 6 and 7: the tool surface and secret names through the dispatch" do
    test "memory advertises nothing: no tools, an empty secret list, and a structured refusal" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      binding = Tracker.bind_agent_tools()

      assert binding.adapter == Memory
      # The composed list: memory's own list is empty and this project declares no gate, so nothing is
      # advertised at all (`tracker.ex:73-84`).
      assert binding.tool_specs == []
      # An empty list of secret names is a value, not an exemption (tracker.ex:198-200).
      assert binding.secret_environment_names == []

      result = Tracker.execute_bound_agent_tool(binding, "not_a_memory_tool", %{})

      assert result["success"] == false
      assert Map.has_key?(result, "output")
      assert [%{"type" => "inputText"}] = result["contentItems"]
    end

    test "the file adapter advertises its three janitor tools and has nothing to redact" do
      # `WorkflowStore` keeps the last known good configuration when a reload fails
      # (`workflow_store.ex:98-105`, `:144-156`), and a `file` tracker fails validation without a
      # `provider.path` (`file.ex:180-186`) -- so this workflow is written and reloaded with the
      # result asserted, instead of silently measuring the previous configuration.
      assert :ok = write_file_tracker_workflow!(tmp_dir())

      binding = Tracker.bind_agent_tools()

      assert binding.adapter == FileTracker

      # The composed list, which is what every transport advertises: the adapter's three tools, and
      # nothing appended while the project declares no gate (`tracker.ex:95-98`).
      assert Enum.map(binding.tool_specs, & &1["name"]) ==
               ["symphony_publish", "ticket_comment", "ticket_state"]

      assert binding.secret_environment_names == []
    end

    test "a service-backed project that declares a gate is advertised the gate tool" do
      assert :ok = write_service_gate_workflow!(@gate_command)

      # Asserted, not assumed: a failed reload would leave the previous tracker configured, and this
      # rule would then be measured against the wrong adapter.
      assert Config.settings!().tracker.kind == "ticket_service"
      assert Config.settings!().gate.command == @gate_command

      # This is the fix. `ticket_service` deliberately advertises no tools of its own, and the gate
      # used to be composed by the **file** tracker's adapter -- so a project whose tickets come from
      # the service was offered no tools at all, its agent read the workflow's `gate.command` and ran
      # that command itself in its sandbox, where this project's gate cannot even start.
      assert Contract.assert_composed_tool_list(TicketService, [], @host_tools) == :ok
      assert Contract.assert_bound_tool_list(TicketService, @host_tools) == :ok
    end

    test "a project that declares no gate is advertised nothing extra, for every kind" do
      # The fixture workflow declares no `gate.command` (`schema.ex:579-582`), and composition is
      # asked of the boundary per adapter, so this is a statement about the rule rather than about one
      # configured tracker: for every registered kind, the composed list is exactly the adapter's own.
      assert Config.settings!().gate.command == nil

      Enum.each(Contract.registered_adapters(), fn {kind, adapter} ->
        assert Contract.assert_composed_tool_list(adapter, Map.fetch!(@advertised_tools, kind), []) ==
                 :ok
      end)

      # And at the door, for the kind the fixture configures.
      assert Contract.assert_bound_tool_list(LinearAdapter, Map.fetch!(@advertised_tools, "linear")) ==
               :ok
    end

    test "every adapter answers its own tool surface with the envelope" do
      # Rule 6 for every registered adapter, not only the two the tests above reach through the
      # binding: each adapter is asked for its own specs, each advertised tool is run with arguments
      # every tool is expected to refuse, and the answer has to be the envelope
      # (`success`/`output`/`contentItems`) rather than an exception. The stubs in `tool_opts/1` are
      # what make "refused" provable -- an adapter that reached its transport with one of those
      # arguments fails the test instead of passing quietly.
      Enum.each(Contract.registered_adapters(), fn {kind, adapter} ->
        assert Contract.assert_tool_surface(adapter, tool_opts(kind)) == :ok
        assert advertised_tool_names(adapter) == Map.fetch!(@advertised_tools, kind)
      end)
    end

    test "a bare string is refused by the REST and janitor tools, and accepted by linear" do
      # The one refused argument that is not refused everywhere, recorded rather than smoothed over:
      # `linear_graphql` reads a non-empty string as the query document (`linear/agent_tool.ex:69-74`),
      # so it does reach the provider. The REST tools reject a non-map in `normalize_arguments/1`
      # (`github/agent_tool.ex:72-80`, and the same shape in gitlab, jira and asana), and the janitor
      # tools read a non-map as `%{}` and then refuse the ticket that is missing
      # (`janitor/agent_tool.ex:217-218`, `:211-215`). That is why linear's stub in `tool_opts/1`
      # answers an error where the others fail the test.
      test_pid = self()

      linear_stub = fn query, _variables, _opts ->
        send(test_pid, {:linear_reached, query})
        {:error, :contract_test_stub}
      end

      github_stub = fn _method, _path, _params, _body, _opts ->
        send(test_pid, {:github_reached, :a_request})
        {:error, :contract_test_stub}
      end

      linear =
        LinearAdapter.execute_agent_tool("linear_graphql", "not an object", linear_client: linear_stub)

      assert linear["success"] == false
      assert_received {:linear_reached, "not an object"}

      github =
        GitHubAdapter.execute_agent_tool("github_api", "not an object", github_client: github_stub)

      assert github["success"] == false
      refute_received {:github_reached, _request}
    end

    test "secret_environment_names/1 answers a list for every registered adapter" do
      # Rule 7 at the adapter, not through the binding: the callback is required (`tracker.ex:42`), so
      # every adapter is asked, and an empty list counts as an answer rather than an exemption. A
      # linear workflow is written and its load asserted first, because the file-tracker test above
      # rewrites the shared workflow and an adapter must not be measured against whichever workflow
      # happened to run last.
      assert :ok =
               write_workflow_file!(Workflow.workflow_file_path(),
                 tracker_kind: "linear",
                 tracker_api_token: "token",
                 tracker_project_slug: "project"
               )

      assert Config.settings!().tracker.kind == "linear"
      tracker_settings = Config.settings!().tracker

      Enum.each(Contract.registered_adapters(), fn {_kind, adapter} ->
        assert Contract.assert_secret_environment_names(adapter, tracker_settings) == :ok
      end)

      # An empty list is a value, not an exemption: these two have no credentials to redact
      # (`file.ex:153-154`, `memory.ex:40-41`).
      assert FileTracker.secret_environment_names(tracker_settings) == []
      assert Memory.secret_environment_names(tracker_settings) == []

      # Each provider names the variables it redacts, and the provenance differs: linear answers with
      # the field the configuration derived (`schema.ex:823`, `:849-850`, read at
      # `linear/adapter.ex:46`), while the REST providers build their list in their own client
      # (`github/client.ex:21-31`, `gitlab/client.ex:19-29`, `jira/client.ex:29-34`,
      # `asana/client.ex:35-40`).
      assert "LINEAR_API_KEY" in LinearAdapter.secret_environment_names(tracker_settings)
      assert "GITHUB_TOKEN" in GitHubAdapter.secret_environment_names(tracker_settings)
      assert "GITLAB_PAT" in GitLabAdapter.secret_environment_names(tracker_settings)
      assert "JIRA_API_TOKEN" in JiraAdapter.secret_environment_names(tracker_settings)
      assert "ASANA_PAT" in AsanaAdapter.secret_environment_names(tracker_settings)
    end
  end

  describe "section 3.1 and 3.2 claims the code does not keep" do
    test "by-ids does not answer in the requested order" do
      dir = tmp_dir()
      write_ticket(dir, "T-1.md", ticket("id: T-1\nstate: ready", "b\n"))
      write_ticket(dir, "T-2.md", ticket("id: T-2\nstate: ready", "b\n"))

      # Spec 3.1: "list tickets by identifier | those tickets, in the requested order". The file
      # adapter sorts by {identifier, id} (file.ex:525) and memory keeps the configured list's order
      # (memory.ex:27-30), so neither preserves it.
      assert {:ok, issues} = FileTracker.fetch_issues_by_ids(["T-2", "T-1"], file_settings(dir))
      assert Enum.map(issues, & &1.id) == ["T-1", "T-2"]

      first = %Issue{id: "A", identifier: "A", state: "ready"}
      second = %Issue{id: "B", identifier: "B", state: "ready"}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [first, second])

      assert {:ok, answered} = Memory.fetch_issues_by_ids(["B", "A"])
      assert Enum.map(answered, & &1.id) == ["A", "B"]
    end

    test "an unrecognised state is answered with [], not refused" do
      # Spec 3.2: "Fail closed on unknown state | A state the service does not recognise is refused,
      # not coerced." The read path does not do that: an unknown name is simply not matched
      # (file.ex:106-115, memory.ex:12-21) or produces no provider query at all
      # (github/client.ex:364-374, gitlab/client.ex:385-395), and the answer is an empty list.
      dir = tmp_dir()
      write_ticket(dir, "T-1.md", ticket("id: T-1\nstate: ready", "b\n"))

      assert {:ok, []} = FileTracker.fetch_issues_by_states(["nonsense"], file_settings(dir))
      assert {:ok, []} = Memory.fetch_issues_by_states(["nonsense"])

      Contract.assert_empty_answer(
        GitHubClient.fetch_issues_by_states_for_test(["nonsense"], %{}, &refuse_request/5),
        "github with an unrecognised state"
      )
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp restore_client_modules(saved) do
    Enum.each(saved, fn
      {key, nil} -> Application.delete_env(:symphony_elixir, key)
      {key, module} -> Application.put_env(:symphony_elixir, key, module)
    end)
  end

  defp tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "symphony-tracker-contract-#{System.unique_integer([:positive])}"
      )

    dir = Path.expand(dir)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp missing_dir do
    Path.join(System.tmp_dir!(), "symphony-tracker-contract-missing-#{System.unique_integer([:positive])}")
    |> Path.expand()
  end

  defp file_settings(dir) do
    %{provider: %{"path" => dir}, active_states: ["ready"], terminal_states: ["done"]}
  end

  defp write_ticket(dir, name, contents) do
    path = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  defp ticket(front_matter, body), do: "---\n" <> front_matter <> "\n---\n" <> body

  defp refuse_request(_method, _path, _params, _body, _settings) do
    flunk("an unrecognised state must be answered without a provider request")
  end

  # ── Tools ───────────────────────────────────────────────────────────────────

  # The transport each adapter's tools take from their options (`linear/agent_tool.ex:57`,
  # `github/agent_tool.ex:58`, `gitlab/agent_tool.ex:58`, `jira/agent_tool.ex:58`,
  # `asana/agent_tool.ex:58`, and `janitor/agent_tool.ex:159`, `:183`, `:209` for the host-side
  # writers). A stub that fails the test is passed wherever none of the refused arguments may reach
  # the provider or the host.
  #
  # `linear` is the one adapter without such a stub, and the difference test above says why: its tool
  # accepts a bare string as the query, so one of the refused arguments is not refused and does reach
  # the transport. There the stub answers an error instead, so the envelope can still be asserted
  # while what linear does with that argument stays stated in that test rather than hidden here.
  defp tool_opts("file") do
    [
      publish: fn _ticket -> flunk("symphony_publish reached the host") end,
      comment: fn _ticket, _body -> flunk("ticket_comment reached the host") end,
      set_state: fn _ticket, _state -> flunk("ticket_state reached the host") end
    ]
  end

  defp tool_opts("linear") do
    [linear_client: fn _query, _variables, _opts -> {:error, :contract_test_stub} end]
  end

  defp tool_opts("github"), do: [github_client: refusing_rest_request("github")]
  defp tool_opts("gitlab"), do: [gitlab_client: refusing_rest_request("gitlab")]
  defp tool_opts("jira"), do: [jira_client: refusing_rest_request("jira")]
  defp tool_opts("asana"), do: [asana_client: refusing_rest_request("asana")]
  defp tool_opts("memory"), do: []
  # No tools are advertised, so there is nothing to stub: the dispatch's unsupported-tool path is what runs.
  defp tool_opts("ticket_service"), do: []

  defp refusing_rest_request(kind) do
    fn _method, _path, _params, _body, _opts ->
      flunk("#{kind} reached the provider with an argument it must refuse")
    end
  end

  defp advertised_tool_names(adapter) do
    if function_exported?(adapter, :agent_tool_specs, 0) do
      Enum.map(adapter.agent_tool_specs(), & &1["name"])
    else
      []
    end
  end

  # A workflow that satisfies `SymphonyElixir.Tracker.File.validate_config/1`: a `provider.path` that
  # exists and a non-empty `active_states`. The reload result is returned, so a failed load is a test
  # failure rather than the previous configuration being measured in its place.
  defp write_file_tracker_workflow!(dir) do
    contents = """
    ---
    tracker:
      kind: file
      provider:
        path: '#{dir}'
      active_states:
        - ready
      terminal_states:
        - done
    codex:
      command: codex app-server
    ---

    Tracker contract test workflow.
    """

    File.write!(Workflow.workflow_file_path(), contents)
    WorkflowStore.force_reload()
  end

  # A service-backed project that declares a gate. `TicketService.validate_config/1` checks only that
  # `provider.url` is declared and probes nothing, so this test opens no socket; the gate tool is
  # advertised here, never run (its execution is pinned in `janitor/gate_tool_test.exs`).
  defp write_service_gate_workflow!(command) do
    contents = """
    ---
    tracker:
      kind: ticket_service
      provider:
        url: 'http://127.0.0.1:4020'
      active_states:
        - ready
      terminal_states:
        - done
    gate:
      command: '#{command}'
    codex:
      command: codex app-server
    ---

    Tracker contract test workflow: a service-backed project that declares a gate.
    """

    File.write!(Workflow.workflow_file_path(), contents)
    WorkflowStore.force_reload()
  end
end
