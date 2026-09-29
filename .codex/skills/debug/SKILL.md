---
name: debug
description:
  Investigate stuck runs and execution failures by tracing Symphony and Codex
  logs with issue/session identifiers; use when runs stall, retry repeatedly, or
  fail unexpectedly.
---

# Debug

> **Differs from upstream:** this file is upstream's `debug` skill written for *this* deployment (Windows host, file tracker, host-side publishing), not for openai/symphony's POSIX one; the numbers below were measured here, and `## Differences from upstream (this host)` indexes the deviations.

## Goals

- Find why a run is stuck, retrying, or failing.

> **Differs from upstream:** the tracker is a file tracker, so the identity to correlate is a ticket
> key (`SYM-43`), not a Linear issue.

- Correlate a ticket's identity to a Codex session quickly.
- Read the right logs in the right order to isolate root cause.

## Log Sources

- Primary runtime log: `log/symphony.log`
  - Default comes from `SymphonyElixir.LogFile` (`log/symphony.log`).
  - Includes orchestrator, agent runner, and Codex app-server lifecycle logs.
- Rotated runtime logs: `log/symphony.log*`
  - Check these when the relevant run is older.

> **Differs from upstream:** this deployment passes `--logs-root`, so the live file is
> not under the checkout and the rotation is the disk-log handler's numbering.

The orchestrator writes to `--logs-root` when the deployment passes one (here:
`%TEMP%\symphony-fork-logs`), otherwise to `<cwd>/log/symphony.log`. Rotated segments sit beside it
(`symphony.log.1`, `.2`, ...); the `.idx`/`.siz` companions are the log's own bookkeeping, not text.

Read the **live** segment, which on this host is the newest file:

```powershell
$logs = "$env:TEMP\symphony-fork-logs\log"
$live = Get-ChildItem $logs -Filter 'symphony.log*' | Where-Object Extension -ne '.idx' |
        Where-Object Extension -ne '.siz' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$live.FullName
```

## Correlation Keys

> **Differs from upstream:** upstream's `issue_id` is a Linear UUID and its example key
> is `MT-625`; here the id is the tracker's own id, which for a file ticket is
> usually the key itself.

- `issue_identifier`: human ticket key (example: `SYM-43`) -- start here.
- `issue_id`: the tracker's own id (for a file ticket, usually the same string)
- `session_id`: Codex thread-turn pair (`<thread_id>-<turn_id>`)

Use them as your join keys during debugging.

> **Differs from upstream:** nothing to change here -- `elixir/docs/logging.md` is in this repository,
> so upstream's instruction applies as written.

- Applicable: align with `elixir/docs/logging.md` conventions for a log statement that is missing a
  context field; the file is `elixir/docs/logging.md` in this checkout.

## Quick Triage (Stuck Run)

### Start with the queue, not the log

> **Differs from upstream:** upstream starts at the log; the host's tracker skips a
> malformed ticket silently, so the queue is checked first -- the queue is the directory named by the
> workflow's `tracker.provider.path`.

Most "the agent is stuck" reports are really "the ticket is not a ticket". Check the file first:

```powershell
$tickets = "$env:USERPROFILE\code\symphony-work"
git -C $tickets status --short          # is it even committed?
git -C $tickets log --oneline -3

# A leading UTF-8 BOM stops the tracker's front-matter match -- the file is skipped, silently.
$b = [System.IO.File]::ReadAllBytes("$tickets\SYM-43.md")
($b[0..2] | ForEach-Object { $_.ToString('X2') }) -join ' '   # EF BB BF means: strip it
```

A ticket that the tracker cannot parse does **not** error: it disappears from the active set, so
whatever was running for it gets stopped as "moved to non-active state". If a ticket went quiet
mid-run, suspect this before anything else -- it happened on SYM-48, where the run's own edit wrote
the BOM.

Upstream's triage, with the log in hand:

1. Confirm scheduler/worker symptoms for the ticket.
2. Find recent lines for the ticket (`issue_identifier` first).
3. Extract `session_id` from matching lines.
4. Trace that `session_id` across start, stream, completion/failure, and stall
   handling logs.
5. Decide class of failure: timeout/stall, app-server startup failure, turn
   failure, or orchestrator retry loop.

## Commands

> **Differs from upstream:** `rg` does not expand a glob passed as a path argument
> (`IO error ... os error 123`), and PowerShell does not expand it either, so `rg`
> does its own globbing; `| sort -u` is replaced because PATH's `sort` is Windows
> `sort.exe` (no `-u`).

```powershell
$logs = "$env:TEMP\symphony-fork-logs\log"

# 1) Narrow by ticket key (fastest entry point)
rg -n --glob 'symphony.log*' 'issue_identifier=SYM-43' $logs

# 2) If needed, narrow by the tracker's own id for the ticket
rg -n --glob 'symphony.log*' 'issue_id=SYM-43' $logs

# 3) Pull session IDs seen for that ticket
rg -o --glob 'symphony.log*' 'session_id=[^ ;]+' $logs | Sort-Object -Unique

# 4) Trace one session end-to-end
rg -n --glob 'symphony.log*' 'session_id=<thread>-<turn>' $logs

# 5) Focus on stuck/retry signals
rg -n --glob 'symphony.log*' 'Issue stalled|scheduling retry|turn_timeout|turn_failed|Codex session failed|Codex session ended with error' $logs
```

## Investigation Flow

1. Locate the ticket slice:
    - Search by `issue_identifier=<KEY>`.
    - If noise is high, add `issue_id=<UUID>`.
2. Establish timeline:
    - Identify first `Codex session started ... session_id=...`.
    - Follow with `Codex session completed`, `ended with error`, or worker exit
      lines.
3. Classify the problem:
    - Stall loop: `Issue stalled ... restarting with backoff`.
    - App-server startup: `Codex session failed ...`.
    - Turn execution failure: `turn_failed`, `turn_cancelled`, `turn_timeout`, or
      `ended with error`.
    - Worker crash: `Agent task exited ... reason=...`.
4. Validate scope:
    - Check whether failures are isolated to one issue/session or repeating across
      multiple tickets.
5. Capture evidence:
    - Save key log lines with timestamps, `issue_identifier`, `issue_id`, and
      `session_id`.
    - Record probable root cause and the exact failing stage.

### Classify, then act

> **Differs from upstream:** upstream's four classes stop at the worker; the host's
> janitor adds a publish stage, so these classes cover the queue and publish paths.

- **Never dispatched**: the ticket is not parseable (BOM, bad YAML, unquoted colon in `title:`), its
  `state` is not in the workflow's `active_states`, or the tracker's `path` is wrong. Check the queue
  section above, then the config.
- **Dispatched, then stopped with no PR**: the ticket left the active states before the run finished.
  Look for `Issue moved to non-active state` and check whether the agent set the state before
  publishing.
- **Run finished, no PR, no publish line**: the sweep's own criteria (`in-review` **and** a dirty
  workspace or a branch without a PR) were not met; `janitor: SYM-43 not published` says so every
  round.
- **Session started and then nothing**: an app-server or turn failure. Search the same `session_id` for
  `turn_*`, `ended with error`, `Issue stalled`, and the retry lines.
- **Published but the wrong content**: `git log --oneline -3` and `git status --short` in the
  workspace under `<workspace_root>\<ticket>`; the workspace is a full clone, so its history is the
  evidence.

## Reading Codex Session Logs

> **Differs from upstream:** the file is wherever `--logs-root` puts it, not
> `log/symphony.log` (see `## Log Sources`).

In Symphony, Codex session diagnostics are emitted into the log named by `--logs-root` and
keyed by `session_id`. Read them as a lifecycle:

1. `Codex session started ... session_id=...`
2. Session stream/lifecycle events for the same `session_id`
3. Terminal event:
    - `Codex session completed ...`, or
    - `Codex session ended with error ...`, or
    - `Issue stalled ... restarting with backoff`

For one specific session investigation, keep the trace narrow:

1. Capture one `session_id` for the ticket.

> **Differs from upstream:** `rg` needs its own `--glob` here (see `## Commands`).

2. Build a timestamped slice for only that session:
    - `rg -n --glob 'symphony.log*' "session_id=<thread>-<turn>" $logs`
3. Mark the exact failing stage:
    - Startup failure before stream events (`Codex session failed ...`).
    - Turn/runtime failure after stream events (`turn_*` / `ended with error`).
    - Stall recovery (`Issue stalled ... restarting with backoff`).
4. Pair findings with `issue_identifier` and `issue_id` from nearby lines to
   confirm you are not mixing concurrent retries.

Always pair session findings with `issue_identifier`/`issue_id` to avoid mixing
concurrent runs.

### The lines that answer most questions

> **Differs from upstream:** these are the lines this host actually emits, including the
> local janitor's publish stage, which upstream's worker does not have.

```
Dispatching issue to agent: issue_id=SYM-43 issue_identifier=SYM-43
Starting agent run for issue_id=SYM-43 ...
Running workspace hook hook=after_create issue_id=SYM-43 workspace=...
Codex session started for issue_id=SYM-43 ... session_id=...
janitor: SYM-43 not published (workspace=...)          <- the sweep decided there was nothing to do
janitor: SYM-43 committed on symphony/SYM-43           <- publishing started here
janitor: SYM-43 pushed symphony/SYM-43
janitor: SYM-43 PR https://github.com/.../pull/47
Issue moved to non-active state: ... state=in-review; stopping active agent   <- the run ends HERE
janitor: SYM-43.md looks wrong: [:bom, :no_front_matter]
```

Read them as a lifecycle: dispatch, workspace hook, session start, publish, stop. **The state change is
what ends a run** -- anything the agent was told to do *after* setting `in-review` never happened, which
is why the publish tool is called before it.

## Notes

- Prefer `rg` over `grep` for speed on large logs.
- Check rotated logs (`symphony.log*` beside the live log; see `## Log Sources`) before concluding data
  is missing.
- Quote the exact lines you used, with the ticket key and the session id, in anything you report.
- There is no `make`, no `jq` (use `gh ... --jq`) and no working `python3` here; PowerShell 5.1 has no
  `&&` / `||`, so check `$LASTEXITCODE` instead.

> **Differs from upstream:** nothing to change here -- upstream also asks that missing context fields
> be aligned with `elixir/docs/logging.md`, and that doc is in this repository.

- Applicable: align new log statements with `elixir/docs/logging.md` conventions; it is in this
  checkout.

## Differences from upstream (this host)

- **File tracker, not Linear.** Upstream correlates a Linear issue: `issue_id` is a Linear UUID and
  the example key is `MT-625`. Here the tracker is the ticket directory, so `issue_id` is the
  ticket's own id (usually the same string as `issue_identifier=SYM-43`), and `SYM-43` replaces
  `MT-625` in every command.
- **The log is where `--logs-root` says.** Upstream reads `log/symphony.log` and `log/symphony.log*`
  (default from `SymphonyElixir.LogFile`); this deployment passes
  `--logs-root %TEMP%\symphony-fork-logs`, so the live file is
  `%TEMP%\symphony-fork-logs\log\symphony.log`, with `symphony.log.1`, `.2`, ... beside it. The
  `.idx`/`.siz` companions are the handler's bookkeeping, not text, and the newest file is the live
  segment.
- **Queue first, then the log.** Upstream's triage starts with recent lines for the ticket. Here a
  malformed ticket -- a UTF-8 BOM, bad YAML, an unquoted colon in `title:` -- is skipped by the
  tracker **silently** (measured on SYM-48, where the run's own edit wrote the BOM), so a ticket can
  vanish from the active set mid-run and the only symptom is a run that stopped. That is why
  `## Quick Triage (Stuck Run)` checks the queue before the log.
- **`rg` does its own globbing.** Upstream passes the log glob as a path argument
  (`rg -n "..." log/symphony.log*`). `rg` does not expand a glob passed as a path argument
  (`IO error ... os error 123`) and PowerShell does not expand it for native programs either, so the
  commands pass `--glob 'symphony.log*'` and the `$logs` directory.
- **`| sort -u` does not work.** PATH's `sort` is Windows `sort.exe`, which has no `-u`, so the
  session-id command uses `| Sort-Object -Unique`.
- **POSIX vs PowerShell.** No `make`, no `jq` (use `gh ... --jq`) and no working `python3`; PowerShell
  5.1 has no `&&` / `||`, so `$LASTEXITCODE` is checked instead.
- **This host's lifecycle lines and classes.** Upstream's four failure classes are session-level
  (stall loop, app-server startup, turn failure, worker crash) and its lifecycle list stops at the
  session. The local janitor adds a publish stage, so `### Classify, then act` and
  `### The lines that answer most questions` cover the queue and publish paths and list the lines this
  host actually emits, including `Issue moved to non-active state`, which is what ends a run.
- **`elixir/docs/logging.md`.** Applicable, not "not applicable": the doc is `elixir/docs/logging.md`
  in this repository, so upstream's instruction to align missing context fields with it applies as
  written. The three join keys above are still the contract.
- **The ticket directory is the workflow's, not a fixed path.** Upstream correlates a Linear issue and
  has no directory to read; here the queue is the directory named by the workflow's
  `tracker.provider.path` (this deployment: `C:/Users/lhl20/code/symphony-work`), so the triage
  commands read that path rather than a hard-coded ticket directory inherited from an earlier
  deployment.
