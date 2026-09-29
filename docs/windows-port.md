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
  #35 (sweep), #37 (agent's tool call) and #39/#41/#43 (probe tickets).
- The tracker is a git repository of Markdown tickets, mirrored to GitHub Issues by the janitor.

What is *not* true yet -- and it is the whole distance to upstream:

| gap | state |
|---|---|
| the agent can write git metadata (commit, branch) | **done** (`8000fdb`): `codex.git_metadata_writable` |
| the agent can authenticate to push / open a PR | **not started**: needs a credential in the child environment |
| the agent has the skills upstream's workflow assumes | **not started**: they are not delivered at all |
| the file tracker matches Linear's capability surface | **not started**: gap list in §4 |

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

## 3. Credentials: the remaining half of "the agent can publish"

`git push` is not a permission problem and no sandbox setting fixes it. The token lives in the
invoking user's Windows Credential Manager (`gh`'s `hosts.yml` on this machine has no `oauth_token`
line at all, by design: `gh auth status` reports the token as keyring-backed), and the sandbox account
is a different local user with an empty vault. `.ssh` is excluded from the sandbox's read roots, so
SSH is out too.

The only supported routes are a credential **in the child environment** (`GH_TOKEN`/`GITHUB_TOKEN` plus
`gh auth git-credential` as the git helper) or a login performed as the sandbox account itself.

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

Still open: the token itself, and the scope decision below. Until that lands, `symphony_publish` and
the janitor remain the only publishers -- which is fine, they are idempotent with the agent doing it.

**This is the one place the port makes the machine weaker**, so it is stated plainly: the token
available here (`gho_…`, scopes `repo`/`workflow`/`delete_repo`/`gist`/`read:org`) can write to every
repository it can see, and anything in the child's environment is readable by the agent. A
fine-grained PAT limited to the target repository is the honest choice for `codex.child_env`;
injecting the broad token is not.

## 4. The tracker: what "as consistent as Linear" means

Reference inventory of the Linear path (fields, reads, tool, mutations, and the gap list) is §4.1-4.3.
The target is not to clone Linear's transport -- it is to be consistent at the two layers that matter:
the **normalized issue** and the **agent tool result shape**. A full GraphQL passthrough (`linear_graphql`)
has nothing to be consistent *with* here: a file ticket's mutation API is editing the file.

### 4.1 Must hold identically (this is the actual deliverable)

1. Same normalized field set and presence rules: absent nullable field -> `nil`, absent collection ->
   `[]`. Both reads return `{:ok, list} | {:error, term}`, and an empty input list returns `{:ok, []}`
   **with no I/O**.
2. `labels` normalize identically: trim, downcase, drop blanks, uniq (`linear/client.ex:607-616`). The
   file tracker currently trims only -- a SPEC 1266-1267 deviation (`tracker/file.ex:310-321`).
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

## 5. Skills: what the agent is missing, and where they have to live

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

1. **The files are repository content** of the repository the agent works on -- here
   `lanhaolong20161111/beekeeper` (locally `ai_beekeeper/.verify_elixir`), not this fork. Committed:
   `.codex/skills/{commit,pull,push,land}/SKILL.md`, ported for this host (see the table below).
2. **The deployment prompt references them by path**, the way upstream does. That belongs to the same
   change as turning on `codex.git_metadata_writable` and `codex.child_env`, so that permissions,
   prompt and skills switch together instead of leaving a run able to do something it is told not to.

For a fresh clone to contain them, leg 1 has to be **pushed**: the workspace hook clones from the
remote, so a local commit alone is invisible to the agent. (The app-server API can also declare extra
skill roots per cwd via `skills/list`'s `perCwdExtraUserRoots`, but this fork never calls `skills/list`
and neither does upstream -- that route is out of scope, not a fallback.)

What to do with each file, from the port review:

| skill | disposition |
|---|---|
| `commit` | **port**: the capability is platform-neutral; change heredoc/temp-file to repeated `-m` (or `-F -` with UTF-8 no BOM), drop the `Co-authored-by: Codex` trailer, and never blanket `git add -A` |
| `pull` | **port nearly verbatim**: only the `$(git branch --show-current)` and the gate command change, plus a line-ending precondition (`core.autocrlf=true` with no `.gitattributes` rule turns `zdiff3` into whole-file churn) |
| `push` | **port**: `make -C elixir all` -> `mix lint` + `mix test` from `elixir/`; `/tmp` + `mktemp` + `rm` -> `$env:TEMP` + `[IO.File]::WriteAllText`; no `&&`/`||` (PowerShell 5.1 cannot parse them); keep the PR title/body discipline |
| `land` | **port a reduced version**: locate PR, mergeability, `gh pr checks --watch` + `$LASTEXITCODE`, `gh pr merge --squash`, and the reply-before-change discipline. Drop the Codex-review lore and `python3`. |
| `debug` | **port the method, retarget it**: the log is where `--logs-root` says, not `log/symphony.log`; `rg pat 'dir/*.log'` fails on Windows (rg does not glob argv, PowerShell does not glob for native tools) -- use `rg -n --glob 'symphony.log*' <pattern> <dir>`; `| sort -u` is broken because PATH `sort` is Windows `sort.exe` |
| `release` | **drop**: it bumps/tags Symphony's own repo and watches Burrito on ubuntu-24.04 |
| `linear` | **drop**: `linear_graphql` is bound only by the Linear adapter; the file tracker advertises `symphony_publish` instead |
| `land/land_watch.py` | **drop**: its three signals are Symphony's (Codex review comments, autofix head moves); `gh pr checks --watch` covers "watch CI" with no Python. If it ever runs: `python` not `python3` (the `python3` on PATH is the Store stub) and `PYTHONUTF8=1` for non-ASCII review text |

Other measured Windows facts the ported skills must respect: `make` and `jq` are absent; `gh` has
built-in `--jq`; `rg` exists (and Codex bundles one); `curl` in PowerShell is an alias for
`Invoke-WebRequest` (use `curl.exe`); `D:\Program Files\Git\usr\bin` is not on PATH, so Git-bash tools
like `mktemp`/`sort`/`grep` only work as `/usr/bin/<x>`; `bash.exe` in System32 is WSL and cannot run
Windows programs (the code already finds Git's `bash` -- `Shell.find_bash/0`).

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
  (`beekeeper` `7733061`): `commit`, `pull`, `push` (repository gate `mix precommit`, `gh --jq`,
  PowerShell exit-status checks, body files as UTF-8 without BOM) and a reduced `land`; `release`,
  `linear` and the Python watcher deliberately not reproduced. Skill discovery was measured and
  found **not** to include the workspace, so the delivery mechanism is corrected above: repository
  content plus a prompt that names the file by path.
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
