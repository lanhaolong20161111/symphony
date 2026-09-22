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

### Intervening

Four verbs, no more:

| verb | effect |
|---|---|
| `POST /api/v1/refresh` | poll the tracker now instead of waiting for the next interval (202) |
| `POST /api/v1/pause` | stop taking on new work; runs already in flight keep going, and are still reconciled -- a drain, not a freeze |
| `POST /api/v1/resume` | start taking on new work again |
| *edit the tracker* | move an issue to a terminal state to stop its run -- note this also removes the workspace (see Operating notes) |

`GET /api/v1/state` reports `paused`, so the flag is observable rather than something you have to
remember setting.

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
GITHUB_TOKEN=workflow-check mise exec -- mix workflow.check   # config + prompt template
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

## Giving an ACP agent the tracker tools

A Codex app-server turn can be handed tools directly (`dynamicTools`). An ACP session cannot: its
tool channel is MCP, so the tools have to arrive as an MCP server. Measured against DSH (see
`examples/mcp_declaration_probe.exs` in the ACP SDK), the declaration it honours is a **stdio
entry** -- `%{"command" => ...}` -- not the `type: "acp"` tunnel variant: with the tunnel form the
handshake succeeded and `mcp/connect` never arrived.

So Symphony serves its own tracker tools over stdio:

```sh
mise exec -- mix escript.build                     # produces bin/symphony
# in WORKFLOW.md:
#   acp:
#     tracker_tools: true
```

With that on, an ACP agent sees the configured tracker's provider-native tools -- for GitHub, a
single `github_api` tool -- and calls them like any other MCP tool. The call is executed **here**,
by `Tracker.execute_bound_agent_tool/4` with Symphony's own configuration: the agent sends a tool
name and arguments, and never receives the tracker token. That is the same boundary the Codex path
draws, reached a different way.

Off by default, because it widens what an agent may do to the tracker. The server itself is
`bin/symphony --mcp [WORKFLOW.md]`, which is also usable by hand:

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | bin/symphony --mcp
```

It deliberately does not start the application -- the tracker adapter is a plain module and the
configuration comes from the workflow file -- so it cannot put a second Orchestrator on the same
tracker as the instance that spawned it.

## Assigning work from a commander

`Orchestrator` is the only thing that decides what runs -- how many at once, what waits, what
retries -- but it does not invent work: its input is the tracker, and its output is one agent run
per dispatchable ticket. So "let a commander hand out the tasks" is not a missing feature; it is a
**second workflow whose job is to write tickets**.

`examples/planner/` is a runnable one: a goal ticket in, tickets with `blocked_by` out, then the
normal workflow executes them in order. Its README records the two things that bite -- the ticket
path must be **absolute** (each agent works in its own clone, so a relative path resolves inside a
throwaway checkout), and dependencies exist only on the **file tracker**, which is why the example
is file-backed.

What the agents themselves can do depends on the backend, and this is easy to get wrong. The
tracker adapters advertise a provider-native tool -- GitHub's is `github_api`, a general REST call
**executed server-side with Symphony's credentials** -- so on the **codex** backend an agent can
file issues itself. The **acp** backend has no dynamic-tool channel at all, so under ACP (the
default here) the only way an agent creates work is by writing files. Stripping the tracker token
out of the agent's environment and offering it a mediated tool are two different things: the first
does not remove the capability when the second is present.

## What reloads, and what does not

| change | takes effect | how |
|---|---|---|
| a module, template or route | as you save | the dev reloaders (see below); run `iex -S mix phx.server` |
| `WORKFLOW.md`: tracker, polling, agent limits, hooks, workspace root, prompt | within a second | `WorkflowStore` polls the file and keeps the last good copy, so a broken edit cannot take a running instance down |
| `WORKFLOW.md`: `server.host` / `server.port` | within a second | the store notices the endpoint's settings changed and bounces that child through the supervisor -- measured moving a running instance from 4002 back to 4001 without restarting the application |
| `SYMPHONY_URL_PATH` | on the next endpoint bounce or restart | read from the environment when the endpoint starts, so any later bounce picks a changed value up |
| anything in `config/*.exs` | never | restart. On a running node, `Application.put_env/3` is the only way to move a setting |
| `mix.exs`, dependencies, `code_reloader` itself | never | restart. `code_reloading?` is a compile-time macro, so the reloader plugs are baked into each build |

## Development reloaders

Run the console with `iex -S mix phx.server` rather than `mix phx.server`: same reloaders, plus a
shell in which you can inspect and patch the running system (`recompile()`, `:sys.get_state/1`,
`Supervisor.restart_child/2`).

Symphony's endpoint now carries Phoenix's two development reloaders, the same way `phx.new`
generates them. Two halves are needed and **neither works alone**:

- `config/config.exs` sets `code_reloader: true` and the `live_reload` patterns, in a `:dev`-only
  block;
- `lib/symphony_elixir_web/endpoint.ex` has the matching `if code_reloading?` block with the
  reloader's socket and plugs, and `mix.exs` registers `Phoenix.CodeReloader` as a Mix listener --
  without the listener the reloader still compiles on the next request, but nothing is pushed to
  the browser, so live reload never fires (Mix says so in a warning if it is missing).

Three things to know:

- **`code_reloading?` is compile time.** It is a macro, so the plugs are baked into the compiled
  endpoint: changing `code_reloader` needs a recompile, not just a restart, and that is why the
  dependency is `only: :dev` and the block is absent from `mix test` and from releases (verified:
  a `MIX_ENV=test` compile contains no reference to `Phoenix.LiveReloader`).
- **`config/*.exs` still never reloads.** Only modules and templates do. To change a setting on a
  running node, `Application.put_env/3`; to change the workflow, edit `WORKFLOW.md` (polled every
  second).
- **Dependencies and `mix.exs` need a restart**, as always.

## Poking a running node

`HttpServer` is a direct child of `SymphonyElixir.Supervisor`, so the observability endpoint can be
stopped and started on its own -- which is how a `server.host` / `server.port` change takes effect
without restarting the application:

```elixir
Supervisor.which_children(SymphonyElixir.Supervisor)          # find the child id first
:ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.HttpServer)
{:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.HttpServer)
```

Measured, not assumed: with that pair the port is listening, not listening, listening again.

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

## Operating notes

Four behaviours that are easy to get wrong, and that no error message will tell you about:

**A reload is not a restart.** `WORKFLOW.md` is polled every second and takes effect without one
(`WorkflowStore` keeps the last good copy, so a broken edit cannot take a running instance down).
But not everything is read per use: the observability endpoint's `server.host` / `server.port` are
read once in `HttpServer.start_link/1`, and `SYMPHONY_URL_PATH` is read at boot. Changing those
needs a restart, and nothing will say so.

**Cancelling a run discards its workspace.** Moving an issue to a terminal state stops the running
agent (`terminate_running_issue/3`), and for a *blocked* issue it also releases the claim and
removes the workspace. The `before_remove` hook does run, so a PR-cleaning hook is fine, but
anything uncommitted in that workspace is gone -- "mark it done to stop it" is a destructive way to
pause, not a gentle one.

**Coming back from blocked means starting over.** A run that needs input goes to `blocked`;
clearing it means moving the issue out of a terminal state, which re-dispatches it -- and the
workspace went with the cancel above. The prompt says "resume from the current workspace state",
which is true within a run's turns, not across a cancel. If you want an agent to continue, add to
the issue and leave its state alone.

**A workspace that exists is assumed usable.** `ensure_workspace/2` returns an existing directory
as-is, and hooks run under `hooks.timeout_ms` with the task killed on timeout -- so a hook that
timed out half way through `git clone` leaves a workspace the next run will happily work in. If a
run fails strangely early, delete its workspace directory and let it be recreated.

**Workspace cleanup is not continuous.** At boot, `run_terminal_workspace_cleanup/0` removes the
workspaces of issues already in a terminal state; after that, nothing collects them. Workspaces of
issues that never reach a terminal state, or that fail before one, are yours to remove.