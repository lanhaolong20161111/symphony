# Quickstart

Symphony needs a tracker and an agent backend. Everything else is optional, and the tracker can
be **files on disk**, so you can run it with no account, no token and no network access at all.

## 1. Toolchain

The project pins its toolchain in `elixir/mise.toml` (currently `erlang 28`, `elixir 1.19.5-otp-28`)
and that pin matters: Elixir 1.20 is a different compiler, and under it `mix lint` currently
crashes inside Credo rather than failing cleanly.

```sh
cd elixir
mise install          # Windows: winget install jdx.mise, then mise install
```

There is no `make` on Windows; `make all` is `setup -> build -> fmt-check -> lint -> coverage ->
dialyzer`, and each step is just a mix task, so run those directly.

## 2. Pick a tracker

### Nothing but files (no account)

A ticket is one file. Copy the worked example and point the workflow at it:

```sh
cp -r examples/file-tracker/tickets ~/my-backlog
```

```yaml
tracker:
  kind: file
  provider:
    path: ~/my-backlog
  required_labels: []
  active_states: [open, ready]
  terminal_states: [done, cancelled]
```

Markdown with YAML front matter; the body becomes the issue description, so write it like a task
brief. Move work along by editing `state:` -- an agent can do that itself, since it is only a
file. A `.md` file without front matter is ignored (a README may live beside the tickets), a
ticket carrying `blocked_by:` is held back rather than dropped, and a missing `path` is an error
on every poll instead of an empty backlog.

### GitHub Issues

The checked-in workflow already uses this; set the token and the repo:

```sh
export GITHUB_TOKEN=$(gh auth token)          # PowerShell: $env:GITHUB_TOKEN = (gh auth token)
```

```yaml
tracker:
  kind: github
  provider:
    repo: owner/name
  active_states: [open]
  terminal_states: [closed]
```

States are GitHub's own (`open`/`closed`); the adapter rejects anything else, so Linear-style
`Todo`/`Doing`/`Done` do not exist here. The token comes from the environment, never the file.
`jira`, `gitlab`, `asana` and an in-memory tracker are also available.

## 3. Pick an agent backend

| backend | how it runs |
|---|---|
| `acp` (default) | any ACP agent: DSH, WorkBuddy, and ZCode/Pi through their wrappers |
| `codex` | `codex app-server` |
| `command_code` | the `command-code` CLI, on its own harness |

The default block drives DSH over ACP with a CommandCode model; `WORKFLOW.md` documents the
alternatives (including the ZCode wrapper and its `ZCODE_NODE` requirement) inline.

## 4. Run it

```sh
mise exec -- mix phx.server
```

**Turn the observability endpoint on.** It is off by default -- not a typo: `server.port` has no
schema default, so an unconfigured workflow reaches the `:ignore` branch and nothing listens.
Recent versions log a warning when that happens; the fix is a `server:` block:

```yaml
server:
  host: 127.0.0.1
  port: 4001
```

Then:

```sh
curl http://127.0.0.1:4001/api/v1/state          # running/retrying/blocked + per-run token usage
open http://127.0.0.1:4001/                      # the console (LiveView)
```

The endpoint has **no authentication** and can read files, run commands and start agents, so it
is loopback-only by design. Do not expose it.

### Serving the console behind a proxy mount

If something else fronts Symphony on a path prefix (for example the recorder serving it at
`/symphony`), set `SYMPHONY_URL_PATH`:

```sh
SYMPHONY_URL_PATH=/symphony mise exec -- mix phx.server
```

That makes absolute URLs (including `/dashboard.css`) and the LiveView socket carry the prefix,
and the layout publishes the matching socket path for the client. Empty -- the default -- keeps
upstream behaviour exactly as it was.

## 5. Check your work

```sh
mise exec -- mix compile --force --warnings-as-errors   # full type check (see below)
mise exec -- mix lint                                   # specs.check + credo --strict
mise exec -- mix format --check-formatted
mise exec -- mix test
```

`mix compile --force` is not redundant with `mix build`: the type checker only reports on files it
actually compiles, so an incremental build hides type problems in everything that did not change.
That is how six dead clauses were found here, none of them in a file the build had touched.

On Windows a handful of tests fail for environmental reasons (symlinks need Developer Mode, ssh
needs a remote, some paths assume a POSIX root) and the full suite can hang on the live tests.
Check whether you are looking at one of those before chasing a "regression": a useful trick is
`git stash` + rerun, which is how the eight failures in `workspace_and_config_test.exs` were
confirmed to predate a change.

## 6. When nothing happens

| symptom | cause |
|---|---|
| nothing listens on the port | `server.port` unset (see step 4) |
| no runs, ever | the tracker returns no dispatchable issues: check `active_states` against what the tickets actually say, and remember `blocked_by:` holds tickets back |
| every run fails on the first turn | the agent backend rejected an option (this happened when codex renamed an approval policy); read the first `turn_ended_with_error` rather than the last one |
| the console is blank but the API works | the LiveView socket: when served through a mount, `SYMPHONY_URL_PATH` must match the prefix, otherwise the browser dials `/live` on the wrong app |

## Test tags

A handful of tests need something the machine may not have. They carry tags, and
`test_helper.exs` excludes them on Windows so that a local run is a signal rather than noise
(CI runs on Linux, where nothing is excluded):

| tag | means | why it is excluded on Windows |
|---|---|---|
| `:needs_ssh` | the remote-worker tests | they need a resolvable ssh host; without one they sit until their timeout |
| `:needs_symlinks` | symlink-escape tests | creating symlinks needs Developer Mode |
| `:posix_paths` | tests that assume a POSIX root (`/tmp`) or a POSIX shell | the git-bash assumption does not hold; a fake `gh` stub written as `#!/bin/sh` produces no output |

Run everything anyway with:

```sh
mise exec -- mix test --include needs_ssh --include needs_symlinks --include posix_paths
```

Three failures worth knowing about, because each looked like a product bug at first:

- **Wall-clock assertions** (`assert_due_in_range`, the turn-timeout test): the remainder is
  measured after an unbounded amount of VM and OS scheduling, so a loaded machine eats the slack.
  They are widened rather than tagged, with the upper bound still exact -- a retry scheduled
  *later* than configured is the bug worth failing on.
- **A path built by `Path.join` from `System.tmp_dir!()`** mixes separators on Windows, and
  `Path.wildcard` then matches nothing at all -- which made `specs.check` inspect zero files while
  reporting success. `Path.expand` before globbing.
- **Timing tests that pass alone and fail in a full run** are the normal case, not a paradox: run
  them alone first (`mix test path/to/file.exs:LINE`) and check whether they are flaky or real.