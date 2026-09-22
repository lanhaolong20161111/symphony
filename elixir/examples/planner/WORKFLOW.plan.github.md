---
# Planner, GitHub-backed: the commander files issues instead of files.
#
# Run this once with a goal issue, let it create the work as GitHub issues, stop it, then run the
# normal WORKFLOW.md so the executor picks those issues up. Nothing in the engine changes -- this is
# a second WORKFLOW.md, selected by the argument the CLI already takes.
#
# `acp.tracker_tools: true` is the part that lets the agent act on the tracker: the ACP adapter
# declares Symphony's MCP server, the agent calls `github_api`, and the call is executed here with
# Symphony's token. The credential never enters the agent's environment, which is why the tool is
# mediated rather than handed over.
#
# Two differences from the file-backed planner worth knowing before choosing:
#
#   * GitHub has no `blocked_by`, so tickets created this way carry **no machine-readable
#     dependencies**. Order the work in the issue bodies, or with labels, and accept that the
#     executor will pick everything open up in parallel (bounded by max_concurrent_agents).
#   * GitHub's only states are open and closed, so "blocked" and "in progress" have to live in
#     labels or comments.
#
# Absolute path not required here (that was the file tracker's trap); `repo` is owner/name and the
# token is read from the environment by the adapter.

tracker:
  kind: github
  provider:
    repo: REPLACE/owner-repo
  active_states:
    - open
  terminal_states:
    - closed

polling:
  interval_ms: 30000

workspace:
  root: ~/code/symphony-planner-workspaces

agent:
  backend: acp
  max_concurrent_agents: 1
  max_turns: 20

acp:
  adapter: dsh
  # The whole point of this workflow: the agent may file issues.
  tracker_tools: true
  init_timeout_ms: 60000
  turn_timeout_ms: 1800000
---

You are planning work, not doing it. Turn the goal below into GitHub issues that other agents can
execute independently, using the `github_api` tool you have been given.

Goal: {{ issue.title }}

{{ issue.description }}

Rules:

1. File one issue per piece of work, with
   `POST /repos/<owner>/<repo>/issues` and a body of `{"title": ..., "body": ...}`. Keep titles
   imperative and one line; put everything an executor needs in the body: what to change, where, and
   how to tell it is done.
2. Execution order is not machine-readable on GitHub. State it in the bodies ("do this before X") and
   add a `blocked-by` style note in the first line of the body if the order matters, but assume the
   executor may start several at once.
3. Do not implement anything yourself, and do not modify the repository. Filing issues is the whole
   job.
4. If the goal is too vague to split, file exactly one issue whose body lists the questions that have
   to be answered first.
5. When the issues are filed, reply with a list of their numbers, then stop. This run is a one-shot:
   whoever started it will stop Symphony and run the executor workflow against the same repository.
