# Agent tool surface

Measured by reading `elixir/lib/**` at `main` (`f393609`) plus its tests. Paths are repo-relative.
Where a name could not be found in the tree, the section says so and labels the substitute inference.

## 1. Which tracker kinds advertise agent tools

Registry: `elixir/lib/symphony_elixir/tracker.ex:13-21` (seven kinds). The composition at the
boundary is `adapter_agent_tool_specs/1`, `elixir/lib/symphony_elixir/tracker.ex:107-113`; it calls
an adapter's `agent_tool_specs/0` only if it is loaded and exported, else `[]`. That optionality is
declared at `elixir/lib/symphony_elixir/tracker.ex:30-32`, so "no tools" is a legal adapter.

| kind | tool names | composed where |
|---|---|---|
| asana | `asana_api` | `elixir/lib/symphony_elixir/asana/adapter.ex:26` -> `elixir/lib/symphony_elixir/asana/agent_tool.ex:8,47-54` |
| file | `symphony_publish`, `ticket_comment` | `elixir/lib/symphony_elixir/tracker/file.ex:165` -> `elixir/lib/symphony_elixir/janitor/agent_tool.ex:19-20,68-80` |
| github | `github_api` | `elixir/lib/symphony_elixir/github/adapter.ex:39` -> `elixir/lib/symphony_elixir/github/agent_tool.ex:8,47-55` |
| gitlab | `gitlab_api` | `elixir/lib/symphony_elixir/gitlab/adapter.ex:39` -> `elixir/lib/symphony_elixir/gitlab/agent_tool.ex:8,47-55` |
| jira | `jira_rest` | `elixir/lib/symphony_elixir/jira/adapter.ex:26` -> `elixir/lib/symphony_elixir/jira/agent_tool.ex:8,47-55` |
| linear | `linear_graphql` | `elixir/lib/symphony_elixir/linear/adapter.ex:38` -> `elixir/lib/symphony_elixir/linear/agent_tool.ex:8,46-54` |
| memory | (none) | no `agent_tool_specs/0` in `elixir/lib/symphony_elixir/tracker/memory.ex`; falls through `elixir/lib/symphony_elixir/tracker.ex:107-113` |

Each non-file kind advertises exactly one tool; `file` advertises exactly two. Pinned by tests:
`file_tracker_test.exs:277-285`, `asana_adapter_test.exs:61`, `github_adapter_test.exs:67`,
`gitlab_adapter_test.exs:67`, `jira_adapter_test.exs:60`, `extensions_test.exs:239` (all under
`elixir/test/symphony_elixir/`), and memory -> `[]` at `dynamic_tool_test.exs:56`.

## 2. Tools that are the host's, not a tracker's

`symphony_publish` and `ticket_comment` are defined in `SymphonyElixir.Janitor.AgentTool`
(`elixir/lib/symphony_elixir/janitor/agent_tool.ex:19-20`, specs at `:68-80`) and composed into the
file adapter at `elixir/lib/symphony_elixir/tracker/file.ex:164-171` (alias at
`elixir/lib/symphony_elixir/tracker/file.ex:76`).

Why that boundary: they are not tracker capabilities. The agent cannot commit, push or open a pull
request -- codex's `workspaceWrite` sandbox makes `.git/` read-only and `gh` cannot read its own
config (`elixir/lib/symphony_elixir/janitor/agent_tool.ex:5-6`,
`elixir/lib/symphony_elixir/tracker/file.ex:159-161`) -- so the host performs the write and the tool
returns the branch and pull-request URL in the same turn
(`elixir/lib/symphony_elixir/janitor/agent_tool.ex:12-14`). Backing calls: `Janitor.publish_now/1`
(`elixir/lib/symphony_elixir/janitor.ex:630`) and `Janitor.comment_on_ticket/2`
(`elixir/lib/symphony_elixir/janitor.ex:603`); the sweep is the same work on a timer
(`elixir/lib/symphony_elixir/janitor.ex:621-623`).

The setting: both `acp.tracker_tools` (`elixir/lib/symphony_elixir/config/schema.ex:286`) and
`server.tracker_tools` (`elixir/lib/symphony_elixir/config/schema.ex:399`) default to `false`.
A project that does not declare them gets no HTTP route (404 `tracker_tools_disabled`,
`elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex:66-70`, pinned at
`elixir/test/symphony_elixir_web/observability_tools_test.exs:60-66`) and an ACP session with an
empty `mcp_servers` list (`elixir/lib/symphony_elixir/acp/app_server.ex:361-362,414`). The Codex
path is not gated that way: a file-tracker turn receives `dynamicTools` unconditionally
(`docs/fork-changes.md:26`).

## 3. The envelope a tool call returns

Shape: `dynamic_tool_response/2`, one private copy per tool module --
`elixir/lib/symphony_elixir/linear/agent_tool.ex:129-140`, `github/agent_tool.ex:111-117`,
`gitlab/agent_tool.ex:112`, `jira/agent_tool.ex:112`, `asana/agent_tool.ex:112` (all under
`elixir/lib/symphony_elixir/`, each running to `:117`), `janitor/agent_tool.ex:189-201`, and the
boundary fallback `elixir/lib/symphony_elixir/tracker.ex:127-141`. Three keys: `"success"`
(boolean), `"output"` (pretty JSON text), `"contentItems"` = one `inputText` item repeating it.

Success, `elixir/test/symphony_elixir/janitor/agent_tool_test.exs:45-55`:

    response = AgentTool.execute("symphony_publish", %{"ticket" => "SYM-26"}, publish: stub(result))
    assert response["success"]
    payload = Jason.decode!(response["output"])
    assert payload["branch"] == "symphony/SYM-26"
    assert [%{"type" => "inputText", "text" => text}] = response["contentItems"]

Failure, `elixir/test/symphony_elixir/dynamic_tool_test.exs:26-43`:

    assert response["success"] == false
    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["linear_graphql"]
             }
           }

HTTP returns that map as the response body
(`elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex:79`); MCP wraps it as
one text content item with `isError` false
(`elixir/lib/symphony_elixir/mcp/tracker_server.ex:96-108`); a Codex turn receives it directly
(`elixir/lib/symphony_elixir/codex/app_server.ex:89-92`).

## 4. How the three transports reach the same list

All three read the same binding built by `Tracker.bind_agent_tools/0`
(`elixir/lib/symphony_elixir/tracker.ex:50-60`), which snapshots adapter, settings, specs and secret
names so advertisement and execution cannot drift on a workflow reload
(`elixir/lib/symphony_elixir/tracker.ex:44-48`; pinned at
`elixir/test/symphony_elixir/dynamic_tool_test.exs:46-76`).

- Codex app-server: `elixir/lib/symphony_elixir/codex/app_server.ex:484`
  (`"dynamicTools" => dynamic_tool_binding.tool_specs`), binding from `DynamicTool.bind()` at
  `elixir/lib/symphony_elixir/codex/app_server.ex:41` -> `elixir/lib/symphony_elixir/codex/dynamic_tool.ex:15`.
- ACP/MCP stdio server: `elixir/lib/symphony_elixir/mcp/tracker_server.ex:79` answers `tools/list`
  from `tool_specs/0` (`:119-124`), which binds at `:111`; declared into an ACP session at
  `elixir/lib/symphony_elixir/acp/app_server.ex:361,414` and entered by `bin/symphony --mcp`
  (`elixir/lib/symphony_elixir/cli.ex:37,56`).
- HTTP tool endpoint: route `elixir/lib/symphony_elixir_web/router.ex:50` ->
  `ObservabilityApiController.tool/2`, which binds at
  `elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex:74`.

Empty list: the HTTP endpoint answers 404 `no_agent_tools`
(`elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex:75-76`; pinned at
`elixir/test/symphony_elixir_web/observability_tools_test.exs:70-75`, memory tracker). MCP answers
`tools/list` with an empty list (`elixir/lib/symphony_elixir/mcp/tracker_server.ex:119-124`) and any
call with `isError` true (`:103-105`), which reads on the agent side as a server with no tools
(`elixir/lib/symphony_elixir/acp/app_server.ex:364-367`).

## 5. Deliberately not advertised

- `memory` advertises nothing at all (row 1 above; `elixir/lib/symphony_elixir/tracker.ex:107-113`).
- A tool one kind has and another cannot: `symphony_publish` / `ticket_comment` exist only for
  `kind: file` (`elixir/lib/symphony_elixir/tracker/file.ex:164-165`). A Linear project gets only
  `linear_graphql` (`elixir/lib/symphony_elixir/linear/agent_tool.ex:46-54`) and no way to ask for a
  publish; only the host sweep does that (`elixir/lib/symphony_elixir/janitor.ex:621-623`).
  Symmetrically, a file-tracker project never sees `linear_graphql`.
- A write capability missing on purpose: there is no generic ticket state or comment CRUD tool. The
  contract says so directly -- "Do not add generic comment/state/attachment CRUD merely to make
  providers look alike" (`SPEC.md:1182`). The janitor can write a key and a link
  (`elixir/lib/symphony_elixir/janitor/ticket.ex:110,132`) but exposes neither; a ticket's state is
  moved by editing one line of its file (`elixir/lib/symphony_elixir/tracker/file.ex:56-58`), and
  `ticket_comment` exists only because editing the body would risk the ticket's structure
  (`elixir/lib/symphony_elixir/janitor/agent_tool.ex:30-35`, `:173`). No git or shell tool is
  advertised either -- publishing is host-side only
  (`elixir/lib/symphony_elixir/janitor/agent_tool.ex:5-6`).
- The whole surface is closed by default: `elixir/lib/symphony_elixir/config/schema.ex:286,399`.

## Two names this tree does not contain

The ticket's validation greps for `symphony_gate` and `ticket_service`. Neither string exists here:
`grep -rn "symphony_gate" .` and `grep -rn "ticket_service" .` return zero hits across the worktree,
and `git log -S"symphony_gate" --all` / `git log -S"ticket_service" --all` return no commits. I am
inferring rather than reading what they denote:

- `symphony_gate` -> I infer the host-side gate that closes the surface: `server.tracker_tools` /
  `acp.tracker_tools` defaulting to false (`elixir/lib/symphony_elixir/config/schema.ex:286,399`),
  the 404 `tracker_tools_disabled`
  (`elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex:66-70`), the empty
  ACP `mcp_servers` (`elixir/lib/symphony_elixir/acp/app_server.ex:362`). The nearest literal is
  `apply_dispatch_gate` (`elixir/lib/symphony_elixir/tracker/file.ex:217`), which gates dispatch.
- `ticket_service` -> I infer the host-side ticket service the file tracker's tools sit on:
  `SymphonyElixir.Janitor` (`elixir/lib/symphony_elixir/janitor.ex:603,630`) plus
  `SymphonyElixir.Janitor.Ticket` (`elixir/lib/symphony_elixir/janitor/ticket.ex`). No module,
  config block or tracker kind carries that name; the only `ticket_`-prefixed tool is
  `ticket_comment` (`elixir/lib/symphony_elixir/janitor/agent_tool.ex:20`).
