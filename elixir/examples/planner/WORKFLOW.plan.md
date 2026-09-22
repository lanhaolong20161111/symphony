---
# A planner workflow: one ticket in, many tickets out.
#
# Run Symphony with this file instead of the default WORKFLOW.md, point it at a goal ticket, and
# the run it dispatches writes the tickets that the normal workflow then executes. Symphony itself
# is unchanged -- this only uses the tracker it already reads.
#
# `path` MUST be absolute. Each agent works in its own clone under `workspace.root`, so a relative
# ticket directory would resolve inside that clone and the tickets would never be seen.
tracker:
  kind: file
  provider:
    path: REPLACE/ME/with/an/absolute/path/to/examples/planner/tickets
  active_states:
    - plan
  terminal_states:
    - done

polling:
  interval_ms: 5000

workspace:
  root: ~/code/symphony-planner-workspaces

# No hooks: a planner does not need the application's source, only the ticket directory.
# No `server:` block either -- the observability endpoint stays off for a planner run.

agent:
  backend: acp
  max_concurrent_agents: 1
  max_turns: 20

acp:
  adapter: dsh
  init_timeout_ms: 60000
  turn_timeout_ms: 1800000
---

You are planning work, not doing it. Your single job is to turn the goal below into tickets that
other agents can execute independently.

Goal: {{ issue.title }}

{{ issue.description }}

Rules:

1. Write **one ticket per file** into the ticket directory this workflow is configured with (the
   absolute path in `tracker.provider.path`). Use kebab-case file names that say what the work is.
2. Each ticket is Markdown with YAML front matter:

   ```markdown
   ---
   id: short-stable-id
   title: One line, imperative
   state: ready
   blocked_by: [ids-of-tickets-that-must-finish-first]
   labels: [area]
   ---

   What to do, where, and how to tell it is done. Enough that an agent needs nothing else.
   ```

3. `state: ready` is the only state that makes a ticket dispatchable, and `blocked_by` is what keeps
   the rest in order. A ticket with a blocker is held back rather than dropped, so order the work
   honestly instead of flattening it.
4. Do not implement anything. Do not touch the application's source. If the goal is too vague to
   split, write exactly one ticket whose body lists the questions that have to be answered first.
5. When every ticket is written, set this goal ticket's `state:` to `done` -- that ends the planning
   run and lets the normal workflow take over.
