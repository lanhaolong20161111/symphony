defmodule SymphonyElixir.TrackerContract do
  @moduledoc """
  The tracker contract, as assertions any registered adapter can be run against.

  Every rule here was re-derived from the code that implements it, because
  `docs/ticket-service-spec.md` section 3 warns about itself: its `[carried]` claims were never
  verified when it was written. The `path:line` that establishes each rule sits in the comment
  beside it, so the specification's carried claims can be re-derived from this file alone.

  The rules live here; what each adapter actually does about them -- including the adapters that
  genuinely differ -- is stated in the test that calls these functions, not hidden in a branch
  here. Nothing in this module changes an adapter, and no rule is relaxed to make one pass.
  """

  import ExUnit.Assertions

  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.Issue

  # The registry is a private module attribute (`tracker.ex:13-21`), and the only public door,
  # `adapter_for_kind/1`, needs a kind to open it. So the kinds are read from the source: a kind
  # added to the registry and not to this suite makes `registered_kinds/0` change under the test
  # that pins it, instead of being silently skipped -- which is the whole point of a contract that a
  # new adapter must pass.
  @registry_source Path.expand("../../lib/symphony_elixir/tracker.ex", __DIR__)
  @registry_entry ~r/"([a-z_]+)"\s*=>/

  # `tracker.ex:23-28` declares three required callbacks. `agent_tool_specs/0`,
  # `execute_agent_tool/3` and `validate_config/1` are optional there (`tracker.ex:30-32`), so an
  # adapter need not export them -- but one that advertises tools must be able to run them.
  @required_callbacks [
    fetch_issues_by_states: 1,
    fetch_issues_by_ids: 1,
    secret_environment_names: 1
  ]

  # `issue.ex:12-30`: the frozen field set. Sorted before comparison, because the struct's order is
  # not part of the contract and the source's order is not alphabetical.
  @issue_fields ~w(adapter assignee_id blocked_by branch_name created_at description dispatchable id
                   identifier labels model native_ref priority state title updated_at url)a

  # `issue.ex:23-24`: the two collections default to `[]`, never `nil`. Every other field defaults
  # to `nil`, except `dispatchable`, which defaults to `false` (`issue.ex:25`).
  @collection_fields ~w(blocked_by labels)a
  @scalar_fields ~w(assignee_id branch_name created_at description id identifier model native_ref
                     priority state title updated_at url adapter)a

  @envelope_keys ~w(success output contentItems)
  @tool_keys ~w(name description inputSchema)

  # Arguments no advertised tool may act on: every key a tool reads, carrying a type it refuses.
  # They let the envelope be asserted without any of them reaching a provider or the filesystem.
  @refused_arguments [
    %{},
    "not an object",
    %{
      "ticket" => 42,
      "body" => [],
      "state" => %{},
      "method" => 1,
      "path" => 2,
      "query" => %{},
      "variables" => []
    }
  ]

  @doc """
  The kinds in `Tracker`'s adapter registry, read from the registry itself.
  """
  @spec registered_kinds() :: [String.t()]
  def registered_kinds do
    @registry_source
    |> File.read!()
    |> registry_block()
    |> then(&Regex.scan(@registry_entry, &1))
    |> Enum.map(fn [_, kind] -> kind end)
    |> Enum.sort()
  end

  @doc """
  Every registered kind paired with the adapter `adapter_for_kind/1` answers for it.
  """
  @spec registered_adapters() :: [{String.t(), module()}]
  def registered_adapters do
    Enum.map(registered_kinds(), &{&1, registered_adapter(&1)})
  end

  @doc """
  Rule 1: the kind round-trips through `adapter_for_kind/1` (`tracker.ex:94-100`).
  """
  @spec registered_adapter(String.t()) :: module()
  def registered_adapter(kind) do
    assert {:ok, adapter} = Tracker.adapter_for_kind(kind)
    adapter
  end

  @doc """
  Rule 1: a registered module implements the behaviour and its required callbacks.

  The required three are `tracker.ex:23-24` and `tracker.ex:27`; `module_info(:attributes)` is read
  for the `@behaviour` declaration so a module that merely exports the names still fails.
  """
  @spec assert_registered_adapter(module()) :: :ok
  def assert_registered_adapter(adapter) do
    assert Code.ensure_loaded?(adapter), "#{inspect(adapter)} is registered but cannot be loaded"

    assert Tracker in behaviours(adapter),
           "#{inspect(adapter)} does not declare @behaviour SymphonyElixir.Tracker"

    Enum.each(@required_callbacks, &assert_callback(adapter, &1))

    assert function_exported?(adapter, :agent_tool_specs, 0) ==
             function_exported?(adapter, :execute_agent_tool, 3),
           "#{inspect(adapter)} advertises agent tools and execute_agent_tool/3 must come as a pair " <>
             "(tracker.ex:25-26): specs exported=#{function_exported?(adapter, :agent_tool_specs, 0)} " <>
             "execute exported=#{function_exported?(adapter, :execute_agent_tool, 3)}"

    :ok
  end

  @doc """
  Rule 1: an unregistered kind is refused, not coerced and not matched by another spelling.
  """
  @spec assert_unknown_kind_refused(term()) :: :ok
  def assert_unknown_kind_refused(kind) do
    assert {:error, {:unsupported_tracker_kind, ^kind}} = Tracker.adapter_for_kind(kind),
           "adapter_for_kind/1 must refuse #{inspect(kind)} with {:unsupported_tracker_kind, _}"

    :ok
  end

  @doc """
  Rule 2: an empty request is answered with `{:ok, []}`.

  `fetch_issues_by_states([])` and `fetch_issues_by_ids([])` return `{:ok, []}` and no work is done
  (`file.ex:90`, `file.ex:104`, `file.ex:123`, `file.ex:137`, `memory.ex:11-31`,
  `linear/client.ex:111-113`, `linear/client.ex:127-129`, `github/client.ex:80-82`,
  `github/client.ex:94-96`, `gitlab/client.ex:82-84`, `gitlab/client.ex:126-127`,
  `jira/client.ex:84`, `jira/client.ex:121`, `asana/client.ex:90`, `asana/client.ex:127`).
  """
  @spec assert_empty_answer(term(), String.t()) :: :ok
  def assert_empty_answer(result, what) do
    assert result == {:ok, []},
           "#{what} must answer {:ok, []} for an empty request, got #{inspect(result)}"

    :ok
  end

  @doc """
  Rule 2, at its strongest for an adapter that resolves settings first: the empty call is answered
  ahead of those settings.

  `unusable_settings` must fail a non-empty request -- that is asserted first, so this rule cannot
  pass by accident on an adapter that ignores its settings entirely. The file adapter is the one
  adapter with a settings-taking entry point (`file.ex:103-104`, `file.ex:136-137`).
  """
  @spec assert_empty_request_skips_settings(module(), map()) :: :ok
  def assert_empty_request_skips_settings(adapter, unusable_settings) do
    assert match?({:error, _}, adapter.fetch_issues_by_states(["ready"], unusable_settings)),
           "the settings used to prove rule 2 must fail a non-empty request; they did not"

    assert_empty_answer(
      adapter.fetch_issues_by_states([], unusable_settings),
      "#{inspect(adapter)}.fetch_issues_by_states([], unusable_settings)"
    )

    assert_empty_answer(
      adapter.fetch_issues_by_ids([], unusable_settings),
      "#{inspect(adapter)}.fetch_issues_by_ids([], unusable_settings)"
    )
  end

  @doc """
  Rule 2 for the provider clients: an empty request reaches neither the settings nor the wire.

  The `*_for_test` hooks take the request function as an argument, so passing settings that could
  not satisfy a real request (`%{}`) plus a function that fails the test if it is called proves the
  empty branch runs before `settings/1` and before any provider call.
  """
  @spec assert_empty_request_skips_settings_and_provider(module(), atom()) :: :ok
  def assert_empty_request_skips_settings_and_provider(client, hook) do
    requesting = fn _method, _path, _params, _body, _settings ->
      flunk("#{inspect(client)} reached the provider request function for an empty request")
    end

    assert_empty_answer(
      apply(client, hook, [[], %{}, requesting]),
      "#{inspect(client)}.#{hook}([], %{}, request_fun)"
    )
  end

  @doc """
  Rule 4: the `Issue` struct's field names and defaults (`issue.ex:12-30`).

  Elixir exposes no runtime access to `@type`, so the declared types are not asserted here; the
  values an adapter actually parses are, in the tests that read a real ticket.
  """
  @spec assert_issue_struct() :: :ok
  def assert_issue_struct do
    struct = Issue.__info__(:struct)
    fields = struct |> Enum.map(& &1.field) |> Enum.sort()

    assert fields == Enum.sort(@issue_fields),
           "the Issue struct's fields changed; the contract in issue.ex:12-30 must be re-frozen"

    defaults = Map.new(struct, &{&1.field, &1.default})

    Enum.each(@collection_fields, fn field ->
      assert Map.get(defaults, field) == [],
             "Issue.#{field} must default to [] rather than nil (issue.ex:23-24)"
    end)

    assert Map.get(defaults, :dispatchable) == false, "Issue.dispatchable must default to false"

    Enum.each(@scalar_fields, fn field ->
      assert Map.get(defaults, field) == nil, "Issue.#{field} must default to nil (issue.ex:12-30)"
    end)

    :ok
  end

  @doc """
  Rule 5: `Issue.routable?/2` (`issue.ex:61-74`).

  Labels match case- and whitespace-insensitively on both sides (`issue.ex:70-74`), every
  configured label is required (`issue.ex:65`), and `dispatchable` is a gate of its own that makes
  the whole predicate false regardless of labels (`issue.ex:68`).
  """
  @spec assert_routable_rules() :: :ok
  def assert_routable_rules do
    routed = %Issue{dispatchable: true, labels: ["Perf", " UX "]}

    assert Issue.routable?(routed, ["perf", "ux"]), "labels must match case-insensitively"
    assert Issue.routable?(routed, ["  PERF  ", "Ux"]), "configured labels must be normalised too"
    refute Issue.routable?(routed, ["perf", "missing"]), "every configured label is required"
    refute Issue.routable?(routed, ["perf", "ux", "extra"]), "an absent label cannot be required"
    assert Issue.routable?(%Issue{dispatchable: true, labels: []}, []), "no labels required is a match"
    refute Issue.routable?(%Issue{dispatchable: false, labels: ["perf"]}, ["perf"])
    refute Issue.routable?(%Issue{dispatchable: false, labels: []}, []),
           "dispatchable is a gate even when nothing is required"

    refute Issue.routable?(%Issue{dispatchable: true, labels: nil}, ["perf"]),
           "a nil label list is not routable (issue.ex:68)"

    :ok
  end

  @doc """
  Rule 7: `secret_environment_names/1` is required and returns a list of names.

  An empty list is a value, not an exemption (`file.ex:153-154`, `memory.ex:40-41`): the callback is
  always present (rule 1) and always answers a list.
  """
  @spec assert_secret_environment_names(module(), map()) :: :ok
  def assert_secret_environment_names(adapter, tracker_settings) do
    names = adapter.secret_environment_names(tracker_settings)

    assert is_list(names),
           "#{inspect(adapter)}.secret_environment_names/1 must return a list, got #{inspect(names)}"

    Enum.each(names, &assert_present_string(&1, "a name from #{inspect(adapter)}"))
    :ok
  end

  @doc """
  Rule 6: the agent tool surface.

  The dispatch answers an unsupported tool with the envelope rather than an exception
  (`tracker.ex:115-121`, `tracker.ex:127-141`), which is what every adapter has to satisfy; an
  adapter that advertises tools must additionally answer each of its own specs with the envelope
  (`success`/`output`/`contentItems`) and never raise, including for arguments it refuses.

  `tool_opts` is handed to `execute_agent_tool/3` unchanged. It exists so the caller can pass the
  adapter's own transport stub (`linear/agent_tool.ex:57`, `github/agent_tool.ex:58`,
  `gitlab/agent_tool.ex:58`, `jira/agent_tool.ex:58`, `asana/agent_tool.ex:58`,
  `janitor/agent_tool.ex:159`) and so turn "this argument was refused before any request" from
  something read out of the source into something the caller's stub proves. It changes no adapter.
  """
  @spec assert_tool_surface(module(), keyword()) :: :ok
  def assert_tool_surface(adapter, tool_opts \\ []) do
    unsupported = bound_agent_tool(adapter, "no_such_tool", %{}, tool_opts)

    assert_envelope(unsupported, "#{inspect(adapter)} dispatched with an unsupported tool")
    refute unsupported["success"], "an unsupported tool must fail, not succeed"

    assert_advertised_tools(adapter, tool_opts)
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  defp registry_block(source) do
    case String.split(source, "@adapters %{", parts: 2) do
      [_, rest] ->
        List.first(String.split(rest, "\n  }"))

      [_] ->
        flunk("no @adapters registry found in #{@registry_source}")
    end
  end

  defp behaviours(adapter) do
    adapter.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
  end

  defp assert_callback(adapter, {fun, arity}) do
    assert function_exported?(adapter, fun, arity),
           "#{inspect(adapter)} is missing required callback #{fun}/#{arity} (tracker.ex:23-28)"
  end

  defp assert_present_string(value, what) do
    assert is_binary(value), "#{what} must be a string, got #{inspect(value)}"
    assert String.trim(value) != "", "#{what} must not be blank"
  end

  defp assert_advertised_tools(adapter, tool_opts) do
    specs = advertised_tool_specs(adapter)
    Enum.each(specs, &assert_tool_spec(adapter, &1, tool_opts))
  end

  defp advertised_tool_specs(adapter) do
    if function_exported?(adapter, :agent_tool_specs, 0) do
      specs = adapter.agent_tool_specs()
      assert is_list(specs), "#{inspect(adapter)}.agent_tool_specs/0 must return a list"
      assert specs != [], "#{inspect(adapter)} exports agent_tool_specs/0 but advertises nothing"
      specs
    else
      []
    end
  end

  defp assert_tool_spec(adapter, spec, tool_opts) do
    assert is_map(spec), "#{inspect(adapter)} advertises a tool spec that is not a map"

    keys = spec |> Map.keys() |> Enum.sort()
    assert keys == Enum.sort(@tool_keys), "#{inspect(adapter)} advertises keys #{inspect(keys)}"

    assert_present_string(spec["name"], "a tool name from #{inspect(adapter)}")
    assert_present_string(spec["description"], "the description of #{inspect(spec["name"])}")

    assert is_map(spec["inputSchema"]),
           "#{inspect(spec["name"])} must carry an inputSchema map, got #{inspect(spec["inputSchema"])}"

    Enum.each(@refused_arguments, &assert_tool_envelope(adapter, spec["name"], &1, tool_opts))
  end

  defp assert_tool_envelope(adapter, tool, arguments, tool_opts) do
    result = execute_tool(adapter, tool, arguments, tool_opts)
    assert_envelope(result, "#{inspect(adapter)}.#{inspect(tool)} with #{inspect(arguments)}")
  end

  defp execute_tool(adapter, tool, arguments, tool_opts) do
    call_tool(adapter, tool, arguments, tool_opts)
  rescue
    error ->
      flunk(
        "#{inspect(adapter)} raised for tool #{inspect(tool)} with #{inspect(arguments)}: " <>
          Exception.message(error)
      )
  end

  defp call_tool(adapter, tool, arguments, tool_opts) do
    if function_exported?(adapter, :execute_agent_tool, 3) do
      adapter.execute_agent_tool(tool, arguments, tool_opts)
    else
      bound_agent_tool(adapter, tool, arguments, tool_opts)
    end
  end

  defp bound_agent_tool(adapter, tool, arguments, tool_opts) do
    Tracker.execute_bound_agent_tool(
      %{adapter: adapter, tracker_settings: %{}},
      tool,
      arguments,
      tool_opts
    )
  end

  defp assert_envelope(result, what) do
    assert is_map(result), "#{what} must return the result envelope, got #{inspect(result)}"

    Enum.each(@envelope_keys, fn key ->
      assert Map.has_key?(result, key), "#{what} is missing #{inspect(key)}"
    end)

    assert is_boolean(result["success"]), "#{what} must carry a boolean success"
    assert is_binary(result["output"]), "#{what} must carry a binary output"
    assert is_list(result["contentItems"]) and result["contentItems"] != [],
           "#{what} must carry non-empty contentItems"
  end
end
