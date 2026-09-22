# Planner example: one ticket in, many tickets out

Symphony already has a dispatcher -- `Orchestrator` is the single place that decides what runs next,
how many things run at once, and what waits. What it deliberately does not do is *invent* work: its
input is the tracker, and its output is one agent run per dispatchable ticket.

So "let a commander assign the tasks" is not a missing feature; it is a **second workflow whose job
is to write tickets**. This directory has two, one per kind of tracker:

| file | tracker | dependencies | credentials |
|---|---|---|---|
| `WORKFLOW.plan.md` | local files | ✅ `blocked_by`, machine-readable | none at all |
| `WORKFLOW.plan.github.md` | GitHub issues | ❌ (order goes in the text) | the tracker token, held by Symphony |

## Files

| file | what it is |
|---|---|
| `WORKFLOW.plan.md` | file-backed planner: `active_states: [plan]`, writes ticket files |
| `WORKFLOW.plan.github.md` | GitHub-backed planner: files issues through `github_api` (`acp.tracker_tools: true`) |
| `tickets/GOAL-1.md` | the goal ticket the file-backed planner consumes |
| `tickets/` | where the file-backed planner writes the tickets it invents |

## Run the file-backed one

```sh
# 1. Edit WORKFLOW.plan.md: REPLACE/ME/... must be an absolute path to this tickets/ directory.
# 2. Put the goal in tickets/GOAL-1.md (the body is the issue description).
mise exec -- mix escript.build
bin/symphony WORKFLOW.plan.md          # the planner writes tickets, then marks GOAL-1 done
bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails WORKFLOW.md
```

`mix phx.server` also works if you prefer the console, as long as `workflow_file_path` points at the
planner file (`config :symphony_elixir, workflow_file_path: "examples/planner/WORKFLOW.plan.md"`).

## Run the GitHub-backed one

```sh
# 1. Edit WORKFLOW.plan.github.md: repo: owner/name, and export GITHUB_TOKEN.
# 2. Have a goal issue open in that repository.
bin/symphony WORKFLOW.plan.github.md    # the planner files issues, then lists their numbers
# 3. Stop it (it is a one-shot), then run the executor against the same repository:
bin/symphony WORKFLOW.md
```

That mode is the one that needs `acp.tracker_tools: true`, which is off everywhere by default:
it hands the agent the tracker's write capability. Keeping it in the *planner* workflow only is the
point of having two files -- the executor workflow never has it.

## The traps, all measured

**The file planner's path must be absolute.** Every agent works in its own clone under
`workspace.root`, so a relative ticket directory resolves *inside that clone*. The planner writes
beautiful tickets into a throwaway checkout and the next poll sees nothing, with no error anywhere.
(The GitHub planner has no equivalent trap: the issues are not files.)

**Dependencies only exist on the file tracker.** `blocked_by` is what makes that mode a task graph
rather than a pile -- a ticket carrying blockers is held back, visible as blocked, not silently
dropped -- and the dispatcher only takes tickets in `active_states`. GitHub has no such field.

**A declared MCP server inherits nothing.** The `acp.tracker_tools` path works by having the agent
call Symphony's MCP server, and that server is a separate process: the ACP adapter has to pass it an
environment (`PATH`, and the tracker token from `secret_environment_names`) or it cannot validate the
workflow and advertises **zero tools**, which looks on the agent side exactly like "no such server".

**Stop the planner when it is done.** With the GitHub tracker, the issues it files are `open`, which
is an active state: left running, the planner would start executing its own plan.

## What the agents can and cannot do

The tracker adapters expose provider-native tools. GitHub's is a general REST call (`github_api`)
**executed server-side with Symphony's credentials**, so the agent can file issues while never
holding the token. Under ACP that tool arrives as an MCP server, which the adapter declares when
`acp.tracker_tools: true`; on the codex backend the same tools are handed to the turn directly
(`dynamicTools`). The HTTP route (`POST /api/v1/tools/:tool`) exists for agents with a shell but
without MCP.
