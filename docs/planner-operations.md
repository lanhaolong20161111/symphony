# Operating a planner: one page

`Orchestrator` decides what runs, but it never invents work -- its input is the tracker. A planner is
therefore a **second workflow whose output is tickets**. There are two, and the choice is about the
tracker, not about Symphony.

| | file-backed | GitHub-backed |
|---|---|---|
| workflow | `examples/planner/WORKFLOW.plan.md` | `examples/planner/WORKFLOW.plan.github.md` |
| output | ticket files | issues, filed through `github_api` over MCP |
| dependencies | ✅ `blocked_by`, machine-readable | ❌ order goes in the issue text |
| credentials | none | the tracker token, held by Symphony |
| `acp.tracker_tools` | not needed | **required** |

## The sequence

```sh
mise exec -- mix escript.build                 # once

# 1. plan
bin/symphony examples/planner/WORKFLOW.plan.github.md
#    it reads the goal issue, files the work as issues, lists their numbers, and stops working

# 2. stop the planner -- it is a one-shot. Left running, its own issues are `open`, which is an
#    active state, so it would begin executing the plan it just wrote.

# 3. execute
bin/symphony WORKFLOW.md                       # or the console, if you prefer
```

The file-backed planner is the same shape with `bin/symphony examples/planner/WORKFLOW.plan.md`, and
then step 3 points at the same tickets directory.

## Before it runs: check the repository

The repository must have **issues enabled**. A fork does not copy issues, and a repository can have
them switched off entirely -- `GET /issues` then yields nothing and the planner polls forever for a
goal it can never see. Check with `gh repo view <owner>/<name> --json hasIssuesEnabled`.

## Before it runs: check the workflow, not the agent

```sh
GITHUB_TOKEN=$(gh auth token) mise exec -- mix workflow.check
```

`workflow.check` validates the front matter **and renders the prompt body once**, which is the part
nothing else checks: the body is a template that is otherwise only rendered when a run starts, so a
typo in it fails runs rather than failing here.

For the file-backed planner this fails until the placeholder path is replaced -- deliberately, because
the file tracker validates that the directory exists. A relative path would pass and then write
tickets into each agent's throwaway clone, silently.

## What "the planner" actually is

A normal Symphony run. It polls the tracker like any other, takes the goal ticket because that ticket
is in `active_states`, and works in its own workspace. The only unusual things about the workflow are:

- `max_concurrent_agents: 1` -- one planner, not a fleet of them;
- `acp.tracker_tools: true` (GitHub mode only) -- which is what lets the agent act on the tracker at
  all. This is off everywhere by default: it hands the agent the tracker's write capability. Keeping
  it in the planner workflow only is why there are two files; the executor workflow never has it.

## Where the tool comes from

Three routes reach the same mediated tools (`github_api` for GitHub), and the credential stays on
Symphony's side in all three:

| route | how | when |
|---|---|---|
| MCP over ACP | `acp.tracker_tools: true`; the adapter declares Symphony's MCP server and the agent calls it | ACP backends. Verified end to end: the agent called the tool and reported the real result without holding a token |
| Codex dynamic tools | handed to the turn directly | `backend: codex` |
| HTTP | `POST /api/v1/tools/:tool` with `server.tracker_tools: true` | any agent with a shell |

If the MCP route looks broken -- the agent reporting that no such server exists -- it is almost
certainly the declaration, not the agent: `command` must be absolute, the declaration must carry
`env` (a declared server inherits nothing, and without the token it advertises zero tools), and
nothing but JSON may reach stdout.

## What the executor can and cannot do

Measured on a real run of the tickets a planner had filed: the agent cloned, edited, verified with
probe scripts it wrote itself, committed, and **pushed a branch**. Git authentication works, so its
work is publishable. What it could not do is touch the tracker, because the executor workflow
deliberately has no `acp.tracker_tools`.

So the boundary is sharper than "the agent has no credentials": it may publish code, and it may not
close its own tickets. Closing is an operator action, which is why a finished issue still reads as
open until someone says otherwise.

## After it runs

- **Check what it filed** before executing: a planner is an agent, and its judgement is the product.
- **Close or reword** anything you do not want executed -- with GitHub, closing is also how you
  cancel: the issue leaves the active state and the executor stops tracking it.
- The planner's own workspace stays on disk under `workspace.root`; nothing collects it.
