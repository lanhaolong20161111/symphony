# Planner example: one ticket in, many tickets out

Symphony already has a dispatcher -- `Orchestrator` is the single place that decides what runs
next, how many things run at once, and what waits. What it deliberately does not do is *invent*
work: its input is the tracker, and its output is one agent run per dispatchable ticket.

So "let a commander assign the tasks" is not a missing feature; it is a **second workflow whose job
is to write tickets**. This example is that, and nothing else changes:

| file | what it is |
|---|---|
| `WORKFLOW.plan.md` | a planner workflow: `active_states: [plan]`, one agent at a time, no hooks, endpoint off |
| `tickets/GOAL-1.md` | the goal ticket the planner consumes |
| `tickets/` | where the planner writes the tickets it invents |

## Run it

```sh
# 1. Edit WORKFLOW.plan.md: REPLACE/ME/... must be an absolute path to this tickets/ directory.
# 2. Put the goal in tickets/GOAL-1.md (the body is the issue description).
# 3. Build the escript once, then run Symphony with the planner workflow:
mise exec -- mix escript.build
bin/symphony examples/planner/WORKFLOW.plan.md
# 4. The planner writes tickets with state: ready and blocked_by: [...], then marks GOAL-1 done.
# 5. Now run the normal workflow, pointed at the same tickets directory:
bin/symphony WORKFLOW.md
```

`mix phx.server` also works if you prefer the console, as long as `workflow_file_path` points at the
planner file (`config :symphony_elixir, workflow_file_path: "examples/planner/WORKFLOW.plan.md"`).

## The two things that bite

**The path must be absolute.** Every agent works in its own clone under `workspace.root`, so a
relative ticket directory resolves *inside that clone*. The planner would write beautiful tickets
into a throwaway checkout and the next poll would see nothing, with no error anywhere.

**Dependencies come from the file tracker.** `blocked_by` is what makes this a task graph rather
than a pile: a ticket carrying blockers is held back -- visible as blocked, not silently dropped --
and the dispatcher only ever takes tickets in `active_states`. The GitHub adapter has no equivalent,
which is why this example is file-backed.

## What the agents can and cannot do

The tracker adapters expose provider-native tools to the agent, and GitHub's is a general REST tool
(`github_api`, executed server-side with Symphony's credentials) -- so on the **codex** backend an
agent could file issues itself. The **acp** backend (DSH, and the default here) has no dynamic-tool
channel, so under ACP the only way for an agent to create work is to write files. That is exactly
what this example does, and why it does not need any credential at all.
