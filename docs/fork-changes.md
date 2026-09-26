# What this fork changes, and why

This repository is a fork of `openai/symphony`, used as one component of a larger setup (a
recorder that drives it over ACP and reads its observability API). The standing rule for every
change made here:

> **Do not alter Symphony's own defaults, settings or architecture. Prefer additions that are
> inert until something explicitly configures them.**

This file is the ledger for that rule: what changed, why, whether it moves a default, and how to
get upstream behaviour back. Anything not listed here should be assumed unchanged.

## Behaviour that changed for a caller

Only two engine-level changes are visible to a caller, plus the example workflow.

| # | area | change | why | affects a default? | back to upstream |
|---|---|---|---|---|---|
| 1 | `lib/symphony_elixir/specs_check.ex` | `Path.expand/1` before globbing | a path built by `Path.join/2` from `System.tmp_dir!/0` mixes separators on Windows (`C:\...\Temp/x`), and `Path.wildcard/1` then matches **nothing** -- the check read zero files and still reported "all public functions have @spec". Now it finds them. | no default moved, but it **checks more files** than before, so a tree with unspecced top-level modules can newly fail | none needed; the fix is strictly more checking |
| 2 | `lib/symphony_elixir/codex/app_server.ex` | a failed `thread/start` returns `{:error, {:thread_start_rejected, %{approval_policy: .., thread_sandbox: ..}, reason}}`; a failed `initialize` returns `{:error, {:initialize_rejected, reason}}`; both log the values sent | codex renamed an approval policy once (`reject` -> `granular`) and every run then failed before its first turn with an error that never named the option | no | callers that only match `{:error, _}` are unaffected; to restore the bare reason, return `reason` instead of the tuple |
| 3 | `elixir/WORKFLOW.md` | the example workflow now tracks GitHub Issues, drives `acp`/DSH by default (was `codex`), sets `server: {host, port}` so the observability endpoint is enabled, and carries the file tracker and ZCode routes as comments | the deployment in this workspace uses GitHub, DSH and a loopback endpoint; each was verified end to end | this is the **example file**, not an engine default -- `Config` has no built-in tracker or backend | `git show acea168:elixir/WORKFLOW.md` |

## Engine code: behaviour-preserving work

| area | change | why |
|---|---|---|
| `github/client.ex`, `gitlab/client.ex` | a guarded clause plus a `_ -> false` fallback collapsed into one clause with the guard in the body | Elixir 1.20's type checker proved the fallback unreachable (callers check presence first). Same answers for every reachable input |
| `orchestrator.ex` | deleted `terminate_task/2`'s unreachable `:ok` fallback | callers always pass a pid; the checker proved it |
| `workspace.ex` | two `case` blocks over `workspace_path_for_issue/2` collapsed into hard matches; `workspace_path_for_issue/2` gained an explicit `@spec` | for a binary `worker_host` the resolution cannot fail, so both an `{:error, _}` branch and a `_` branch were unreachable. A hard match keeps that proof in the code: it fails loudly if the proof ever stops holding |
| `agent_runner.ex`, `command_code/app_server.ex` | alias ordering; a single-clause `with` rewritten as `case`; `Enum.map/2 \|> Enum.join/2` replaced by `Enum.map_join/3`; one over-long `@type` split | `mix lint` (`specs.check` + `credo --strict`) had never run on this checkout; these were the violations it found |
| `tracker/memory.ex` | `validate_config/1` added | the behaviour marks it optional, so its absence is legal -- but Elixir 1.20's type checker warns at the dispatch site. An in-memory tracker has nothing to validate |

## Additions that are inert by default

| addition | what it is | why it cannot change existing behaviour |
|---|---|---|
| `tracker/file.ex` + `"file" =>` in `tracker.ex` | a file-backed tracker: Markdown with YAML front matter, or YAML | dispatch is a literal map lookup on `tracker.kind`; nothing selects `file` unless a workflow says so |
| `examples/file-tracker/tickets/` | a runnable example backlog | data, read only when a workflow points at it |
| `http_server.ex` `url_path/0` + `layouts.ex` | `SYMPHONY_URL_PATH` (default `""`) sets the endpoint's `url: [path: ..]` and publishes the matching LiveView socket path in a `<meta>` | empty is the default and produces exactly the previous URLs and socket path |
| `http_server.ex` warning | logs when it disables the endpoint | log output only; the `:ignore` branch is unchanged |
| `.gitattributes` | `* text=auto eol=lf` | line endings only |
| `test/` tags and `test_helper.exs` | `:needs_ssh`, `:needs_symlinks`, `:posix_paths`, excluded on win32 | test-only; CI runs on Linux where nothing is excluded |
| `docs/quickstart.md`, `docs/fork-changes.md`, README pointer | documentation | documentation |
| development reloaders (`mix.exs`, `lib/symphony_elixir_web/endpoint.ex`, `config/config.exs`) | `{:phoenix_live_reload, "~> 1.2", only: :dev}`, `listeners: [Phoenix.CodeReloader]`, the standard `if code_reloading?` block, and a `:dev`-only config block with `code_reloader: true` plus live-reload patterns | the fork had dropped the reloader the `phx.new` template installs, so every source change needed a restart. Inert by construction: `code_reloading?` is read at compile time, the config block exists only in `:dev`, the dependency is `only: :dev`, and a `MIX_ENV=test` compile contains no `Phoenix.LiveReloader` reference |
| `server.*` reloads now move the endpoint (`workflow_store.ex`, `http_server.ex` `mount_path/0`, `config/config.exs`) | `WorkflowStore` compares the endpoint's identity (port, host, port override, mount path) on every successful reload and, when it changed, restarts the `HttpServer` child through the supervisor | the endpoint reads `server.host`/`server.port` once, at start, so a workflow reload used to be silently ignored -- the last runtime setting a reload could not reach. **This one does change behaviour** (a reload can move the port), which is the point, and it is switched off in `:test` (`restart_endpoint_on_workflow_change: false`) because the suite rewrites workflows constantly. `mount_path/0` became public so the store names the same source of truth instead of duplicating the env lookup |
| `mix workflow.check` (`lib/mix/tasks/workflow.check.ex`) | validates WORKFLOW.md: the front matter against the config schema **and** the prompt body by rendering it once | a Mix task, run by hand or by the gate; it starts nothing and changes no runtime behaviour |
| `POST /api/v1/pause` / `resume`, `paused` in the snapshot (`orchestrator.ex`, `presenter.ex`, `observability_api_controller.ex`, `router.ex`) | drains the queue: no new issues are dispatched, while runs in flight keep being reconciled and can finish | nothing is paused unless the endpoint is called; the default is `paused: false`, and `maybe_dispatch/1`'s unpaused path is the original code unchanged |
| `SymphonyElixirWeb.BodyParser` (`body_parser.ex`, wired in `endpoint.ex`) | wraps `Plug.Parsers` so the failures it raises (`ParseError`, `BadEncodingError`, `UnsupportedMediaTypeError`, `RequestTooLargeError`) become 400/413/415 responses | Plug raises rather than answers, so without this a client sending malformed JSON got an exception instead of a status. Same shape as the recorder's endpoint, including the two details that cost time there: leave an already-sent connection alone, and halt after answering or the router runs the controller against a sent connection. Verified: five endpoint tests, including malformed JSON, a JSON array and a bare string |
| `POST /api/v1/tools/:tool` (`observability_api_controller.ex`, `router.ex`, `server.tracker_tools` in the schema) | runs the tracker's provider-native tool with Symphony's credentials; the request body is the tool's arguments | the same capability as the MCP server, for backends where MCP is unavailable or unwanted, and it needs no protocol support at all because an agent with a shell can `curl` it. Off by default, fails closed when the configuration cannot be read, and answers tool failures as 400/404 rather than 500. Verified with five endpoint tests, and then end to end against a live ACP session: the agent ran the documented `curl` call, the endpoint executed a real GitHub `/rate_limit` with Symphony's credentials while the agent held none, and the agent reported the number back. That session also exercised the malformed-body guard for real -- the inline JSON form is mangled by PowerShell, and the agent got a 400 `malformed_body` it could read and correct, which is why the docs now show the `--data-binary @file` form. Malformed and non-object bodies are answered with a 400 `malformed_body` rather than raising, via the `BodyParser` row below |
| `MCP.TrackerServer` + `--mcp` (`lib/symphony_elixir/mcp/tracker_server.ex`, `cli.ex`, `acp/app_server.ex`, `acp.tracker_tools` in the schema) | serves the tracker's provider-native tools as a stdio MCP server, which the ACP adapter declares to the agent when `acp.tracker_tools: true` | an ACP session has no `dynamicTools` channel, so on the ACP backend an agent could not act on the tracker at all. Off by default -- it widens what an agent may do -- and the tools still execute here with Symphony's credentials, so the token never reaches the agent. Verified: the escript builds, `bin/symphony --mcp` answers `initialize`/`tools/list`/`tools/call` over stdio, and `tools/list` returns the real `github_api` spec. **Verified end to end in a live ACP session**: the agent called `github_api` over MCP, the server ran it with Symphony's credentials, and the agent reported the real number while holding no token. Getting there needed three things I had wrong first, all now recorded in the operating notes: an absolute `command` (DSH enforces it), an `env` in the declaration (a declared server inherits nothing, and without the token it advertises zero tools), and stdout reserved for JSON (the BEAM logger was writing crash reports there, which made the client restart the server mid-call) |
| `examples/planner/` (a planner WORKFLOW, a goal ticket, a README) | a commander: a second workflow whose prompt turns one goal ticket into tickets carrying `blocked_by`, which the normal workflow then executes | examples and documentation only -- it is a `WORKFLOW.md` variant selected by the CLI's workflow-path argument, so no engine code is involved. Verified end to end with **no tracker token**: the app starts, `mix workflow.check` passes, the prompt renders, and the file tracker reports the goal ticket |
| `scripts/measure_harness_cost/` | a tool that measures what a harness costs per ticket | a script, not part of the application |

## CI and toolchain

| area | change | why |
|---|---|---|
| `mise.toml` | `elixir 1.19.5-otp-28` -> `1.20.4-otp-28` (erlang stays `28`) | 1.20 turns the type checker on; on 1.19.5 the gate cannot see dead clauses at all. `mise-action` reads this file, so the workflow needed no edit |
| `mix.lock` | `credo 1.7.16` -> `1.7.19` | 1.7.16 does not run under 1.20 at all (it raises inside `Credo.Check.Consistency.SpaceAroundOperators.Collector`) |
| `Makefile` | new `type-check` target (`mix compile --force --warnings-as-errors`), wired into `ci` after `build` | the type checker only reports on files it compiles, so an incremental build hides problems in everything that did not change -- that is how the six dead clauses above were found |

None of this changes the application; it changes what the gate checks and with which compiler.

## Notes on earlier claims

Two things written elsewhere during this work were wrong and are corrected here:

- The schema's `approval_policy` default (`granular`) is **not** a change made here; `git diff
  acea168..HEAD -- lib/symphony_elixir/config/schema.ex` is empty.
- The Makefile's `build` target is fine: `mix build` is an alias (`build: ["escript.build"]`) in
  `mix.exs`. An earlier "task not found" was a wrong-directory mistake, not a broken target.

---

# Operating the file tracker end to end (2026-09-26)

A separate deployment from the planner work above: tickets live as Markdown files in a **git
repository with a private GitHub remote**, and the fork's own `tracker/file.ex` reads them. Nothing
in this section changes engine code -- it is a `WORKFLOW.md` variant plus a host-side script. It is
written down here because every item below cost real time to find, and a fresh agent will otherwise
re-derive all of it.

Artifacts (all outside this repository except the workflow):

| artifact | where | what it is |
|---|---|---|
| `elixir/WORKFLOW.file.md` | this repo (untracked at the time of writing) | `tracker.kind: file`, `active_states: [ready, in-progress]`, `terminal_states: [done, cancelled, failed]`, a purpose-built prompt, and a publishing hook |
| `symphony-janitor.ps1` | `~/code/` (host-side, not in any repo) | the host janitor: board, ticket sync, publish sweep, GitHub Issue mirror |
| `beekeeper-tickets` | private GitHub repo | the ticket queue; only safe because it holds nothing but Markdown |
| `~/code/symphony-file-workspaces/<identifier>/` | local | one workspace per ticket, named after the identifier |

## The state machine, and why `in-progress` must be active

`orchestrator.ex`'s `reconcile_issue_state/4` has four branches:

```
terminal                          -> terminate, and clean the workspace
not routable                      -> terminate, keep the workspace
active                            -> refresh and keep going
anything else (non-active)        -> "Issue moved to non-active state", terminate, keep the workspace
```

So the third and fourth branches together force the design: **a state the agent sets while working
must be in `active_states`**, or reconcile terminates the run the instant the agent touches the
ticket. That is why `in-progress` is listed as active, and why `in-review` is deliberately in
neither list -- it is the "stop and wait for a human" state, and it works for free.

## Measured pitfalls

Each of these was hit, diagnosed and fixed here; none is a guess.

| # | symptom | cause | fix |
|---|---|---|---|
| 1 | `System.cmd("sh", ..)` -> `:enoent` | `sh` was not on `PATH`; `bash` resolved to WSL's, which cannot run a Windows command | the fork's `Shell.find_bash/0` / `find_sh/0` already pick Git's; the launcher also prepends Git's `bin`/`usr\bin` (harmless redundancy) |
| 2 | `Workspace hook timed out hook=after_create` | `hooks.timeout_ms` defaults to `60_000`, while `git clone` + `mix deps.get` needs >90s | `hooks.timeout_ms: 600000` |
| 3 | the retry reused a half-empty workspace and the agent ran with no source | after a hook timeout Windows cannot delete the partial directory (`:eacces`), so the next attempt found a directory that was non-empty but incomplete | make the hook **idempotent**: `if [ ! -d .git ]; then git clone ..; fi` |
| 4 | `{:approval_required, %{"method" => "item/commandExecution/requestApproval"}}` in an endless retry loop | `approval_policy: on-request` has no operator channel to answer it | `approval_policy: never` -- `codex/app_server.ex` auto-approves only when the policy equals `"never"` |
| 5 | a ticket **silently disappeared** from the queue (the queue just looked empty) | the file was written as UTF-8 **with a BOM**; `file.ex`'s front matter regex is `\A---`, which a BOM breaks, and a `.md` without front matter is *skipped by design* | write ticket files as UTF-8 **without** BOM. This is the failure mode `file.ex`'s own moduledoc names as the worst one, and it is reachable by any Windows editor that adds a BOM |
| 6 | `{:file_tracker_invalid_yaml, .., %YamlElixir.ParsingError{}}` | `title: Smoke test: add a marker line ..` -- an **unquoted colon** inside a plain YAML scalar | quote it: `title: "Smoke test: add a marker line .."` |
| 7 | `%YamlElixir.ParsingError{type: :invalid_unicode, message: "Invalid Unicode character at byte #156"}` | non-ASCII in the **workflow's** front matter (a Chinese comment). The workflow and the tickets go through the same parser, but only the workflow rejects it -- measured: a ticket with a Chinese title, Chinese labels and a Chinese body parses fine | keep the workflow's front matter strictly ASCII; comments go in the body or as ASCII |
| 8 | a run burned its entire budget flailing | the prompt asked for something the sandbox forbids. Three separate instances, in this order: (a) `.codex/skills/{linear,commit,push,pull,land}` references that do not exist when the hook clones a non-symphony repo; (b) a `Validation` of `mix format --check-formatted`, which compiles deps, and the sandbox can neither reach Hex nor run MSVC; (c) "commit, push and open a PR", which finding 1 below makes impossible | treat the prompt as a specification the sandbox must satisfy: every command named in a ticket has to be runnable *there*, and nothing may ask the agent to publish |

Pitfall 8 has a shape worth stating plainly, because it recurred: **anything in the prompt the agent
cannot do becomes the whole run's activity.** The agent does not skip an impossible step, it works
around it -- deleting `_build`, creating a `subst` drive, probing ACLs, trying
`http.sslBackend=openssl`. One run spent 6.4M input / 80k output tokens on pitfall 8(b).

And a corollary, learned the same way: **a ticket can be a question, and a workspace holds no answer
to it.** A ticket reading "tell me the name of the running agent" left the agent alone in a clone
with nothing to change; it read the ticket twice, searched the environment for anything named
`AGENT`/`SYMPHONY`, tried to list agents, then invented a file to patch and fought the patch tool
until it was stopped. So the prompt now says that a ticket which *asks* rather than requests is
answered in `ANSWER.md` at the workspace root: a question produces no diff, and that file is what
carries the answer back to the person, through the same publish path as any code change.

## Two structural findings

### 1. In the `workspaceWrite` sandbox the agent cannot publish

Measured, from the agent's own shell output:

```
fatal: cannot lock ref 'refs/heads/symphony/SYM-6':
       unable to create directory for .git/refs/heads/symphony/SYM-6

gh : failed to load config: open C:\Users\..\AppData\Roaming\GitHub CLI\config.yml:
     Access is denied.
```

`.git/` is read-only for the agent and `gh` cannot read its own configuration (it lives under
`%APPDATA%`, outside the workspace). So `git add`, `git checkout -b`, `git commit`, `git push` and
`gh pr create` **all fail**, no matter how `networkAccess` is set, and there is no permission to
escalate to (the agent correctly refused to try).

Consequence: the agent's job ends at "files changed and validated, ticket set to `in-review`", and
**publishing is the host's job**. A hook or a host-side sweep runs outside that sandbox and has
`.git`, `gh` and the certificate store.

### 2. `hooks.after_run` does not fire on the path that matters

`agent_runner.ex` wraps all turns in `try/after`, so `after_run` looks like the natural place to
publish. It is not:

```
agent sets the ticket to `in-review`
  -> reconcile sees a non-active state
  -> terminate_running_issue/3 -> stop_running_task/3 -> terminate_task/2
  -> Task.Supervisor.terminate_child/2  (or Process.exit(pid, :shutdown))
```

That is an **external** exit signal, and the run task does **not** set `trap_exit`, so the process is
killed without unwinding and the `after` block never runs. `after_run` is kept in the workflow for
the other path (a run that completes while the ticket is still active), but the host sweep is what
actually publishes. Both are idempotent, so they cannot double-publish.

The general lesson: **do not hang required work off `after_*` hooks in this orchestrator** until you
have checked how the run is terminated.

## The janitor, and each of its criteria

`symphony-janitor.ps1` runs every 30s and does four things. The criteria are the load-bearing part:

| phase | criterion | why exactly that |
|---|---|---|
| board | every `.md` with front matter, except `BOARD-*` and `README.md` | front matter is what makes a file a ticket; the generated view files must never be mistaken for tickets (they are not: they have no front matter, and `file.ex` skips those) |
| ticket sync | `git add -A` -> commit -> `pull --rebase --autostash` -> push | `--autostash` is what lets it run while an agent is mid-edit on a ticket file |
| publish sweep | ticket state is `in-review` **and** (workspace is dirty **or** the branch has no PR) | the second half is not redundant: if the push succeeds and `gh pr create` fails, the workspace is already clean, so a dirty-only trigger would never retry |
| Issue mirror | one GitHub Issue per ticket, id recorded back into the ticket as `issue:` | the id gives a stable link in both directions without title searching |

**Single writer per field** -- the rule that keeps this from becoming two sources of truth:

| field | written by | flows |
|---|---|---|
| `state`, `assignee_id`, discussion | the human, through the Issue | Issue -> janitor -> ticket file |
| code changes, the PR | the agent | workspace -> janitor -> branch + PR |
| the boards | the janitor alone | read-only for everyone else |

The conflict rule for `state` is what makes that work: the janitor remembers the label it last wrote,
and only treats the label as a human edit when it differs from **that** value. Without it the two
sides would fight every 30s.

## Board conventions

- `README.md` is the repository's landing page: a link bar with per-state counts, then the full table.
- `BOARD-<state>.md` is one view per state, header carrying the count; terminal states are capped at
  20 rows with a "showing 20 of N" note.
- The boards carry **no front matter**, which is both what keeps the tracker from reading them and
  what keeps the janitor from listing them.
- Everything in them is regenerated every 30s, so hand edits are lost; each file says so.

## Windows PowerShell 5.1 + `gh`: six more ways to lose time

These are host-side, but they are the difference between a working janitor and a confusing one.

| # | symptom | cause | fix |
|---|---|---|---|
| 1 | `Unexpected token '}'` from a script that looks fine | this machine runs **Windows PowerShell 5.1**, which decodes a `.ps1` as ANSI unless it has a BOM; the Chinese comments were mangled into stray quotes | save the script as UTF-8 **with** BOM. Every edit tool that rewrites the file without one breaks it again |
| 2 | a key was written twice, once of them into the ticket body | `[regex]::Replace($s, $p, $r, 1)` -- the **static** overload has no count parameter, so the trailing `1` is taken as `RegexOptions` (`1` = IgnoreCase) and *every* match is replaced | use the instance form: `([regex]$p).Replace($s, $r, 1)` |
| 3 | `Cannot convert value "5845913451" to type "System.Int32"` | GitHub comment ids exceed `Int32` | cast with `[long]` |
| 4 | `unknown flag: --> README.md\` exits 0` | PowerShell 5.1 passes a **multi-line** argument to a native command by splitting it on whitespace, so `gh` saw fragments of the body as flags; the body's backticks were also eaten as escapes | `--body-file <temp file>`, never `--body "<multiline>"` |
| 5 | every Chinese title and comment came back as mojibake | PowerShell 5.1 decodes a native command's stdout with the **console** codepage (GBK here) while `gh` emits UTF-8 | `[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)` and `$OutputEncoding` likewise, before shelling out |
| 6 | `could not add label: 'state:in-review' not found`, and the whole `gh issue create` failed | GitHub labels must exist before they can be attached | create the state labels once at startup; ignore "already exists" |

Two related notes on encodings, because they pull in opposite directions: ticket files must be UTF-8
**without** BOM (pitfall 5 above), and PowerShell scripts must be UTF-8 **with** BOM (item 1 here).
Neither is a style preference; both are forced by the reader.

## Corrections to earlier claims

- An early note said the run "used the operator's official DeepSeek API key" as a property of the
  setup. It was a property of the *default* `~/.codex/config.toml` only: `model_provider = "deepseek"`
  with no pin in the workflow. The workflow now passes
  `--config model_provider='"commandcode"' --config 'model="deepseek/deepseek-v4.1-flash"'`
  explicitly, verified from `session_meta` in the rollout (`"model_provider": "commandcode"`).
- `--profile commandcode` does **not** work on codex 0.155.1: it rejects the legacy
  `[profiles.commandcode]` table and demands the settings move to a separate
  `~/.codex/commandcode.config.toml`. The workflow deliberately does not touch that config and
  passes the same settings explicitly instead.
- The codex command string is handed to `bash -lc` (`codex/app_server.ex`'s
  `local_launch_command/1` interpolates it into `exec ..`), so **bash** does its word splitting and
  shell quoting is stripped before codex sees the TOML fragments. That is why the upstream example
  writes `'model="gpt-5.5"'` with the quotes it does.

---

# The host janitor, and why it is Elixir

The deployment above needs a process that is neither Symphony nor the agent: it keeps the ticket
repository in step with GitHub, regenerates the boards, and publishes finished work. It began as a
Windows PowerShell script and is now `mix janitor`.

| | PowerShell (`elixir/scripts/janitor.ps1`, kept for its comments) | `mix janitor` |
|---|---|---|
| arguments | one string, split by a shell | a list, never split |
| JSON | `ConvertFrom-Json` plus manual key walking | the built-in `JSON` module |
| text | explicit UTF-8 everywhere, BOM-sensitive in both directions | UTF-8 by construction |
| a hung child | hung one whole round for 62 minutes | per-call timeout that kills the process tree |
| errors | `$LASTEXITCODE` checked by hand | `{:ok, _}` / `{:error, _}` |
| tests | none possible | 23, and `mix lint` clean |

`mix janitor [--once] [--interval N] [--skip-mirror]` runs it. It deliberately does **not** start the
application: Symphony's app starts the observability endpoint, so `Mix.Task.run("app.start")` would
make the janitor fight a running orchestrator for `server.port`. It starts `:logger` and nothing
else, so the two can run side by side -- which is the normal deployment, since Symphony executes
tickets and the janitor keeps the paperwork.

The PowerShell traps are recorded here because none of them is visible from the outside, and each
one cost real time:

| # | trap | what it cost |
|---|---|---|
| 1 | a `.ps1` without a BOM is decoded as ANSI | non-ASCII comments shredded the script's syntax |
| 2 | `[regex]::Replace($s, $p, $r, 1)` -- the static overload has **no count parameter**, so the trailing `1` becomes `RegexOptions` (1 = IgnoreCase) | every match replaced; a second copy of a key ended up inside a ticket body |
| 3 | a multi-line argument to a native command is split on whitespace | `gh` read fragments of a ticket body as command-line flags |
| 4 | native stdout is decoded with the console codepage | every non-ASCII title and comment came back as mojibake |
| 5 | `$_` inside a nested `Where-Object` is the inner item | every count in the board's view bar read zero |
| 6 | `Get-Content` / `Set-Content` default encodings | mangled non-ASCII and added a BOM -- and a BOM hides a ticket from the tracker entirely |
| 7 | `Select-Object -Last N` truncates the pipe | a command that had succeeded looked like it had failed |
| 8 | a nested-quantifier regex backtracked exponentially | one command hung for two minutes |
| 9 | a native child exits but leaves its stdout pipe open | a whole round hung for **62 minutes** with no child process left alive |
| 10 | only Windows PowerShell 5.1 is present on this machine | none of the modern conveniences |
| 11 | native failures do not raise | every call needed a hand-written status check |

Three properties of the port are deliberate; do not "simplify" them away:

* **`Shell.run/3` opens a port instead of calling `System.cmd/3`.** `System.cmd` has no timeout, and
  the 62-minute hang was a child that had *already exited* -- so the only reliable escape is to hold
  the OS pid and kill the process tree (`taskkill /T /F`).
* **`Ticket.set_key/3` edits only the front-matter section** and passes `global: false`, which makes
  trap 2 structurally impossible. A test asserts that a body line repeating the same key is left
  alone.
* **The board timestamps use `time: :local`.** The first version formatted a UTC timestamp into a
  board a person reads, so every "Updated" cell was eight hours early -- and, worse, the value then
  differed from the file just written, so the board rewrote and committed itself on every round.

`mix janitor` is idempotent: a second round with nothing changed performs no action and makes no
commit. That is worth asserting whenever the mirror logic is touched, because the failure mode is a
repository that commits itself every thirty seconds.

## The janitor is also a supervised child

`janitor.enabled: true` in a workflow starts `SymphonyElixir.Janitor.Server` as the last child of
the application supervisor, where it runs the same rounds `mix janitor` runs. Off by default, like
every other addition in this fork: `init/1` returns `:ignore` when it is not enabled, so a workflow
that does not ask for it sees no new process, no new log line and no new config key in effect.

| | `mix janitor` | `janitor.enabled: true` |
|---|---|---|
| who supervises it | whatever launched it -- a terminal, a job, nothing | the application supervisor |
| if it crashes | it is gone, and nobody notices | restarted (`:permanent`) |
| if the machine reboots | nothing starts it | starts with Symphony |
| logs | its own stdout | Symphony's structured log |

The round is deliberately **synchronous** inside `handle_info/2`. The interesting question is what
bounds a round, and the answer is the per-command killable timeout in `Janitor.Shell.run/3`, not a
second deadline layered on top. A linked task would add that duplicate deadline and would also take
the server down with it when it died. Nothing calls into the server, so blocking its mailbox for a
round costs nothing.

`config/schema.ex` gained the `janitor` block, and `docs` here is the only other place that needs to
know. Two decisions worth keeping:

* **`Config.settings!/0` is read in `init/1`, not while building the child list.** The child list is
  evaluated *before* `Supervisor.start_link/2` runs, so at that moment `WorkflowStore` has not
  started and the settings cannot be trusted yet. `:ignore` from `init/1` is the idiomatic way to
  make a child conditional.
* **The server is last in the list**, for the same reason, from the other side.

### The trap that made this confusing to debug

Adding the config and restarting is not enough: **Symphony runs `bin/symphony`, an escript built
earlier.** The rebuilt source had the `janitor` block in the schema and the server module in the
tree; the running binary had neither, and an unknown top-level workflow key is **silently ignored**,
so nothing anywhere complained that `janitor.enabled: true` was doing nothing. The symptom was a
workflow that started normally and a feature that never ran.

`mix escript.build` is therefore part of changing anything under `lib/`, and the cheap check is to
compare mtimes: a binary older than the source it is supposed to contain cannot contain it.

A second, smaller confusion in the same session: the janitor *was* running, but its log line was in
`symphony.log.2` while `symphony.log.1` -- ten megabytes of an earlier run -- still looked like the
current file. Grep every file the log directory holds, or check the state file's mtime, which every
round rewrites.
