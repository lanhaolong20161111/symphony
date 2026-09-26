---
# File tracker (tickets = markdown files in a git repo). Fork only: tracker/file.ex
# does not exist upstream. Front matter MUST stay ASCII -- the YAML parser rejects
# non-ASCII here (measured, twice).
#
# Every setting below encodes a trap measured on this machine today:
#   * hooks.timeout_ms defaults to 60s while clone + deps.get needs >90s => first run always
#     times out the hook.
#   * after a hook timeout Windows cannot delete the partial workspace (:eacces) => the retry
#     reuses a half-empty dir => hence the idempotent clone guard.
#   * approval_policy can only be `never` (app_server.ex:55 auto-approves only when it equals
#     "never"; there is no operator channel to answer anything else).
#   * the upstream example pins model="gpt-5.5"; this machine's codex runs DeepSeek/CommandCode,
#     so the pin is dropped to let the local config.toml defaults apply.
#   * `sh` must resolve to Git's, not WSL's, or System.cmd("sh", ...) fails with :enoent
#     (launch with Git's bin dirs prepended to PATH).
tracker:
  kind: file
  provider:
    # The queue: one .md per ticket, file name = identifier.
    path: C:/Users/lhl20/code/symphony-tickets
  required_labels: []
  # `in-progress` MUST be here: the moment the agent edits the ticket out of the active set,
  # reconcile terminates the running agent.
  active_states:
    - ready
    - in-progress
  # `in-review` is deliberately in neither list => it lands in reconcile's "non-active" branch
  # => the run stops and waits for a human.
  terminal_states:
    - done
    - cancelled
    - failed
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-file-workspaces
server:
  host: 127.0.0.1
  port: 4001
hooks:
  timeout_ms: 600000
  after_create: |
    if [ ! -d .git ]; then git clone --depth 1 https://github.com/lanhaolong20161111/beekeeper .; fi
    mix deps.get
  # Publishing lives HERE, not in the agent -- measured, not a preference.
  #
  # codex's `workspaceWrite` sandbox makes `.git/` read-only for the agent:
  #     fatal: cannot lock ref 'refs/heads/symphony/SYM-6':
  #            unable to create directory for .git/refs/heads/symphony/SYM-6
  # and `gh` cannot even read its own config (it lives under %APPDATA%, outside the workspace):
  #     gh: failed to load config: open .../GitHub CLI/config.yml: Access is denied
  # So the agent CAN edit files and run the ticket's validation, but it CANNOT branch, commit,
  # push or open a PR. A hook runs from Symphony's own process, outside that sandbox, so it can.
  #
  # Runs ONCE per worker attempt (agent_runner.ex wraps all turns in try/after), which is why
  # this is the right hook and not `before_run`. Hooks are NOT template-rendered, so the ticket
  # identifier comes from the workspace directory name (create_for_issue names it after the
  # identifier).
  #
  # ⚠️ It does NOT fire on the path we actually care about. When the agent sets the ticket to
  # `in-review`, reconcile terminates the run from the OUTSIDE (`Task.Supervisor.terminate_child`
  # / `Process.exit(pid, :shutdown)`), and the run task does not trap exits -- so this `after`
  # block never runs. Kept because it is correct on the normal-completion path (agent stops while
  # the ticket is still active); the host-side janitor is what covers the kill path. Both are
  # idempotent, so they cannot double-publish.
  after_run: |
    id=$(basename "$PWD")
    branch="symphony/$id"
    git checkout -B "$branch" >/dev/null 2>&1
    git add -A
    if git diff --cached --quiet; then
      echo "after_run: nothing to publish for $id"
    else
      git -c user.name=symphony -c user.email=symphony@local commit -q -m "symphony/$id: automated change"
      if git push -u origin "$branch" >/dev/null 2>&1; then
        echo "after_run: pushed $branch"
      else
        echo "after_run: PUSH FAILED for $branch"
      fi
      gh pr create --head "$branch" --base main --label symphony --fill >/dev/null 2>&1 ||
        echo "after_run: pr create failed (already open, or no gh auth)"
    fi
agent:
  # One ticket on the first run: keep it small, and use max_turns as a brake
  # (an earlier run today spun on a dangling reference and burned a lot of budget).
  max_concurrent_agents: 2
  max_turns: 5
codex:
  # Route: CommandCode's DeepSeek V4.1 Flash -- NOT the operator's own DeepSeek API key.
  # Measured 2026-09-26: without this the run lands on model_provider=deepseek
  # (base_url https://api.deepseek.com/) and bills the official key; one stuck run spent
  # 11.4M input / 152k output tokens there before it was caught.
  #
  # `--profile commandcode` does NOT work on codex 0.155.1: it rejects the legacy
  # `[profiles.commandcode]` table in config.toml and demands the settings move to a
  # separate ~/.codex/commandcode.config.toml. We deliberately do not touch that config --
  # the same settings are passed explicitly instead.
  #
  # Note the quoting: Symphony hands this whole string to `bash -lc` (codex/app_server.ex
  # local_launch_command/1), so bash does the word splitting and shell quotes are stripped
  # before codex sees the TOML fragments.
  command: codex --config shell_environment_policy.inherit=all --config model_provider='"commandcode"' --config 'model="deepseek/deepseek-v4.1-flash"' app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
    # The ticket file lives OUTSIDE the agent's workspace, and workspaceWrite only allows
    # writes inside the workspace by default => without this the agent can read the ticket
    # but not change its state. The key name is inferred (camelCase, same family as
    # networkAccess); if codex rejects it, thread/start will say so and we adjust.
    writableRoots:
      - C:/Users/lhl20/code/symphony-tickets
---

You are working on ticket `{{ issue.identifier }}`.

## The ticket

- Identifier: {{ issue.identifier }}
- Title: {{ issue.title }}
- State: {{ issue.state }}
- Labels: {{ issue.labels }}

The ticket file is at:

    C:/Users/lhl20/code/symphony-tickets/{{ issue.identifier }}.md

Description:

{{ issue.description }}

## Your workspace

Your working directory is a fresh clone of the target repository. Do all code work there.
Do not touch any path other than that clone and the ticket file named above.

## Moving the ticket

Progress is tracked by exactly ONE line in the ticket file: the `state:` line in its front matter.

- When you start working: change `state: ready` to `state: in-progress`.
- When your work and its validation are done: change it to `state: in-review`. That is your
  "done" signal -- the host publishes after that (see "Do NOT run git or gh" below).
- If you are genuinely blocked: leave it at `state: in-progress` and say why in your final message.

Edit that one line with your normal file-editing tool. There is no ticket API and no tool to call --
the file *is* the tracker.

## Steps

1. Set the ticket to `state: in-progress`.
2. Do the work the ticket describes. If it describes a bug, reproduce it first so the target is explicit.
3. Run the validation the ticket asks for. The ticket's `Validation` section is **not optional**:
   if it names a command, run it and make it pass before you go on.
4. Set the ticket to `state: in-review`. Then write your final message. **Do not publish anything**
   -- the branch, the commit, the push and the PR are the host's job (next section).

## Do NOT run git or gh

Do not run `git commit`, `git add`, `git checkout -b`, `git push` or `gh pr create`. In this sandbox
they cannot succeed, and trying costs the entire run:

- `.git/` is read-only for you: `fatal: cannot lock ref 'refs/heads/...': unable to create directory
  for .git/refs/...`
- `gh` cannot even read its own config: `Access is denied` on `%APPDATA%\GitHub CLI\config.yml`

Neither is a permissions problem you can escalate your way out of -- do not try workarounds
(no junction/symlink tricks, no `--git-dir` relocation, no ACL probing). Measured: an earlier run
spent most of its budget doing exactly that and never finished.

**Publishing is the host's job.** Once you set the ticket to `in-review`, a host-side sweep commits
your working tree, pushes a branch named `symphony/<ticket>` and opens the PR. You do not need to do
any of it.

## Rules

- Only the ticket's validation decides whether this is done. Do not claim completion without running it.
- Do not modify any ticket other than `{{ issue.identifier }}`.
- Report what you actually did and what failed. No "next steps for the user".
