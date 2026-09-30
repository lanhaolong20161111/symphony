# The Windows port

What this fork needs to become a *Windows* port of upstream Symphony: the same architecture, the same
agent-driven git workflow, with exactly one intended difference -- a file-backed tracker instead of
Linear, and that tracker as close to Linear's capabilities as the data model can honestly carry.

This file is the plan and the record. It is written so a session that has none of the history can work
from it. Evidence is quoted with the measurement or the file it came from; anything unmeasured is
marked as such.

## 1. Where the port stands

Already true, and worth not redoing:

- The orchestrator runs on Windows: port scanning, `Shell` with a real deadline and a
  process-tree kill, the escript build, the Phoenix endpoint, the janitor, the file tracker.
- Publishing works end to end, **host-side**: the janitor commits, pushes and opens a PR, driven either
  by the ticket reaching `in-review` or by the agent calling `symphony_publish`. Measured: PRs
  #35 (sweep), #37 (agent's tool call) and #39/#41/#43 (probe tickets). Since SYM-57 the agent
  publishes inside its own session too (§3, §6 item 3); the host path stays the documented fallback.
- The tracker is a git repository of Markdown tickets, mirrored to GitHub Issues by the janitor.

What was not true when this file was first written -- the whole distance to upstream -- and where each
one stands now:

| gap | state |
|---|---|
| the agent can write git metadata (commit, branch) | **done** (`8000fdb`): `codex.git_metadata_writable` |
| the agent can authenticate to push / open a PR | **done** (`9417b04`, `d4d6019`, `08a2a31`, §3): on SYM-57 the agent pushed the ticket's branch and opened PR #63 itself |
| the agent has the skills upstream's workflow assumes | **done** (`934dbdc` in the target repository, §5): five skills, upstream's document as the spine |
| the file tracker matches Linear's capability surface | **done** (rounds 3-6, §4): the ten items of §4.1 and the emulations of §4.2 |

## 2. Git metadata: why the agent could not commit

Codex's `workspace-write` sandbox makes a checkout's git metadata read-only **by path**. The names
`.git`, `.agents` and `.codex` are a hard-coded set (`codex-rs/protocol/src/permissions.rs:36-45` at
`rust-v0.155.1`), and Windows turns them into DENY ACEs on the workspace (`add_deny_write_ace`).

Measured inside a real session (probe tickets SYM-45/SYM-46):

```
icacls .git                      S-1-5-21-…:(DENY)(W,D,Rc,DC)      (a per-root capability SID)
Set-Content .git\permission-test.txt   -> Access to the path … is denied.
git checkout -b probe/sym-47     -> fatal: cannot lock ref 'refs/heads/probe/sym-47': …
git commit --allow-empty         -> fatal: Unable to create '…\.git\index.lock': Permission denied
whoami                           -> CodexSandboxOnline
```

`whoami` is the part that explains everything else: on Windows the sandbox runs the agent as a
**separate local account** (`CodexSandboxOnline`, `windows-sandbox-rs/src/setup.rs:52-53`), so the
permission profile's `<special>:root access="read">` is not "read everything" -- a path is reachable
only if that account was granted it. That is also why `gh` could not read `%APPDATA%\GitHub CLI`, and
why neither `.ssh` nor the invoking user's Credential Manager is reachable (`.ssh` is in
`USERPROFILE_ROOT_EXCLUSIONS`).

The fix is per-path and it works: an explicit writable entry for the **same resolved path** suppresses
the carveout for that path and nothing else. Measured on SYM-47 (entry added by hand) and then
implemented as `codex.git_metadata_writable: true`, which adds the workspace's git dir **and** common
dir -- asked of git, because a linked worktree keeps its metadata outside the workspace:

```
icacls .git   -> DENY gone       write into .git -> exit 0
git checkout -b probe/sym-47   -> Switched to a new branch
git commit --allow-empty       -> [probe/sym-47 9f0e708] probe-commit
git push                       -> fatal: schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS
```

## 3. Credentials: how the token reaches git

`git push` is not a permission problem and no sandbox setting fixes it. The token lives in the
invoking user's Windows Credential Manager (`gh`'s `hosts.yml` on this machine has no `oauth_token`
line at all, by design: `gh auth status` reports the token as keyring-backed), and the sandbox account
is a different local user with an empty vault. `.ssh` is excluded from the sandbox's read roots, so
SSH is out too.

The only supported routes are a credential **in the child environment** (`GH_TOKEN`/`GITHUB_TOKEN`,
which git then receives as an `Authorization` header) or a login performed as the sandbox account
itself.

The mechanism is now in place (both keys default off, so nothing changes until a workflow asks):

- `codex.child_env: [GH_TOKEN]` -- **names only**; values are read from Symphony's own environment when
  the child is launched, so no secret is ever written into a project file. This is the deliberate
  opposite of `secret_environment_names`, which strips tracker secrets from that same child; when a
  workflow names a variable that is also a declared tracker secret, the secret wins and the refusal is
  logged (silently honouring either side is how a token leaks). A name this process does not have is
  omitted rather than passed through empty.
- `codex.git_metadata_writable: true` also passes `GIT_CONFIG_COUNT=1`,
  `GIT_CONFIG_KEY_0=safe.directory`, `GIT_CONFIG_VALUE_0=*`, which is what makes git stop refusing with
  `fatal: detected dubious ownership` (the sandbox account is not the workspace's owner).

**The mechanism grew the two pieces a push actually needs (round 14, commit `ab5bb4c`).** An entry in
`codex.child_env` is now either `"NAME"` or `"CHILD=SOURCE"`, and the mapping form is not decoration:
`gh` prefers `GH_TOKEN` over the OS credential store, so naming it that in Symphony's own environment
would move the janitor's GitHub calls onto the agent's narrower token and break the ticket mirror. So the
workflow says `child_env: ["GH_TOKEN=SYMPHONY_AGENT_TOKEN"]` -- the child gets `GH_TOKEN`, the value is
read from `SYMPHONY_AGENT_TOKEN` -- and when that source is absent the entry is simply omitted, which is
why the line could be committed before the token existed. That change also brought
`credential.helper=!gh auth git-credential`, since the sandbox account has no credential store of its own
and some credential had to be supplied at all; `d4d6019` replaced the helper program with a config header
instead. The token is the same one either way -- only the way git receives it changed.

**The token reaches git, and that closes the chain (round 15).** Three commits did it. `9417b04` made
the writable git dir keep the caller's spelling, because `Path.expand/1` lower-cases a Windows drive
letter and codex compares that entry as text. `d4d6019` traded the credential-helper program for an
`Authorization: Basic` config header and set `GIT_TERMINAL_PROMPT=0`, so a missing credential fails
instead of prompting. `08a2a31` added `http.sslBackend=openssl`, and that is the one that mattered:
SYM-56's agent reported what git actually saw, and its config *did* carry the header -- `git config --get
http.https://github.com/.extraheader` returned it, 165 chars -- while the push still died with
`schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS`. The failure is below the token:
schannel wants a TLS client credential from CryptoAPI, and the sandbox account has no loaded profile to
give it one, while the OpenSSL that Git for Windows ships needs none of that. The injected config also
lost an empty-valued `credential.helper` entry, which orphaned its key. Measured on SYM-57, which is
acceptance item 3: the agent pushed the ticket's branch (exit 0, `[new branch] symphony/SYM-57`), opened
**PR #63 itself**, and the host's `symphony_publish` answered `pushed=false, committed=false` -- nothing
left to do. `SEC_E_NO_CREDENTIALS` went from 20-22 occurrences per run to 0.

**And the behaviour without a token is measured, not assumed** (SYM-53, the first ticket to try
pushing itself). The agent committed for itself (`d754576 | Symphony Agent | docs(readme): append
symphony-agent-push marker for SYM-53`), tried `git push -u origin main`, and failed with the raw error
it then reported through `ticket_comment`:

```
fatal: unable to access 'https://github.com/lanhaolong20161111/beekeeper/':
schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS (0x8009030e)
```

It did not retry, called `symphony_publish` as the prompt says, and the host pushed the agent's commit
and opened PR #55 -- so the fallback path is real, and it is what the fork kept as the documented
fallback once the credential arrived (round 15).

**A sandbox limitation the same run exposed**: the gate -- `mix lint` (specs.check + `credo --strict`)
then `mix test`, both from `elixir/` -- **cannot compile** inside the agent sandbox
(`Mix.Sync.PubSub`'s first compile dies; round 19 measured exactly where), so the `push` skill
demanding it would have blocked every push for a reason unrelated to the change. The skill now says
to report that and continue with the check the ticket names (target repository `1df8639`); the
repository gate is re-run where it can run.

**This is the one place the port makes the machine weaker**, so it is stated plainly: the token
available here (`gho_…`, scopes `repo`/`workflow`/`delete_repo`/`gist`/`read:org`) can write to every
repository it can see, and anything in the child's environment is readable by the agent. A fine-grained
PAT, rather than that broad token, is the honest choice for `codex.child_env`. The decision taken on the
retired deployment: a fine-grained PAT with **Contents: Read and write** and **Pull requests: Read and
write**, on `lanhaolong20161111/beekeeper` only, handed over as the User-scope variable
`BEEKEEPER_AGENT_TOKEN` (never pasted into a transcript) -- the retired deployment's variable, replaced
now by `SYMPHONY_AGENT_TOKEN`: one variable serves every project, because the workflow decides which
repository the agent works on. The current workflow fills it either with one PAT set to **All
repositories** (the same two scopes, plus **Workflows: write** only if an agent will ever push
`.github/workflows/*`) or not at all, in which case the host publishes as it has all along. That was the
credential in place on the retired deployment, and SYM-57's push is the measurement that it reaches git.

## 4. The tracker: what "as consistent as Linear" means

Reference inventory of the Linear path (fields, reads, tool, mutations, and the gap list) is §4.1-4.3.
The target is not to clone Linear's transport -- it is to be consistent at the two layers that matter:
the **normalized issue** and the **agent tool result shape**. A full GraphQL passthrough (`linear_graphql`)
has nothing to be consistent *with* here: a file ticket's mutation API is editing the file.

### 4.1 Must hold identically (this is the actual deliverable)

1. Same normalized field set and presence rules: absent nullable field -> `nil`, absent collection ->
   `[]`. Both reads return `{:ok, list} | {:error, term}`, and an empty input list returns `{:ok, []}`
   **with no I/O** -- a SPEC 11.1 MUST (SPEC 1199, SPEC 1204). In the file tracker that short-circuit
   sits at both adapter entry points, ahead of path resolution, so it holds even when `provider.path`
   is missing or unreadable: an empty request is answered with `{:ok, []}`, never with
   `{:error, {:file_tracker_path_not_found, path}}`. Linear short-circuits in the same place
   (`linear/client.ex:111-113`, `127-129`).
2. `labels` normalize identically: trim, downcase, drop blanks, uniq (`linear/client.ex:607-616`).
   **Done**: the file tracker runs those same four steps in `normalize_labels/1`, so the list and the
   comma-string front-matter forms land on the same answer (SPEC 1266-1267).
3. `state` verbatim; compared trimmed + downcased only.
4. `priority` integer-or-null with Linear's 1..4-then-unknown dispatch rank. **Done in round 6**: the
   coercion is "an integer, or `nil`" -- a quoted integer is accepted because front matter is
   hand-written, and a float (or a number with anything after it) is `nil`, which is the answer
   Linear's parser gives rather than a truncation nobody asked for.
5. `blocked_by` entries are `{id, identifier, state}` maps with each key nullable, as Linear produces
   (`linear/client.ex:626-630`). **Done in round 3**: front matter accepts both the shorthand and the
   full form, and the shorthand is expanded by reading the blocker's own file:
   ```yaml
   blocked_by: [SYM-1, SYM-2]                                  # shorthand, expanded against the directory
   blocked_by: [{id: SYM-1, identifier: SYM-1, state: done}]   # Linear-shaped
   ```
   An unresolved id keeps a `nil` state, which blocks exactly as Linear's `nil` blocker state does
   (`client.ex:508-510`).
6. `dispatchable` stays explicit and is never reconstructed by the scheduler. **Done in round 3**, on
   Linear's rule: gate while a blocker is unfinished **and** the ticket is in the first `active_states`
   entry (Linear hardcodes `Todo`, `client.ex:501-503`; here the list's order decides). This replaced
   "gate in every state", which is a deliberate behaviour change.
7. `url` stays `nil` in the issue record unless the ticket declares one -- the SPEC allows `string or
   null` and inventing a URL from a repository name would be the tracker guessing at a convention it
   does not own. The janitor, which does know its repository, derives the URL for its own surfaces
   (`janitor.ex:929-931`).
8. `created_at`/`updated_at` come from front matter, RFC3339 or `nil`. Do **not** substitute file
   mtime: it flips on unrelated edits.
9. Agent tool results keep `%{"success", "output", "contentItems"}` and the "unknown tool -> structured
   failure, the session continues" rule -- for every tracker, including one that advertises no tools.
10. `secret_environment_names` stays a declared, enforced contract; `[]` for the file tracker is a
    value, not an exemption.

### 4.2 Emulated, and labelled as emulation

- **Comments** -> the reserved `## Discussion` section, one line per comment carrying the author, the
  timestamp and **the id GitHub gave the comment** (`id=<N>`, `id=0` when the URL carries none), so an
  entry can be named and edited the way a Linear comment can. **Done in round 4.** Newlines are
  flattened on the way in: a comment body must not be able to forge a `## Discussion` heading inside
  the ticket. Linear keeps comments and description separate; the file tracker's body *is* the
  description, and that stays the documented difference.
  **And the agent can write one (round 12)**: the file tracker's second tool, `ticket_comment`, appends
  to that section and answers with the id it assigned (`local-1`, `local-2`, ...). This is the one
  mutation an edit cannot do safely -- appending to the body by hand can break the ticket's structure --
  and it is the file tracker's answer to Linear's `commentCreate`, without pretending a raw GraphQL
  surface makes sense here.
- **Attachments / PR links** -> front-matter `links: [{url, title, kind: pr|url}]`, mirroring
  `attachmentLinkGitHubPR` / `attachmentLinkURL`. **Done in round 3**: when the host observes a pull
  request for a ticket -- whether it opened it or found it already open -- it records the link on the
  ticket, idempotently. The inline list is the only form it edits: a block-form `links:` is left
  untouched rather than clobbered, and a ticket that needs two pull requests at once (the multi-repo
  case in §4.3) would need a list keyed by repository rather than by URL.
- **Assignee** -> `assignee_id` front matter, already parsed. `me` is unsupported: there is no viewer
  query analogue, so the honest emulation is a configured worker identity.
- **State objects with ids** -> states stay the declared config lists; no ids in the issue record.
- **Pagination / rate limits** -> not applicable; mirror the *error contract* instead. The
  malformed-record rule is **deliberately the stricter one** and stays that way: Linear drops one bad
  candidate record from a state-list read and fails a whole id-refresh
  (`linear/client.ex:413-428, 419-421`), while the file tracker fails the entire fetch on one
  unparseable YAML file (`tracker/file.ex`'s moduledoc says why -- a `.yaml` file is an explicit claim
  to be a ticket, and a silently dropped ticket is the "empty backlog looks like no work" failure this
  module exists to avoid). The difference is documented here rather than smoothed over.

### 4.3 Out of scope, deliberately

Workflow state ids/types, teams, projects/cycles/milestones, estimates, due dates, subscribers,
parent/sub-issue hierarchy; provider identity and authorization (tokens, scopes, `viewer`/`me`); a
server query language; cursors, rate limits, retries and backoff (document "no rate limit" rather than
inventing one); webhooks; rich text, reactions, mentions. And do not make the file tracker depend on
the GitHub mirror or the janitor: the Linear path has no such dependency.

## 5. Skills: where they live, and the shape they now have

Upstream's skills are **not an orchestration feature**. Neither upstream's nor this fork's `lib/`
mentions `skills` at all; Codex discovers them per working directory, and upstream's agent works on
upstream's own repository, which contains `.codex/skills/`. Measured on a real session here: the skill
roots are `~/.codex/skills`, `~/.agents/skills` and plugin caches -- the workspace is not among them,
and none of the seven skills appeared in the session's 44-item skill list.

**Measured, and it corrected an assumption here.** A session whose own working directory contained
`.codex/skills/windows-port-probe/SKILL.md` still listed only the user-level roots (`~/.codex/skills`,
`~/.agents/skills`, the plugin caches) and never mentioned the probe ✗. So codex-cli 0.155.1 does
**not** discover skills next to the workspace, and "put them in the repository and they load" is
wrong.

Upstream does something simpler, and its own prompt shows it: it names the file **by path** --
*"when ticket reaches `Merging`, explicitly open and follow `.codex/skills/land/SKILL.md`"*. The files
live in the repository, and the workflow prompt points at them. That is why the mechanism has two
legs:

1. **The files are repository content** of the repository the agent works on -- and the deployment now
   targets this fork, so that repository is this one (the workflow file is
   `~/code/symphony-projects/symphony.md`; the retired one is archived). Committed here:
   `.codex/skills/{commit,push,pull,land,debug}/SKILL.md`, ported for this host (see the table below).
2. **The deployment prompt references them by path**, the way upstream does. That was done as one
   change together with `codex.git_metadata_writable` and `codex.child_env`, so that permissions,
   prompt and skills switched together instead of leaving a run able to do something it is told not to.

For a fresh clone to contain them, leg 1 has to be **pushed**: the workspace hook clones from the
remote, so a local commit alone is invisible to the agent. (The app-server API can also declare extra
skill roots per cwd via `skills/list`'s `perCwdExtraUserRoots`, but this fork never calls `skills/list`
and neither does upstream -- that route is out of scope, not a fallback.)

What is in each file now, and how far each one is from upstream's:

| skill | lines | state |
|---|---|---|
| `commit` | 96 | ported: the capability is platform-neutral; heredoc and temp files become repeated `-m` (or `-F -`), the `Co-authored-by: Codex` trailer is gone, and a run never blanket `git add -A` |
| `pull` | 204 | ported: the conflict path, plus the line-ending precondition (`core.autocrlf=true` with no `.gitattributes` rule turns `zdiff3` into whole-file churn) and the fresh-clone preconditions that executing it turned up |
| `push` | 190 | ported: the gate is `mix lint` (specs.check + `credo --strict`) then `mix test`, both from `elixir/` -- the fork's project root (this host has no `make`), `$env:TEMP` replaces `/tmp`, `&&`/`||` are unrolled because PowerShell 5.1 cannot parse them, the PR title/body discipline is kept -- and **a run never pushes `main`** |
| `land` | 482 | ported **in full, not reduced**: the manual loop, the helper's five exit codes and `## Review Handling` are all here, because executing the skill is what showed which of upstream's steps are load-bearing |
| `debug` | 276 | ported and retargeted (round 10): the queue before the log (a BOM or bad YAML makes a ticket vanish from the active set silently -- the SYM-48 failure), `rg`'s own `--glob`, no `| sort -u` (PATH's `sort` is Windows `sort.exe`), and the lifecycle lines this host actually emits |
| `release`, `linear` | -- | **still deliberately unported**: `release` bumps and watches upstream's own repository on ubuntu-24.04, and `linear_graphql` is bound only by the Linear adapter -- the file tracker advertises `symphony_publish` instead |
| `land/land_watch.py` | -- | **not ported as Python, and not dropped either**: its signals are now `SymphonyElixir.Land` in this fork's own code (`c5a55f2`, `b06c82d`), which also runs inside the agent sandbox (round 19) |

**All five now have one shape** (target repository `934dbdc`, with `fcbbc3a`/`1ebed53` folding `push`,
`pull` and `land` back up to upstream's content first, then corrected by execution in `b0e8fd8`,
`eba5c28`, `0b3e04a` and `1712c55`): upstream's document is the spine. Each file keeps upstream's
section order and wording where it is host-neutral, puts a one-line `> **Differs from upstream:** ...`
note directly above every changed instruction, and ends with `## Differences from upstream (this host)`,
whose bullets index those notes; an upstream instruction that cannot work here is declared "not
applicable, because ..." rather than deleted. **The line counts above are counted in the fork's own
`.codex/skills/`**, where the five skills live now -- the retired target repository's `1712c55` was the
same table's earlier reading. One correction moved with them: the gate every skill names is the fork's,
`mix lint` (specs.check + `credo --strict`) then `mix test`, both from `elixir/`. The retired target
repository gated at its root with `mix precommit`, and every gate reference in this file -- the round
log below included -- has been corrected to the fork's.

**And the rule the SYM-57 run earned** (`b0e8fd8`): that run pushed `main` first, then noticed the
convention, moved the commit to `symphony/SYM-57` and restored `main` with `--force-with-lease`
(verified afterwards: `main` is back at `934dbdc`). `push` step 3 now says a run never pushes `main`,
the Commands block carries an executable guard (`if ($branch -eq "main") { ... exit 1 }`), the Notes
repeat it, and a differences bullet records the incident -- restoring a wrong push to a shared branch
is an incident for the operator, not a recovery step to repeat.

Other measured Windows facts the ported skills must respect: `make` and `jq` are absent; `gh` has
built-in `--jq`; `rg` exists (and Codex bundles one); `curl` in PowerShell is an alias for
`Invoke-WebRequest` (use `curl.exe`); `D:\Program Files\Git\usr\bin` is not on PATH, so Git-bash tools
like `mktemp`/`sort`/`grep` only work as `/usr/bin/<x>`; `bash.exe` in System32 is WSL and cannot run
Windows programs (the code already finds Git's `bash` -- `Shell.find_bash/0`).

**Correction to an earlier note: non-ASCII front matter is not the problem; the encoding is.** This
deployment's project file carries Chinese comments *inside* its YAML front matter, and it parses --
measured directly: `workflow parsed: prompt template 6323 chars`, with `tracker.kind`, the janitor
paths and the codex keys all resolved from it. What actually failed earlier was the **writing**: a BOM
from `Set-Content -Encoding UTF8`, or UTF-16 from `>`, produces a file the loader rejects, and the error
was blamed on the Chinese. The rule to keep is "write UTF-8 **without a BOM**" (use the editor tool, or
`[IO.File]::WriteAllText($p, $s, [Text.UTF8Encoding]::new($false))`), not "keep the front matter
ASCII" -- that belief would ban legitimate comments, and one validator in this fork enforces exactly
that mistake.

**And a BOM must not cost a ticket.** Measured the hard way, on ticket SYM-48: the run edited its own
ticket with a Windows shell, the BOM broke the tracker's `\A---` front-matter match, and the ticket
**vanished from the queue mid-run** -- the run was stopped, the ticket sat at `in-progress`, and the
janitor's warning (`SYM-48.md looks wrong: [:bom, :no_front_matter]`) was the only trace. Both parsers
(`tracker/file.ex` and `janitor/ticket.ex`) now strip a leading BOM before matching, so the ticket keeps
working; `problems/1` still reports `:bom`, because whatever wrote it may have changed more than the
BOM. On a POSIX host a BOM is exotic; on Windows it is one `Set-Content` away, which is exactly why
this belongs in the port.

**One dormant POSIX script, deliberately not "fixed".** This fork's own `.codex/worktree_init.sh` is
`#!/usr/bin/env bash` and ends in `make setup`, which does not exist on this host -- and nothing in the
repository references it (no workflow, doc or example calls it). It is left alone and recorded here
instead of being ported: a script nothing runs is not a blocker, and rewriting it would have created the
impression that the worktree path is supported here, which it is not (see §2's per-clone layout and the
worktree discussion in `docs/fork-changes.md`). If a workflow ever does call it, the port is
`mix setup` from `elixir/` -- `mise trust` already works.

## 6. Acceptance

The port is done when, on this Windows machine, one real ticket run can show all of:

1. the session's sandbox lets the agent write git metadata (`codex.git_metadata_writable: true`),
2. the agent writes a commit with a real message (not the janitor's fixed one),
3. it pushes the branch and opens the pull request itself -- or, if the credential decision goes the
   other way, the run reports precisely why it could not,
4. the branch name and PR URL are recorded on the ticket,
5. the tracker exposes Linear-parity fields (labels normalization, `blocked_by` refs, explicit
   `dispatchable`, derived `url`, links),
6. `mix lint` and `mix test` are green, and this file plus `docs/fork-changes.md` describe what
   changed and how to get upstream behaviour back.

**Where that stands after the 2026-09-29/30 work** (the running service carries the credential fix and
the `land` CLI; SYM-57 and SYM-58 are the two runs that exercised this work):

| # | state |
|---|---|
| 1 | **on and demonstrated**: `codex.git_metadata_writable: true` in the deployment; SYM-50's run committed in a sandbox that had refused exactly that before |
| 2 | **demonstrated**: the agent wrote its own commit, on the ticket's branch, with a real message (`docs: append branch-fix smoke marker to README.md`) rather than the janitor's fixed `symphony/<id>: automated change` |
| 3 | **achieved** (SYM-57, `08a2a31`, §3): the agent pushed the ticket's branch itself (exit 0, `[new branch] symphony/SYM-57`), opened PR #63, and the host's `symphony_publish` answered `pushed=false, committed=false` -- there was nothing left for it to do. `SEC_E_NO_CREDENTIALS` went from 20-22 occurrences per run to 0 |
| 4 | **demonstrated live**: SYM-49 finished with `branch_name: symphony/SYM-49` and `links: [{url: ".../pull/47", title: "PR 47", kind: pr}]` on the ticket |
| 5 | **done, unit-tested**, and the BOM tolerance found by SYM-48 is fixed and re-verified live (a ticket written with a BOM now dispatches) |
| 6 | **the rule every round**: `mix lint` clean and the suite green (613 when it was last counted, before the `land` work). The audit below is item 6's other half -- what changed, and what it would take to get upstream behaviour back |

### The fork against upstream, audited

An audit of the whole tree against upstream `main`, for the record. `elixir/lib`: 28 files identical,
23 differ, 28 exist only here, **0 exist only upstream**; `elixir/test`: 19 identical, 9 differ, 29
only here, 0 only upstream. Of the 32 files that differ, **no upstream feature, clause or capability
was removed without a replacement** -- the differences are POSIX->Windows substitutions (bare
`sh`/`bash`, `/tmp`, `make`), deliberate fork decisions, or clause collapses for Elixir 1.20. Of the 57
files that exist only here, roughly 5% are upstream concerns lifted into their own modules
(`land.ex` <- `land_watch.py`, `shell.ex`, `web/body_parser.ex`), ~75% predate the port
(2026-09-21...09-28: the ACP/CommandCode backends, the file tracker, the MCP bridge, the janitor, the
console), and ~19% were added by the port itself.

### Open, found by that audit -- not fixed

1. **`elixir/test/symphony_elixir/core_test.exs` lost its retry lower bound.**
   `assert remaining_ms >= min_remaining_ms` went away when a flaky-window fix landed; only
   `remaining_ms > -60_000` remains, so a retry scheduled *immediately* instead of after its backoff
   now passes. The comment above it claims the lower edge is asserted by callers that compare two
   attempts against each other, and there are no such callers in the file.
2. **`ssh_test.exs` is excluded wholesale on Windows** by `@moduletag :needs_ssh`, which is
   over-broad: those tests use a fake `ssh` script, and one of them is pure string logic.
3. **`docs/fork-changes.md` is wrong about `granular`.** It says the `granular` approval-policy default
   "is not a change made here" and cites a command whose path is wrong; the change is commit `84428e5`
   (2026-09-21), so it *is* a fork change relative to upstream.
4. **`orchestrator.ex`: while `paused`, `maybe_dispatch/1` returns early**, so
   `reconcile_running_issues/1` and `reconcile_blocked_issues/1` -- both inside `dispatch_new_work/1` --
   do not run. That contradicts the comment above it ("reconciliation below still runs") and
   `orchestrator_pause_test.exs`'s claim; the test only asserts `claimed == 0`, so it cannot catch it.

### Accepted, not done -- the standalone recorder has no drain budget

The recorder was extracted from the retired application into its own repository, and one thing could
not move: `drain_above` was an **in-process MFA** into that application's own orchestrator
(`{AiBeekeeper.Orchestration.Coordinator, :remaining_capacity, []}`), which a standalone recorder
cannot reach. The standalone poller therefore sets no `drain_above`, and **drain is off** -- a feature
the extraction cost, not a defect anybody found and shelved.

The decision is accepted as it stands, and nothing currently depends on it: the limit it read was
always *another* orchestrator's remaining capacity, shared so that the two would not over-schedule
between them, and a standalone recorder no longer sits inside one. The fix path is known and
cheap-ish -- expose remaining capacity over HTTP and let `drain_above` be a 0-arity function that reads
it (the poller already accepts a number, a 0-arity function or an MFA, so only the budget's *source* is
missing, not the mechanism). Nobody is doing that now; this paragraph is the record, so the next
session does not re-derive why the switch has nothing behind it.

## 7. Round log

These are rounds of *work* on the port, numbered as they happened; they are not the harness's goal
rounds, which are counted separately.

- **Round 1 (2026-09-29)**: git-metadata gap measured, fixed and tested (`8000fdb`); the same run found
  the credential half (`SEC_E_NO_CREDENTIALS`) and the separate-sandbox-account explanation, both
  recorded in `docs/fork-changes.md`; the retry-window flake that failed a gate run was fixed
  (`2fa190a`); Linear and skills reference inventories collected (this file's §4 and §5); the
  child-environment mechanism written and tested (`codex.child_env` + `safe.directory`), default off;
  tracker parity started: the file tracker's `labels` now normalize exactly as the Linear adapter
  normalizes them (trim, downcase, drop blanks, uniq).
  Next: the token decision (§3), then port the four skills into the target repository (§5), then the
  rest of the tracker parity work (§4.1 item 5: `blocked_by` refs and `dispatchable`).
- **Round 2 (2026-09-29)**: the four skills written and committed in the target repository
  (`beekeeper` `7733061`): `commit`, `pull`, `push` (repository gate -- `mix lint` then `mix test` from
  `elixir/` where the skills live now; `mix precommit` when this round ran, as the note above the table
  records -- `gh --jq`, PowerShell exit-status checks, body files as UTF-8 without BOM) and a reduced
  `land`; `release`, `linear` and the Python watcher deliberately not reproduced. Skill discovery was
  measured and found **not** to include the workspace, so the delivery mechanism is corrected above:
  repository content plus a prompt that names the file by path.
  Next: the token decision (§3), the prompt/skills/permission switch as one change (§5 leg 2), then
  §4.1 item 5.
- **Round 3 (2026-09-29)**: §4.1 items 2 and 5 done -- labels normalize like Linear's (previous round)
  and `blocked_by` is now Linear's ref shape (`{id, identifier, state}`, each nullable) with the same
  dispatch rule: a blocker gates only while the ticket sits in the workflow's **first** `active_states`
  entry, a blocker whose state cannot be seen blocks, and the shorthand `blocked_by: [T-1]` is expanded
  by reading the blocker's own file through this module's normal decode path. That is a deliberate
  behaviour change: the file tracker used to gate in every state.
  Next: the token decision (§3), the prompt/skills/permission switch as one change (§5 leg 2), then the
  remaining §4.1 items (comments with stable ids, `links`, derived `url`, the malformed-record rule).
- **Round 4 (2026-09-29)**: §4.2's pull-request link done -- the janitor records `links: [{url, title,
  kind: pr}]` on the ticket whenever it observes a PR for it, which is the file tracker's counterpart
  of Linear's `attachmentLinkGitHubPR`; inline form only, idempotent, and a block-form `links:` is left
  alone rather than clobbered.
  Next: the token decision (§3), the prompt/skills/permission switch as one change (§5 leg 2), then the
  remaining §4.1 items (comments with stable ids, derived `url`, the malformed-record rule).
- **Round 5 (2026-09-29)**: comments became addressable -- each `## Discussion` entry now carries the
  id GitHub gave the comment (`id=<N>`), with newlines flattened so a body cannot forge a section. The
  remaining two parity questions were settled by decision rather than code: `url` stays `nil` unless
  the ticket declares one (the tracker does not own that convention; the janitor derives it for its own
  surfaces), and the malformed-record rule stays the stricter one, documented with its reason.
  Next: the token decision (§3) and the prompt/skills/permission switch (§5 leg 2), which together are
  the last thing between here and the end-to-end acceptance in §6.
- **Round 6 (2026-09-29)**: the last tracker parity item -- `priority`'s coercion is now "an integer,
  or nil", matching Linear's parser; a float is no longer truncated into a priority nobody wrote, and a
  quoted integer is still accepted for hand-written front matter. With that, §4.1's ten items and
  §4.2's emulations are all either implemented or documented as a deliberate decision.
  Next: §3's token decision and §5's switch (prompt + permissions + paths), then §6's end-to-end
  acceptance.
- **Round 7 (2026-09-29)**: §5's second leg done -- the deployment prompt (registry commit `2c2eb9d`)
  now states both cases, so it does not have to be rewritten on the day the sandbox keys are turned on:
  call the publish tool when the session advertises one, otherwise own the commit and the push by
  reading `.codex/skills/{commit,push,pull,land}/SKILL.md` in the repository, by path. While proving
  the prompt's own file still loads, an earlier note was corrected: non-ASCII front matter parses
  (`prompt template 6323 chars`), and the real hazard is the encoding a Windows shell writes.
  Next: §3's token decision and enabling the two sandbox keys, then §6's end-to-end acceptance.
- **Round 8 (2026-09-29)**: a live defect found and fixed by the round's own regression run. Ticket
  SYM-48's run edited its own ticket with a Windows shell, the BOM broke the tracker's front-matter
  match, and the ticket **vanished from the queue mid-run** (the run was stopped; the ticket sat at
  `in-progress`; the janitor's warning was the only trace). Both parsers now strip a leading BOM and
  `problems/1` still reports it. The same run also proved the round-7 prompt correct: the session called
  `symphony_publish`, then changed the state, and PR #45 was opened -- and after the BOM was stripped the
  ticket was re-dispatched and finished on its own.
  Next: §3's token decision and the two sandbox keys, then §6's end-to-end acceptance.
- **Round 9 (2026-09-29)**: the accumulated code changes went live -- escript rebuilt and the service
  restarted (4001, four pages 200). Two things were then verified on real tickets rather than in tests:
  a ticket written **with a deliberate BOM** (bytes `EF BB BF` first) was dispatched and completed
  (SYM-49, PR #47), which is the BOM fix working in the running system; and that same ticket came back
  with `branch_name` **and** `links: [{url: ".../pull/47", title: "PR 47", kind: pr}]` in its front
  matter, which is acceptance item 4 demonstrated end to end.
  Next: §3's token decision and the two sandbox keys (items 1-3), then the rest of §6.
- **Round 10 (2026-09-29)**: the `debug` skill is written for this deployment and committed in the
  target repository (`beekeeper` `66d2e04`) -- it starts from the queue rather than the log, because the
  BOM failure mode shows up as a run stopped mid-flight rather than as an error, and it carries the
  lifecycle lines this host actually emits. The fork's own `.codex/worktree_init.sh` was checked:
  nothing references it and it is POSIX-only, so it is recorded as dormant rather than ported.
  Next: §3's token decision and the two sandbox keys (acceptance items 1-3), then the rest of §6.
- **Round 11 (2026-09-29)**: `codex.git_metadata_writable` turned on in the deployment, and the prompt
  rewritten so the split is explicit: **the agent makes its own commit** (following
  `.codex/skills/commit/SKILL.md` by path), the host pushes and opens the PR. Enabling it immediately
  exposed an integration bug in the publish path, found by the first ticket that ran with the flag
  (SYM-50): the agent now leaves a **clean** tree, and `publish/5` only created the ticket's branch in
  the dirty case -- so it pushed the wrong ref and `gh pr create` failed with `Head sha can't be blank
  ... No commits between main and symphony/SYM-50`, leaving no PR and no link, while the log claimed
  "pushed" because it never checked git's status. Fixed (`73347b4`): the branch is created whenever HEAD
  is not already on it, and a push only logs success when git agreed. Re-verified on SYM-51: the agent's
  commit `c23bef6` ended up on `symphony/SYM-51`, PR #51 was opened, and the ticket carries
  `links: [{url: ".../pull/51", ...}]`. Acceptance items 1, 2 and 4 are therefore demonstrated live; 3
  waits on the credential decision.
- **Round 12 (2026-09-29)**: the file tracker's agent surface grew its second tool, `ticket_comment`:
  the agent can append to a ticket's `## Discussion` and the host assigns the id (`local-<n>`, kept
  distinct from the GitHub ids the janitor mirrors in). It is the one mutation an edit cannot do safely,
  and the counterpart of Linear's `commentCreate` -- not a copy of `linear_graphql`, which has nothing
  to mirror here. `Ticket.append_comment/4`, `next_local_id/1` and `comment_line/4` are pure and tested,
  and the janitor's mirrored entries now share that one line format, so the two sources cannot drift.
  Next: rebuild so the new tool is live and verify it on a ticket, then §3's credential decision for
  acceptance item 3.
- **Round 13 (2026-09-29)**: rebuilt and verified `ticket_comment` live. On SYM-52 the session called
  it and then `symphony_publish` in the same turn; the ticket's `## Discussion` now carries
  `- **agent** (2026-09-29T10:15:52.487000Z, id=local-1): ...` -- a substantive note about which
  validation it chose and why, plus what it deliberately did not run -- the agent made its own commit
  (`a961992 | codex | Add symphony comment smoke marker to README`), the host put it on
  `symphony/SYM-52`, PR #53 was opened and the link recorded on the ticket. The deployment prompt gained
  one line pointing at the tool, so a run does not have to discover it from the tool list alone.
  Next: §3's credential decision, which is the last thing between here and acceptance item 3.
- **Round 14 (2026-09-29)**: the credential channel is complete and the no-credential path is measured.
  `codex.child_env` took the mapping form (`"GH_TOKEN=BEEKEEPER_AGENT_TOKEN"`) so the host process never
  holds `GH_TOKEN` -- `gh` would otherwise move the janitor's own calls onto the agent's narrower token --
  and passing a GitHub token first also brought git's `gh` credential helper, without which an HTTPS push
  from the sandbox account seemed to have no credential at all (`ab5bb4c`; round 15's `d4d6019` replaced
  that helper with a config header, because the helper was not enough). The deployment prompt moved to upstream's
  order: the agent commits, pushes and opens the PR itself, with `symphony_publish` as the documented
  fallback. SYM-53 measured that fallback: the agent's own commit `d754576`, then
  `schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS` on its push, no retry, a call to
  `symphony_publish`, and PR #55 from the host -- plus a `ticket_comment` reporting the raw error. The
  same run found that the gate cannot compile inside the sandbox (`mix lint` then `mix test` from
  `elixir/`; `mix precommit` when this round ran, per the gate note in the skills section), and the
  `push` skill now says so (target repository `1df8639`). The target repository was pushed earlier in
  the round (`38fc8a2..e5de4c8`, after merging two commits that were already on the remote), and the
  five skills are now on `main`.
  Next: set the agent token (User scope) -- `BEEKEEPER_AGENT_TOKEN` as it was then,
  `SYMPHONY_AGENT_TOKEN` in the current workflow -- then re-run one ticket to demonstrate acceptance
  item 3.
- **Round 15 (2026-09-29)**: acceptance item 3. Three commits closed the credential chain -- `9417b04`
  (the writable git dir keeps the caller's spelling, because codex compares that entry as text and
  `Path.expand` lower-cases a drive letter), `d4d6019` (the `Authorization: Basic` config header and
  `GIT_TERMINAL_PROMPT=0`, instead of a credential-helper program) and `08a2a31`
  (`http.sslBackend=openssl`, plus the removal of an empty-valued `credential.helper` entry that
  orphaned its key). SYM-56 separated the two failures: the header *was* in the agent's git config,
  165 chars, and the push still died with `schannel: AcquireCredentialsHandle failed:
  SEC_E_NO_CREDENTIALS`, a TLS client credential the sandbox account cannot be given -- below the
  token. On SYM-57 the agent pushed (exit 0, `[new branch] symphony/SYM-57`), opened **PR #63 itself**,
  and the host's `symphony_publish` answered `pushed=false, committed=false`;
  `SEC_E_NO_CREDENTIALS` went from 20-22 occurrences per run to 0. The same run pushed `main` first
  before correcting itself, which is the next round.
  Next: the skills, which that run also showed to be too thin to read literally.
- **Round 16 (2026-09-29)**: the five skills were rebuilt on upstream's document instead of on our
  reading of it (`934dbdc` in the target repository, after `fcbbc3a` and `1ebed53` folded `push`, `pull`
  and `land` back up to upstream's content). All five now share one shape: upstream's section order and
  wording where host-neutral, a one-line `> **Differs from upstream:** ...` note above every changed
  instruction, a closing `## Differences from upstream (this host)` that indexes them, and "not
  applicable, because ..." for upstream instructions that cannot work here. The same round shipped the
  rule SYM-57 earned (`b0e8fd8`): a run never pushes `main` -- step 3, an executable guard in the
  Commands block, the Notes, and the incident recorded as a difference.
  Next: execute `pull` and `land` for real instead of reading them.
- **Round 17 (2026-09-29)**: `pull` and `land` were executed, not read. A verifier played the executor:
  it built an actual conflict and ran `pull/SKILL.md` step by step, then ran `land/SKILL.md`'s manual
  loop against a real open PR up to (not including) the merge. Both were unusable as written, and all
  of it is now fixed in the skill text (`b0e8fd8`, `eba5c28`):
  - `pull` step 7's bare `git commit` opened `core.editor` -- VS Code with `--wait` on this host -- so
    the merge commit never happened; it is `--no-edit` now, with `git merge --continue` named as the
    same code path.
  - `pull` step 8 assumed a prepared checkout: a fresh clone stops at
    `** (Mix) Can't continue due to errors on dependencies` until `mix setup` has run.
  - A fresh clone has no committer identity here (the repository's identity is *local* config), so
    `git commit` stops with `Author identity unknown`; that is a precondition now.
  - `land`'s wait for a `## Codex Review` comment was an **unbounded loop placed before the check
    step**, and this repository has no producer for that comment, so a literal run never reached CI or
    the merge; it is bounded at 120s now.
  - `land`'s `gh api ... --jq` program fails under PowerShell 5.1 (`gh: accepts 1 arg(s), received 3`);
    the replacement uses `ConvertFrom-Json`. `## Review Handling`'s bare `{owner}`/`{repo}` are parsed
    as a script block by PowerShell and needed quotes.
  - `$bodyFile` was used by the merge command but never assigned; the `UNKNOWN` mergeability re-check
    discarded its result and read only `mergeable` while the helper also uses `mergeStateStatus` (both
    are assigned back and bounded now).
  - The helper's documented invocation was wrong twice: `mix run` boots the application and died at
    `** (EXIT) :missing_github_token` printing nothing (it needs `--no-start`), and the relative
    `symphony\elixir` does not resolve from this repository -- it is a sibling of `ai_beekeeper`.
  - The helper's exit 2 is broader than the manual loop's detector: on the clean, mergeable PR #63 it
    reported 2 because a Codex bot's *usage-limit* notice counted as feedback.
  Next: narrow exit 2 in the helper, and fix the promise the skill makes about it.
- **Round 18 (2026-09-29/30)**: exit 2 was narrowed in code, and a promise was corrected instead
  (`a784d98`; target repository `0b3e04a`). In `SymphonyElixir.Land`, when no `@codex review` request
  has ever been made, a Codex-bot comment now counts only if it carries the `## Codex Review` marker
  (`is_nil(request_at) -> codex_review?(comment)`) -- fail-closed both ways, with two new tests. Why it
  was a deadlock: the filter compares only against `request_at`, so without one, whatever it kept was
  permanent and no acknowledgement could ever age it out. The `land` skill's `## Review Handling` had
  promised the opposite, in upstream's own words ("unresolved until a newer `[codex]` issue comment is
  posted acknowledging the findings"); that sentence was corrected in the skill rather than in the
  helper (`0b3e04a`), because an acknowledgement is written *before* the fix exists while a new review
  request is written *after* the commits land -- so the request is the safer gate. Do not change the
  helper back.
  Next: the land watcher, still the last structural difference from upstream.
- **Round 19 (2026-09-29/30)**: the land watcher moved inside the agent sandbox, which closes that last
  structural difference (`42e7588`; skill `1712c55`): `main/1` on `SymphonyElixir.Land`, `mix.exs`
  selecting the escript by `SYMPHONY_ESCRIPT=land`, a new `mix escript.land` task, and `bin/land` built.
  Proven by a real run (SYM-58) and reproduced independently with `codex sandbox <cmd>`:
  `escript C:\Users\lhl20\Desktop\android_cli_demos\symphony\elixir\bin\land` prints
  `Waiting for CI checks...` on stdout and `land watch failed: gh exited 1: no pull requests found for
  branch "main"` on stderr, exit 1. A bare `bin\land` cannot work (on Windows the file has no executable
  extension); the no-build alternative is `elixir -pa
  <fork>\elixir\_build\dev\lib\symphony_elixir\ebin -e SymphonyElixir.Land.cli()`. The skill's
  "host-side only" claim is gone, and `host-side` no longer appears in it. The same round measured why
  `mix` cannot compile in the sandbox, correcting two earlier guesses (TEMP permissions, and "dies
  before any task runs"): `mix.bat --version` exits 0 and prints Mix 1.20.4, and it dies at the **first
  compile**, in `Mix.Sync.PubSub` -> `Mix.Utils.detect_user_id!/0` -> `File.mkdir_p!/1` returning
  `{:error, :enotdir}`, because `File.mkdir_p/1` walks up to the drive root and requires every ancestor
  to stat as a directory, while in the sandbox `File.stat("C:\Users\lhl20")` is `{:error, :eacces}`.
  TEMP itself is writable and carries a `Modify` ACE for `CodexSandboxUsers`, so **no TEMP redirect
  helps** -- not even to a workspace path, which is under the same profile directory (SYM-55 set
  `TEMP`/`TMP`/`TMPDIR` to a workspace directory and reproduced the same `not a directory`);
  `MIX_OS_CONCURRENCY_LOCK=0` does not help either, because it disables `Mix.Sync.Lock`, not the PubSub
  path. The escript and `elixir -pa` forms work because neither compiles, so neither calls
  `File.mkdir_p`. `mix.ps1` is additionally blocked by PowerShell's execution policy, which is why
  `mix.bat` is the form used.
  Next: the audit of the whole tree against upstream, and whatever it finds.
- **Round 20 (2026-09-30)**: the whole-tree audit against upstream `main` (numbers and evidence in §6's
  "The fork against upstream, audited"), and the four open items it found, recorded there as open
  rather than fixed. Two of the four are the port's own: `core_test.exs` lost its retry lower bound in
  a flaky-window fix, and `ssh_test.exs` is excluded wholesale by `@moduletag :needs_ssh` although its
  tests use a fake `ssh` script.
  Next: the four items in §6 -- none of them is the credential path, which is closed.
