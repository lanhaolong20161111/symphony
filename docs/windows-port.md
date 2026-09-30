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
- The agent's own GitHub credential is a **GitHub App installation token minted per run** (§3): the
  child receives `GH_TOKEN` and nothing long-lived sits in its environment, and a four-ticket run on
  2026-09-30 had every run push its branch and open its own pull request.
- The tracker is a git repository of Markdown tickets, mirrored to GitHub Issues by the janitor.
- The deployment drives **this fork**: the registry directory `~/code/symphony-projects/` holds
  `symphony.md`, whose target repository is this one, and the retired deployment's `beekeeper.md` sits
  in the same directory under `archive/` -- readable, and no longer a project, because the registry
  lists `*.md` in the directory root. The console that began as one project with no management is now
  a multi-project control plane: §7-§12.

What was not true when this file was first written -- the whole distance to upstream -- and where each
one stands now:

| gap | state |
|---|---|
| the agent can write git metadata (commit, branch) | **done** (`8000fdb`): `codex.git_metadata_writable` |
| the agent can authenticate to push / open a PR | **done, twice over** (`9417b04`, `d4d6019`, `08a2a31`, then `ea65cf1`, `4f43689`, §3): SYM-57 did it with a long-lived token, and the four-ticket run of 2026-09-30 did it with a per-run GitHub App installation token (`ghs_`) |
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

**The credential is now a GitHub App, and it is minted per run (round 22).** `ea65cf1` added
`SymphonyElixir.GitHubAppToken` (`elixir/lib/symphony_elixir/github_app_token.ex`). It signs a
short-lived JWT itself with OTP's `public_key` -- no `openssl`, no `gh`, no new dependency -- with
`iat = now - 60s` and `exp = now + 540s` (`:69-70`), discovers the installation (or takes one, or
selects by account, refusing to guess when several match), exchanges it for an installation token,
and caches it in `:persistent_term` under a key that records which App it belongs to, so a second App
cannot be served the first one's token (`:84`, `:150-173`). A cached token is reused while more than
the refresh slack -- 300 seconds -- is left on it, which is the margin for a push that begins just
before expiry (`:72-74`, `:160`). Every failure is a value rather than a raise: a key that cannot be
read, one that will not decode, a signing failure, an API that refuses or answers nonsense, a missing
or ambiguous installation (`@type error`, `:93`).

`4f43689` wired it into the run. `codex.app_token` names the App and its key
(`config/schema.ex:314-370`), the mint is an injection point so the tests need neither a key file nor
a network, the child's environment receives the token as `GH_TOKEN` -- whichever name the workflow
mapped in `child_env`, and when `app_token` is configured that mapping is not passed through, with a
warning (`codex/app_server.ex:288-291`, `:334`) -- and the git credential header receives the same
token, because the header cannot be built from an environment-variable name. A mint that fails fails
the run with the reason; falling back to a long-lived credential would quietly undo the reason for
configuring the App at all (`:463-515`). Verified against the real App, not a stub: the JWT was
accepted, the installation (166465349 on the account) was found, a token was minted, and that token
then listed **44 repositories** -- which is also the check that the installation covers repositories
created later, so no per-repository setup is needed as repositories are added. That number stands on
`ea65cf1`'s record rather than on a fresh measurement here: the operator's own `gh` token cannot list
App installations (HTTP 403, tried 2026-09-30), which is itself a small argument for the App being the
only credential that can see what it was granted.

**And the four tickets that exercised it (round 22).** Two throwaway projects, `e2e-alpha` and
`e2e-beta` (`~/code/symphony-projects/e2e-alpha.md`, `e2e-beta.md`), two tickets each, one instance per
project with `max_concurrent_agents: 1`. All four runs did the whole chain themselves: the agent
committed, pushed its own branch and opened its own pull request with an App installation token --
every ticket's own comment reports the credential prefix `ghs_` -- and the host's `symphony_publish`
answered `pushed=false, committed=false`, i.e. there was nothing left for it to do. Each pull
request's head SHA equals its workspace's HEAD, checked against GitHub on 2026-09-30: alpha#1
`10fd0f5`, alpha#2 `420cc28`, beta#1 `24a7ac1`, beta#2 `edac4cf`. All four were then merged: `#2` in
each repository cleanly at 12:10Z, and `#1` in each at 12:12Z only after the branch was updated from
the trunk -- the conflict path `land/SKILL.md` describes, exercised for real, with the merge commit
left in the branch's history. The four runs' input tokens, summed from the four codex rollouts in
`~/.codex/sessions/2026/09/30/`, are 271,737 + 324,472 + 267,216 + 408,459 = **1,271,884**, which is
the "roughly 1.27M" the run is remembered by.

**Which endpoint, and how that is known.** The workflow says `model_provider='"deepseek"'` and
`model="deepseek-flash"` (`e2e-alpha.md:163`), each rollout's `session_meta` carries
`"model_provider":"deepseek"`, and `~/.codex/config.toml:86-89` defines that provider as
`base_url = "https://api.deepseek.com/"`. That is **configuration resolution, not an observation of
the wire**: no request or response was captured, so "the official DeepSeek endpoint" is what the
configuration resolves to, and it is recorded here in exactly those terms.

**What it replaced, and what that costs.** The earlier credential was a long-lived personal access
token: first a fine-grained PAT scoped to the retired repository and handed over as the User-scope
variable `BEEKEEPER_AGENT_TOKEN`, then one variable for every project, `SYMPHONY_AGENT_TOKEN`
(**Contents: Read and write** and **Pull requests: Read and write**, plus **Workflows: write** only if
an agent will ever push `.github/workflows/*`). It is the credential SYM-57 measured. It still exists
on this machine -- both User-scope variables are present, 93 characters each, checked 2026-09-30 -- and
it can be revoked, because every workflow in the registry now names `codex.app_token.private_key_path`
instead: `symphony.md:194-196` and the two e2e workflows. The variable survives only in the comments
that describe the older mechanism. That history is kept rather than deleted, because it explains the
`SEC_E_NO_CREDENTIALS` paragraphs above. The security property is better than it was, and still worth
stating: an hour-long installation token is scoped to whatever the installation was granted and no
long-lived secret sits in the child's environment, but the installation's grant is the whole grant --
those **44 repositories** are writable by anything holding that token, and anything in the child's
environment is readable by the agent.

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
    value, not an exemption. **It was declared and then discarded twice over** -- absent from the
    tracker embed's cast list, and overwritten by the adapter-derived value during finalisation -- so a
    workflow that set it got silence; `19c8e15` casts it, combines it with the derived names rather
    than replacing them (the derived names are a safety property and the configured ones additional,
    so the result is their union), and refuses a value that is not a list of non-empty strings with the
    setting named instead of quietly emptying it. The unconfigured path is unchanged, and a test pins
    that for two adapter kinds (`config/schema.ex:106`, `:124`, `:849-850`, `:878`).

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
| `commit` | 67 | ported: the capability is platform-neutral; heredoc and temp files become repeated `-m` (or `-F -`), the `Co-authored-by: Codex` trailer is gone, and a run never blanket `git add -A` |
| `pull` | 178 | ported: the conflict path, plus the line-ending precondition (`core.autocrlf=true` with no `.gitattributes` rule turns `zdiff3` into whole-file churn) and the fresh-clone preconditions that executing it turned up |
| `push` | 146 | ported: the gate is `mix lint` (specs.check + `credo --strict`) then `mix test`, both from `elixir/` -- the fork's project root (this host has no `make`), `$env:TEMP` replaces `/tmp`, `&&`/`||` are unrolled because PowerShell 5.1 cannot parse them, the PR title/body discipline is kept -- and **a run never pushes `main`** |
| `land` | 422 | ported **in full, not reduced**: the manual loop, the helper's five exit codes and `## Review Handling` are all here, because executing the skill is what showed which of upstream's steps are load-bearing |
| `debug` | 217 | ported and retargeted (round 10): the queue before the log (a BOM or bad YAML makes a ticket vanish from the active set silently -- the SYM-48 failure), `rg`'s own `--glob`, no `| sort -u` (PATH's `sort` is Windows `sort.exe`), and the lifecycle lines this host actually emits |
| `release`, `linear` | -- | **still deliberately unported**: `release` bumps and watches upstream's own repository on ubuntu-24.04, and `linear_graphql` is bound only by the Linear adapter -- the file tracker advertises `symphony_publish` instead |
| `land/land_watch.py` | -- | **not ported as Python, and not dropped either**: its signals are now `SymphonyElixir.Land` in this fork's own code (`c5a55f2`, `b06c82d`), which also runs inside the agent sandbox (round 19) |

**All five now have one shape** (target repository `934dbdc`, with `fcbbc3a`/`1ebed53` folding `push`,
`pull` and `land` back up to upstream's content first, then corrected by execution in `b0e8fd8`,
`eba5c28`, `0b3e04a` and `1712c55`): upstream's document is the spine. Each file keeps upstream's
section order and wording where it is host-neutral, puts a one-line `> **Differs from upstream:** ...`
note directly above every changed instruction, and ends with `## Differences from upstream (this host)`,
whose bullets index those notes; an upstream instruction that cannot work here is declared "not
applicable, because ..." rather than deleted. **The line counts above are the fork's own
`.codex/skills/`, measured 2026-09-30** -- `commit` 67, `pull` 178, `push` 146, `land` 422, `debug`
217, against upstream's 59, 90, 93, 200 and 92 at `be10a1b`, so every ported file is longer than the
document it is based on. The retired target repository's `1712c55` was an earlier, wrong reading of the
same table. One correction moved with the skills from that repository: the gate every skill names is
the fork's, `mix lint` (specs.check + `credo --strict`) then `mix test`, both from `elixir/`. The
retired target repository gated at its root with `mix precommit`, and every gate reference in this
file -- the round log below included -- has been corrected to the fork's. The fork's copies are not new
files: upstream's own `main` ships `.codex/skills/{commit,push,pull,land,debug}/SKILL.md` (they arrive
with `be10a1b`, the commit this fork is based on), and `e592ebe` **replaced their content in place**
with the Windows-adapted versions -- so the diff against upstream is the port, not an added directory.

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

**Three incidents in this batch were one family, and they produced the rule the batch now follows.**
PowerShell 5.1's `Get-Content`/`Set-Content` default to the ANSI code page and re-encode the whole file
between them; an agent edited its own ticket with that pair, the ticket came back not valid UTF-8, and
replaying CP936 decode-and-encode over the last good revision reproduces the damaged commit with **zero
differing bytes** (`4fd8f70`; the damaged file and its two revisions are in
`~/code/symphony-e2e-alpha-work/ALPHA-2.md`). Erlang encodes a spawned process's arguments through the
same ANSI code page, so a Chinese label handed to `gh` arrived mangled and the mirror could never add
it -- every round, for every state change (`1ea2391`; the vocabulary that leaves the process is ASCII
now, the console's own Chinese is untouched, and a missing label is created on demand rather than
failing the whole mirror). And twice, editing these very documents with a shell -- a block replacement
that left an orphan line, and an `Add-Content` that introduced a stray carriage return -- broke a file
(`3ad7c04`, whose own commit message records the third incident). The rule now applied, here and in the
batch's commits: **write text files whole, or verify the read before writing; never perform line
surgery through a bare write call.**

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
the `land` CLI; SYM-57 and SYM-58 exercised that work, and the four-ticket run of 2026-09-30 exercised
the App credential end to end):

| # | state |
|---|---|
| 1 | **on and demonstrated**: `codex.git_metadata_writable: true` in the deployment; SYM-50's run committed in a sandbox that had refused exactly that before |
| 2 | **demonstrated**: the agent wrote its own commit, on the ticket's branch, with a real message (`docs: append branch-fix smoke marker to README.md`) rather than the janitor's fixed `symphony/<id>: automated change` |
| 3 | **achieved** (SYM-57, `08a2a31`, §3): the agent pushed the ticket's branch itself (exit 0, `[new branch] symphony/SYM-57`), opened PR #63, and the host's `symphony_publish` answered `pushed=false, committed=false` -- there was nothing left for it to do. `SEC_E_NO_CREDENTIALS` went from 20-22 occurrences per run to 0. **Re-achieved on all four tickets of the 2026-09-30 run, with the App credential** (§3): each agent pushed its own branch and opened its own PR with a `ghs_` token, each PR's head SHA equalled its workspace's HEAD, and the host's publish tool answered `pushed=false, committed=false` on each |
| 4 | **demonstrated live**: SYM-49 finished with `branch_name: symphony/SYM-49` and `links: [{url: ".../pull/47", title: "PR 47", kind: pr}]` on the ticket |
| 5 | **done, unit-tested**, and the BOM tolerance found by SYM-48 is fixed and re-verified live (a ticket written with a BOM now dispatches) |
| 6 | **the rule every round**: `mix lint` clean and the suite green -- re-measured 2026-09-30 at `b03d3c5`: `mix test` in `elixir/` exits 0 with **912 passed, 6 skipped, 23 excluded** (excluding `:needs_symlinks`, `:needs_ssh`, `:posix_paths`), 261.0s, which is exactly the figure `b03d3c5` itself reports (the previous batch's reading was 796 passed). The audit below is item 6's other half -- what changed, and what it would take to get upstream behaviour back |

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

### Open, found by that audit

One of the four it found is still open; the other three were closed later the same day, and are
recorded here in the form they were closed in rather than left standing as open items.

1. **`orchestrator.ex`: while `paused`, `maybe_dispatch/1` returns early**, so
   `reconcile_running_issues/1` and `reconcile_blocked_issues/1` -- both inside `dispatch_new_work/1` --
   do not run. That contradicts the comment above it ("reconciliation below still runs") and
   `orchestrator_pause_test.exs`'s claim; the test only asserts `claimed == 0`, so it cannot catch it.
   Re-read on 2026-09-30: the early return and the comment are both still there.

The three closures: `elixir/test/symphony_elixir/core_test.exs`'s retry lower bound is back
(`0775e09`), anchored to a monotonic clock read *before* the test triggers the exit that arms the
retry, which is what makes it exact with no margin -- the false comment and the 60s net are gone, and
callers now pass the configured delay as the lower edge, so a short backoff fails the test rather than
only an order-of-magnitude error. `ssh_test.exs`'s whole-file `@moduletag :needs_ssh` became per-test
(`02a56a0`), because only six of the eight need what this host lacks. And `docs/fork-changes.md`'s
claim about `granular` was corrected where it was wrong (`e796351`), together with the counting rule
that let the wrong version stand (`e6be478`).

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

## 7. The control plane: every project, and only its own state

`/control` used to carry a badge list of registry entries. It now carries a **projects table**
(`5c42964`): one row per registry entry with its name, workflow file, declared port, `agent` route,
queue and links, plus a status column and the two control buttons of §8. The table is rendered by
`layouts.ex`'s `project_overview/1`; the status half is `ProjectStatus` (206 lines).

**One interface, and it is the instance's own.** A row's status is the answer from that instance's
`GET /api/v1/state`. No other route is read, nothing reaches into another instance, and nothing is
started or stopped to find out -- which is also why there is deliberately no state file for this view
to go stale against.

**Bounded twice.** Per request, Req gets a short `receive_timeout`, `connect_options` timeout and
`pool_timeout`, all with `retry: false`: Req retries transport errors with backoff, so probing an
instance that is **not** running cost three connection attempts, and that is the one thing a "which of
these are up" table cannot afford. Across rows, the asks go out at once (`Task.async_stream`,
`on_timeout: :kill_task`, `max_concurrency: 8`), so the page waits about one timeout in total rather
than one timeout per project. A probe that raises, or a task that is killed, still yields a row.

**Four states, none of them a guess**: `up`, with the counts the instance reported; `down` when the
connection was refused, which says nothing is listening on the declared port; `unreachable` on a
timeout, a non-200, or a raise; and `no port` when the workflow declares no `server.port` -- not
probed, and deliberately not called "down", because "there is nothing there" sends a reader somewhere
else than "there is nothing to ask". An instance that answers 200 with its own error payload is `up`
with `counts: nil` and the code in `detail`: it is running, and it said so itself. Zeroes would be a
number the instance never claimed, which is the one thing this table must not show. A failing instance
never breaks the page, and the HTTP client is injectable, so the tests never open a socket.

## 8. The hub can start and stop instances

The control column is backed by `InstanceRegistry` (877 lines, `c3da1b3`): the memory the hub did not
have, which is *which process this hub started*. It keeps one small JSON state file at
`~/code/symphony-instances.json` -- project, workflow, port, pid, logs root, started_at -- written
atomically (a temporary file renamed over the old one, so a reader sees the whole old file or the whole
new one) and read totally: a missing, empty or malformed file is an empty registry, and a record
missing any field is not a record.

**A record is not a running project.** A record means the hub started that pid, and nothing else. On
boot `reconcile/1` drops records whose pid is gone and rewrites the file, and adopts the live ones --
but adoption never turns a record into the claim that something is running; only the instance's own
state endpoint does that (§7). A start or a stop looks at the records again for the same reason, so a
crashed instance never leaves a row claiming the hub controls something that is not there.

**Ports.** `allocate/1` is pure apart from the injected "is it held" check: the project's declared port
when nothing holds it, otherwise the first free port in 4001-4099 -- the same block
`Projects.next_free_port/1` suggests from, so a suggestion and an assignment cannot disagree. That
check has to ask the operating system, because a table of who holds which port does not exist and
would be wrong the moment anything else on the machine bound one.

**Starting** runs the same argv this hub was started with, including the acknowledgement switch taken
from the CLI's own parser rather than copied as a string (`CLI.acknowledgement_switch/0`), through a
generated `start.cmd` and `cmd /c` -- which is what lets the child survive the port closing. It
refuses, with a reason rather than a crash: a project the registry does not list (the event carries a
name, never a path), a workflow whose `server.host` is not loopback, a file the validator rejects, a
project already running, and no free port. **Nothing is started at boot**; an instance starts because
a person pressed the button.

**Stopping** kills the process tree with the same helper the shell timeout path already used. When the
kill fails the record is kept, because forgetting it would lose the only handle on a process that may
still be there. It refuses to stop the instance it is running in -- by its own pid and by its serving
port -- and the row for that project renders no stop button, with a crafted click refused in the row.
A project the hub never started is refused too, because the only pids it can name are the ones in its
file.

53 tests, every side effect injected (`:launcher`, `:held?`, `:alive?`, `:kill`, plus the state-file,
registry and own-port bypasses): no test spawns a process, opens a socket or kills anything. Measured
2026-09-30: 43 tests in `instance_registry_test.exs` and 10 in `control_instances_test.exs`.

## 9. `project.publish`: a pull request, or the trunk

A project chooses how finished work lands (`edba622`): `pull_request` (the default, so every existing
workflow behaves exactly as before) or `direct`, which commits on the project's trunk and pushes it
and never looks for or creates a pull request. Under `direct` the ticket records `branch_name: main`
and carries no `links:` entry, because there is no pull request to link.

The two modes share everything else. `direct` checks the trunk out with `git checkout main` (never
`-B`: the reset form would move a branch an agent may already be on), commits only when the tree is
dirty, and pushes with no `--force` and no `+` refspec. A rejected push -- a trunk that moved on the
remote, or an auth failure -- is logged in git's own words and reported as **not** pushed, so no round
claims a push git did not confirm. `main` is a literal rather than discovered per round: a workspace an
agent had already branched must not decide where `direct` pushes, and a project whose trunk is not
`main` surfaces as a failed push instead of a silent push somewhere else.

Six tests run against a scratch repository with a real bare remote. "Never touches the pull-request
path" is *observed* rather than asserted from a log line: a `gh` that resolves but cannot be executed
is put first on `PATH`, and `direct` has to survive it. The first version of that test keyed on a log
line and passed a mutation that routed `direct` through the PR check, which is why the test observes
the behaviour instead.

## 10. `project.isolation: shared` is declared and refused

`5e33746`. `project.isolation: shared` is refused at settings validation, with a message saying it is
not implemented and `per_ticket` is the only mode. The reason is a process one rather than a design
one: the workspace change that would honour `shared` was written by an agent that never tested it, so
it was withdrawn from the working tree rather than shipped on trust. Its diff and test are preserved
outside the repository, at `~/code/symphony-isolation-slice.patch` and
`~/code/symphony-isolation-slice.test.exs`, so the work is neither lost nor in the tree. The
alternative -- accepting the key and quietly giving each ticket its own clone -- is the failure the
refusal exists to prevent.

The schema's cross-field hook (`shared` beside parallel agents, which would have two runs overwriting
each other's edits in one tree) is left in place with a comment saying it is unreachable by
construction until `shared` is honoured. It stays because it is the guard that must hold the moment it
is.

## 11. `publish` is chosen at creation, and edited in settings

`e73b068`. `publish` is chosen when a project is created -- radios in the new-project form, with
`pull_request` preselected and anything else clamped to the default before the file is written -- and
it is visible and editable in the settings page, where the mode joined the existing curated key/value
table as an enum rather than becoming a second surface for the same setting.

Fixing that exposed a real pre-existing bug. The settings reader walked exactly two-segment paths, and
the curated list's first entry is `tracker.provider.path`, three segments deep. The
`FunctionClauseError` it threw was rescued, so **every** row's effective value rendered as `nil` --
including the keys whose value was right there in the running configuration. `read_path/2` now walks
the whole path one segment at a time.

## 12. Reading another project's tickets

`3aa9a99`. The hub can read any registry project's tickets, not only its own. Both ticket routes take
an optional `project` name, resolved by registry membership -- the name is looked up in the listing
rather than joined onto the registry directory, which is what makes a crafted `?project=../../x`
unrepresentable rather than merely discouraged. That project's own workflow file supplies the tracker
settings (a registry file *is* the workflow its instance is started with), so a **stopped** project's
tickets are still reachable here. Omitting the parameter keeps the previous behaviour exactly.

The three failures each render their reason in the existing error card and keep the page alive: an
unknown project, a workflow file that does not parse, and one that cannot be read. None of them
answers "no tickets": an empty list would read as "this project has no work", which is the one answer
that must not be given for a file that could not be read.

**And the page can write (round 23).** `1ea2391` turned the single-ticket page from a reader into a
writer: a state control limited to the states the workflow declares, and a comment box. Both write
through the host's own functions -- the state through `Janitor.set_ticket_state/3`, the comment
through `Janitor.comment_on_ticket/3`, which takes an author so an operator's words are not
indistinguishable from an agent's (`control_ticket_live.ex:54`, `:385-423`) -- and neither ever edits
a ticket's bytes from the view. A ticket that is not valid UTF-8 is refused with the write path's own
reason rather than rewritten; a failure leaves the file byte-identical; a write made while reading
another project's queue lands in that project's files; and nothing is written without a submit.
`578e526` wrapped the host write so that a raise inside it becomes a refusal the page renders rather
than a crashed LiveView; the page's two test files report 20 tests at that commit.

## 13. The ticket service: the store, the surface, and the contract

The tracker work of §4 is finished, and its successor is being built rather than argued about: a
service that owns tickets, in a **new sibling repository**
`~/Desktop/android_cli_demos/symphony-tickets` (its own git repository, its own SQLite through
`exqlite`; no Ecto at all, and Phoenix only for the HTTP surface -- `mix.exs:56-59` lists `exqlite`,
`phoenix`, `bandit` and `jason`). Two slices are working, and neither is in this fork:

- **The store** (`7c31f50`, 42 tests): tickets with both a machine state type and a display name,
  labels, blocker relations that resolve rather than disappear, threaded comments, attachments keyed
  by URL, and an activity log of from-to field pairs with an actor. Two rules are proved rather than
  asserted, and both were **falsified before being believed**: an empty request must not touch the
  database at all -- the tests assert the database file is never created, with a negative control on
  the same unused path -- and a request naming a record that cannot be read must fail rather than
  quietly answer with the records it did find; breaking either rule makes the suite fail. The creation
  grace period is real time the caller supplies, never a sleep: mutations inside the window still
  happen, only the audit entry is withheld, and the creation entry is always written.
- **The HTTP surface** (`322c80d`, 82 tests in total, the 42 still passing): one loopback listener on
  4020, every endpoint mapped onto a store operation instead of re-implementing one, every store error
  tag mapped onto exactly one status and code in a single module, collections always present as empty
  lists, and activity its own call rather than inlined into the ticket. A finding changed the design:
  Plug's query decoding keeps only the last value of a repeated scalar key, so a parameter repeated the
  way the orchestrator will repeat it would have silently become a narrower question -- the query
  string is read raw, both spellings are accepted, and a key that is present but not scalar is a bad
  request. Text is proved end to end: a Chinese title and a multi-line Chinese description survive
  create, read, list and update, then compare against the bytes in SQLite itself rather than only
  against a symmetric JSON round trip.

Then `87b2efe` gave list rows what a scheduler needs. The orchestrator polls "tickets in these states"
every tick and must know, per ticket, whether it is blocked; a list row carried no relations, so the
only correct consumer would have had to fetch each ticket individually -- an N+1 on a poll loop.
Rows now carry their labels and their live blockers, read as two extra **batched** queries over the
whole result set: three statements in total for any number of tickets, never one per ticket, with a
test that counts the statements by tracing the one module that talks to SQLite and was verified to
bite (replacing the batched read with a per-ticket loop makes it fail). Labels are returned exactly as
stored, because the consumer already matches them case-insensitively and folding only in this path
would make a row disagree with the ticket it names. `dispatchable` is still the stored column: the
gating decision belongs to the scheduler, not to the store. `mix precommit`: 90 tests.

The design is `docs/ticket-service-spec.md` -- the contract, the minimal surface, the interface, six
slices, and the operator's five decisions, which supersede the document's own recommendations: a
standalone application on port 4020; **the GitHub mirror is dropped rather than ported**; the
janitor's second parser of the ticket file format is deleted with the last slice, not left reading a
directory nothing writes to; the silently discarded tracker field is fixed in this work (§4.1 item 10);
and the state vocabulary keeps **both** names, an English machine-facing type and the Chinese display
copy that exists today, with the scheduler branching on the type and never on the display name.
Service detail belongs in that document, not here.

**And one slice of the contract is no longer prose.** `b03d3c5` made the tracker contract executable:
`elixir/test/support/tracker_contract.exs` and `elixir/test/symphony_elixir/tracker_contract_test.exs`
(998 lines, with one line added to `test_helper.exs`) assert the same rules against **every adapter in
the registry**, and the registry is read from the source, so registering a new kind changes the suite
rather than being skipped. Each rule carries the `path:line` that establishes it, which is how the
specification's carried claims get re-derived. Where adapters genuinely differ, the difference is
asserted and labelled as the rule it breaks rather than hidden -- the in-memory adapter has no error
path, so unreadable and absent are the same answer to it, it returns configured structs without
normalising labels, and it matches on id alone; those three are reported as the rules it fails and
nothing was changed to make them pass. Two rules had been written and never run, because their helper
functions had no caller; wiring them up needed care, since the tool assertion called the adapter with
an empty option list and one adapter reads a bare non-empty string as a query document -- so the
assertion as written would have made a real request to a real API. The adapter's transport is now
injected and the four REST adapters get stubs that fail the test if they are ever reached, which turns
"refused before the wire" from a reading of the source into a fact.

## 14. The plan to deploy on Linux

This is the operator's **stated intent**, recorded here rather than measured: the deployment
eventually moves to Linux. It is attractive for one reason, and it is the reason this whole document
exists -- the Windows-specific adaptations stop being needed:

- the sandbox that cannot run `mix` (§5, round 19: it boots and dies at the first compile because
  `File.mkdir_p/1` cannot stat an ancestor directory), and with it the gate-outside-the-sandbox dance;
- the sandbox account dance of §2 -- a separate local account, per-path DENY ACEs, `safe.directory`,
  and `codex.git_metadata_writable`, which is a **Windows-only** unblock (upstream's issue #14338 is
  still open, so it must not be read as a portable mechanism);
- argument encoding: Erlang encodes a spawned process's arguments through the ANSI code page, which is
  what mangled the Chinese label before `gh` ever saw it (§5, `1ea2391`);
- the shell re-encoding class: PowerShell 5.1's `Get-Content`/`Set-Content` ANSI default, the BOM that
  `Set-Content -Encoding UTF8` writes, and `>` writing UTF-16 (§5, `4fd8f70`);
- the git-metadata fix of §2, which exists only to make a checkout's `.git` writable to a sandbox
  account.

Two things must not travel with it, and both are stated as rules rather than advice:

1. **The console has no authentication and must never be exposed.** The ticket service carries the same
   warning at its own configuration: `config/config.exs` binds `ip: {127, 0, 0, 1}, port: 4020` and
   says the only thing keeping it private is that it binds the loopback address; the host is refused at
   boot when it is not a literal IP rather than quietly binding somewhere else (`symphony-tickets`,
   `322c80d`; `config/config.exs:21-36`). The hub's control plane has the same property (§8), and a
   Linux host does not change it. If it ever needs to be reachable from elsewhere, that is an SSH port
   forward, not a bind address.
2. **A `.gitattributes` with `* text=auto eol=lf` belongs in the new repository before it moves.** This
   machine has `core.autocrlf=true` (measured 2026-09-30 in both `symphony` and `symphony-tickets`),
   and the ticket service's repository has no `.gitattributes` today (measured: the file does not
   exist). Without it a fresh clone materialises CRLF, and the shell scripts and checks that assume LF
   break on their first run -- a failure this workspace has already paid for once, in
   `elixir_wechatpay`, whose `.gitattributes` was added for exactly this reason (`ac79620`, "pin line
   endings to LF so the conformance scripts survive a fresh clone").

Nothing in the tree depends on the move, and no slice in `docs/ticket-service-spec.md` needs it; this
section exists so the next session does not re-derive why Linux is the cheap direction.

## 15. Open, after this batch

None of these is finished, and none should be read as though it were.

1. **`project.isolation: shared` is declared and refused** (§10). The implementation is parked outside
   the repository, and nothing in the tree honours the setting.
2. **There is no hub-side settings view for another project.** The settings link in a row points at
   that project's own instance, and only while it answers (§7). A stopped project's *tickets* are
   readable here; its settings are not.
3. **Reading a non-file tracker across projects is not attempted.** A Linear or GitHub project shows
   "the workflow does not configure a ticket directory" -- which is the pre-existing behaviour for the
   running instance too, not a new gap.
4. **The standalone recorder has no drain budget** (§6, "Accepted, not done"). The extraction could not
   carry the in-process MFA, and the fix path is recorded there.
5. **Nothing in this fork talks to the ticket service yet.** The store and its HTTP surface exist in
   the sibling repository (§13); the adapter that would speak to port 4020 is slice 3 of
   `docs/ticket-service-spec.md`, and slices 3-6 are unwritten -- including the last slice, which is
   the only thing that retires the file tracker and the janitor's second parser.
6. **The old personal access tokens are still on the machine and can be revoked** (§3). The App
   credential replaced them and no workflow in the registry names them any more, so revocation is the
   operator's call rather than a prerequisite for anything.

And the one item the upstream audit found that this batch did not touch: the `paused` early return in
`orchestrator.ex` (§6).

## 16. Round log

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
- **Round 21 (2026-09-30)**: the deployment moved to this fork and the console grew from one project
  with no management into a multi-project control plane. The registry now holds `symphony.md`, whose
  target repository is this one, with the retired deployment's `beekeeper.md` archived beside it
  (`ea242c5`, `d43f44b`, then `9b9de14`, `54895d6`, `781a58a`); the five Windows-adapted skills were
  replaced in place in this fork's `.codex/skills/` with the gate as `mix lint` then `mix test` from
  `elixir/` (`e592ebe`); and the retired repository's name was removed from the fork's defaults,
  example workflows, UI copy and one generated page (`ef7a83c`). Then, in order:
  - `/control`'s badge list became a projects table that asks each instance's own
    `GET /api/v1/state` -- bounded per request (`retry: false`) and across rows (`Task.async_stream`,
    `on_timeout: :kill_task`), four states and no guesses, a failing instance never taking the page
    down (`5c42964`, `ProjectStatus`).
  - `InstanceRegistry` gave the hub the memory of which process it started, and with it the two
    buttons: a JSON state file written atomically and read totally, a boot reconciliation that drops
    dead pids and adopts live ones without upgrading a record into a fact, a pure port allocator with
    an injected "is it held", a start through a generated `start.cmd` carrying the CLI's own
    acknowledgement switch, a stop that kills the tree and keeps the record when the kill fails, a
    refusal to stop its own instance, and nothing started at boot (`c3da1b3`; 53 tests, every side
    effect injected).
  - `project.publish` gained `direct` -- the trunk, and no pull request -- with the ticket recording
    `branch_name: main` and no `links:`, a push with no `--force` and no `+` refspec, and a rejected
    push reported as not pushed in git's own words (`edba622`; six tests against a scratch repository
    with a real bare remote, one of which *observes* that the PR path is never reached).
  - `project.isolation: shared` became a loud refusal instead of a silent no-op, its untested
    implementation parked outside the repository (`5e33746`); `publish` gained a radio at creation and
    a row in the existing settings table, which uncovered the settings reader that had been rendering
    every row's effective value as `nil` (`e73b068`); and both ticket routes took an optional
    `project` name resolved by registry membership, so a stopped project's tickets are readable here
    (`3aa9a99`).
  - Earlier the same day the audit's four open items were reduced to one: the retry lower bound came
    back anchored to a clock read before the trigger (`0775e09`), `ssh_test.exs`'s exclusion went
    per-test (`02a56a0`), and the `granular` correction landed in `docs/fork-changes.md` (`e796351`,
    `e6be478`) -- the `paused` early return in `orchestrator.ex` is the one still open. The file
    tracker's empty-list short-circuit (`7ea7c36`) and two documentation corrections (`f14b79a`,
    `391708c`) landed in the same stretch. The running instance on 4001 was rebuilt and restarted
    after each batch and serves all of it, and `docs/quickstart.md`'s "the recorder serves this at
    `/symphony`" sentence was corrected: the recorder has been its own application, in its own
    repository, on its own port, with no reverse proxy, since the extraction.
  Next: the five items in §15 -- `shared` decided or its parked slice redone with tests, a hub-side
  settings view for a project that is not answering, and the agent-credential decision.
- **Round 22 (2026-09-30)**: the agent's credential became a GitHub App installation token, minted per
  run, and the whole chain was exercised on four tickets. `ea65cf1` added `SymphonyElixir.GitHubAppToken`
  (the JWT signed in-process, the installation discovered or named, the token cached in
  `:persistent_term` with a 300s refresh slack, every failure a value) and `4f43689` wired
  `codex.app_token` into the run, so the child gets `GH_TOKEN` and git gets the same token in its config
  header. Verified against the real App: a token was minted and used to list **44 repositories**, which
  also shows the installation covers repositories created later. Then two throwaway projects, two
  tickets each, one instance per project and one agent at a time: all four agents committed, pushed
  their own branch and opened their own pull request with a `ghs_` token, each PR's head SHA equalled
  its workspace's HEAD, and the host's publish tool answered `pushed=false, committed=false` on all
  four. All four PRs merged -- the two `#2`s cleanly at 12:10Z, the two `#1`s at 12:12Z only after the
  branch was updated from the trunk, which is the `land` skill's conflict path run for real. Input
  tokens for the four runs: **1,271,884**, summed from the four rollouts. The provider and model are
  known by configuration resolution (`model_provider='"deepseek"'`, `model="deepseek-flash"`), not by
  observing the wire (§3).
  Next: the ticket the run itself damaged started round 23.
- **Round 23 (2026-09-30)**: the encoding family, and the ticket page learned to write. A probe ticket
  came back not valid UTF-8; the suspicion (a byte-boundary cut in the write path) was wrong --
  PowerShell's `Get-Content`/`Set-Content` ANSI pair had re-encoded it, and replaying CP936 over the
  last good revision reproduced the damaged commit with zero differing bytes (`4fd8f70`; the damaged
  file is `~/code/symphony-e2e-alpha-work/ALPHA-2.md`). Every Elixir write path round-trips Chinese
  byte-exactly, so the fix was two-sided: the host now offers the state change itself -- read the
  bytes, replace one key, write the same bytes back -- and refuses to touch a ticket that is not UTF-8,
  so damage is never rewritten under the host's authority. The same family's second member was found in
  the mirror: Erlang encodes a spawned process's arguments through the ANSI code page, so a
  three-character CJK label reached `gh` mangled and no mirror round could add it; the vocabulary that
  leaves the process is ASCII now, the console's Chinese is untouched, and a missing label is created
  on demand rather than failing the whole mirror (`1ea2391`). The single-ticket page gained a state
  control limited to the workflow's declared states and a comment box, both writing through
  `Janitor.set_ticket_state/3` and `Janitor.comment_on_ticket/3` -- the comment signed `operator`,
  never `agent` -- with a non-UTF-8 ticket refused, a failure leaving the file byte-identical, a write
  from another project's queue landing in that project's files, and nothing written without a submit
  (`1ea2391`); `578e526` made a raise inside the host's write path a refusal the page renders rather
  than a crashed LiveView. The third member of the family is in this document's own history: two shell
  edits of it -- one leaving an orphan line, one an `Add-Content` carriage return -- broke a file
  (`3ad7c04`), which is where the write-it-whole rule comes from (§5). And `19c8e15` fixed
  `tracker.secret_environment_names`, which had been declared and then discarded twice over.
  Next: the ticket service, which is where the whole file-writing class goes.
- **Round 24 (2026-09-30)**: the ticket service exists in a new sibling repository, and the tracker
  contract became executable. The design was written first (`ea5ff05`, `docs/ticket-service-spec.md`),
  then the operator's five answers were appended rather than edited in (`3ad7c04`): standalone on 4020,
  the GitHub mirror dropped, the janitor's second parser deleted with slice 6, the discarded tracker
  field fixed here, and both state names kept. The store (`7c31f50`, 42 tests) and its HTTP surface
  (`322c80d`, 82 in total) landed the same night, with two rules falsified before being believed;
  `87b2efe` then gave list rows their labels and live blockers in three batched statements whatever the
  size, because a poll loop must not become an N+1. Back in the fork, `b03d3c5` turned the tracker
  contract into 998 lines of tests that run against every registered adapter, each rule carrying the
  `path:line` that establishes it, and the gate this round re-measured: **912 passed, 6 skipped, 23
  excluded** (261.0s). Finally the operator's intent to move the deployment to Linux was recorded
  (§14), with the two things that must not travel: the unauthenticated console, and the missing
  `.gitattributes`.
  Next: slice 3 of `docs/ticket-service-spec.md` -- the adapter in this fork that speaks to port 4020 --
  and the revocation of the old personal access tokens (§3).
