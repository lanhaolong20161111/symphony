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
- The agent can run its project's **declared gate** and read the answer (§14, `cf4a7da`) -- the check
  the sandbox cannot make for itself on this host. The tool is advertised to a project that declares
  `gate.command`, for **every tracker kind**, since `df2941a` and `6ba1b04`: it had been composed by
  the file tracker's adapter alone, so a service-tracked project -- whose adapter advertises no tracker
  tools -- was advertised **nothing**, which the `svcprobe` run measured before the fix (§13.1, §14).
  Two registry workflows declare a gate: `symphony.md`'s is committed (registry `dfecc0d`, 2026-10-01
  03:26:14) and `svcprobe.md` is still untracked. And it has since been used for real: a
  service-tracked ticket's run called `symphony_gate` on 2026-10-01 (`707a11e`, §14).
- The console's ticket pages read **whichever tracker a project configures** (§12, `d376ae8`): one seam,
  `elixir/lib/symphony_elixir_web/ticket_reader.ex` (584 lines), asks the tracker for a ticket's deep
  read; the file tracker keeps byte-for-byte its old behaviour and the service answers in one call.
- The offline, diffable property the retired mirror used to provide has a replacement: a **markdown
  export** of the ticket store (§13, `3e0ad76` in `symphony-tickets`), one `<identifier>.md` per ticket
  in the vocabulary the file tracker's own parser reads.
- The last step of the loop is on the ticket's own page (§15, `97329cb`): the pull request the ticket
  records is judged with `Land`'s own core, merged only on a verdict to land, and the outcome is
  written onto the ticket.
- The ticket service is **running** on 4020 (§13), and the operator reaches this machine from outside
  through `tailscale serve`, tailnet-only, with both applications still on loopback (§16).
- **The orchestrator reads tickets from that service** (§13.1, `fb31a7f`): the tracker kind
  `ticket_service` speaks the service's own HTTP surface, with the address in the tracker's free-form
  `provider.url`. Registering the kind made the executable contract refuse it three times before it
  would accept it; with the three acknowledgements written by hand, the contract passed **25/25** -- and
  round 27's gate move made it refuse again, in its pinned per-kind tables, so it stands at **27 passed**
  now (§13.1, §14).
- **One real deployment has used it end to end, and the chain ran green** (§13.1). A throwaway project
  (`~/code/symphony-projects/svcprobe.md`) declares `tracker.kind: ticket_service` against
  `http://127.0.0.1:4020`, with its own workspace root and the janitor disabled, and was started on
  port 4021. A ticket created **in the service** (SYM-1, `ready`/`unstarted`) was picked up,
  dispatched, worked and finished on 2026-10-01 with the agent's own commit `e8cf28f`, the agent's own
  pull request (#3, `symphony/SYM-1`) and the ticket moved to `in-review` **in the service**.

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
repository gate is re-run where it can run. **Round 25 gave that its own tool** (§14, `cf4a7da`): the
gate now runs host-side, on the agent's own request, so "the agent verifies its own work" is a thing
this deployment can do rather than a thing it has to hand to somebody else.

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
instead: `symphony.md:202-204` (measured 2026-10-01 -- the `app_token:` block replaced the `child_env:`
lines the earlier `:194-196` pointed at, and the gate block the same commit added sits above it) and the
two e2e workflows. The variable survives only in the comments
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
surgery through a bare write call.** Round 25 extended it to commit messages, where the same rule is
"a number is a claim, and a claim is measured or it is not written" (§19).

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
| 6 | **the rule every round**: `mix lint` clean and the suite green -- re-measured 2026-09-30 at `b03d3c5`: `mix test` in `elixir/` exits 0 with **912 passed, 6 skipped, 23 excluded** (excluding `:needs_symlinks`, `:needs_ssh`, `:posix_paths`), 261.0s, which is exactly the figure `b03d3c5` itself reports (the previous batch's reading was 796 passed). Round 25 re-measured both at its own last commit (`979a319`; HEAD has since moved to `5bec515`, the deploy batch, which is not measured here): `mix lint` exits 0, `found no issues`, 164 source files (6.8s), and the suite exits 0 with **949 passed, 6 skipped, 23 excluded**, 208.4s -- measured while the next feature was already being written into the same working tree, so the tree was not clean; what makes it a reading of this commit's tests is its total, which is exactly HEAD's own test set: 912 at `b03d3c5` plus the 37 this round added (18 + 10 + 9). The three test files that round added were also run on their own: **82 passed** (18 + 55 + 9). A later reading, on 2026-10-01 with HEAD at `11af6ed`: `mix lint` exits 0 with `found no issues` (**169** source files -- 164 at `979a319`), the two files the ticket-service round touched pass on their own (`tracker_contract_test.exs` **25 passed**, `ticket_service_tracker_test.exs` **30 passed**), and the whole suite is **not** measured at that commit: `mix test` failed before running a test, three times, in `mix deps.compile` (`** (File.Error) could not remove files and directories recursively from "...\_build\test\lib\lazy_html": file already exists`) while another Mix process was working in the same tree, so no pass/skip/excluded total is claimed for `11af6ed`. **Round 27 did get the total, and the obstacle turned out to be the same one**: with no other Mix process in the tree, at `6ba1b04`, `mix lint` exits 0 with `found no issues` (**172** files analysed by credo, 7.2s) and the whole suite exits 0 with **1048 passed, 6 skipped, 23 excluded** (289.1s) -- the same three exclusions, and 1048 is `979a319`'s 949 plus the two rounds between. The four test files that round touched, run together and each on its own: **82 passed** (27 + 21 + 24 + 10). The audit below is item 6's other half -- what changed, and what it would take to get upstream behaviour back |

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
than a crashed LiveView; the page's two test files report 20 tests at that commit. Round 25 added the
third write -- landing the ticket's own pull request -- in §15.

**And the read stopped belonging to one tracker's file format (round 27).** `d376ae8` put a ticket's
deep read behind one seam, `elixir/lib/symphony_elixir_web/ticket_reader.ex` (584 lines), which the
presenter resolves through (`ticket_presenter.ex:14`, `:71`, `:93`): the page asks the configured
tracker for one ticket, and the kind decides how. The workflow's `tracker.kind` string is what the seam
maps (`"file"` -> the file reader, `"ticket_service"` -> the service's own call, `ticket_reader.ex:154-155`).
The file tracker's answer is what it always was -- the same parse the dispatcher uses, one directory scan
per read indexed by front-matter id and file stem, so a board of N tickets is not N listings -- and the
service's is one HTTP call, `GET {url}/tickets/:ref`, whose single answer carries the description, the
comments, the labels and the blockers. A kind that cannot answer (`linear`, `github`, `jira`, `asana`,
`gitlab`, `memory`) returns `{:error, {:ticket_kind_not_readable, kind}}` (`ticket_reader.ex:157-158`)
and the page renders that **sentence**, because a tracker that cannot answer must say so: an empty board
reads as "no work to do" and an empty description as "this ticket has no description", and both invite
someone to redo work that is already done. This is a read-only seam -- no write path, no tool, no
agent-facing surface; the page's writes and the land action are untouched. Measured 2026-10-01:
`ticket_reader_test.exs` (474 lines) is **24 passed** and `control_ticket_service_test.exs` (424 lines)
is **10 passed**.

## 13. The ticket service: the store, the surface, and the contract

The tracker work of §4 is finished, and its successor is being built rather than argued about: a
service that owns tickets, in a **new sibling repository**
`~/Desktop/android_cli_demos/symphony-tickets` (its own git repository, its own SQLite through
`exqlite`; no Ecto at all, and Phoenix only for the HTTP surface -- `mix.exs:56-59` lists `exqlite`,
`phoenix`, `bandit` and `jason`). Four slices are committed in that repository -- the store, the surface,
the list-row relations and now the export -- and the fork's own
side of the contract -- the adapter -- is committed here as of `fb31a7f` (§13.1):

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

**And the tickets come back out as markdown (`3e0ad76`, the fourth slice).**
`mix symphony_tickets.export --out DIR [--db PATH]` writes one `<identifier>.md` per ticket, in the
**vocabulary the file tracker's own parser reads** -- which is what replaces the offline, diffable
property the retired mirror used to provide, and what makes a future import an honest thing to attempt
(`lib/mix/tasks/symphony_tickets.export.ex`, 93 lines; `lib/symphony_tickets/export.ex`, 569 lines).
The task is a thin shell: it parses two options, prints what happened, and **exits non-zero when any
ticket failed**, after the tickets that could be written have been; it deliberately does not start the
application, because the store opens the database per operation and starting the listener would bind
the service's port for a one-shot job (`export.ex` moduledoc, `symphony_tickets.export.ex:18-22`). The
design is deliberately boring, and each property is a test: the bytes are a pure function of one
ticket's data -- fixed key order, no export timestamp, stable ordering -- so a second export renders
the same bytes twice over; an unchanged ticket's file is **not touched**, so a repository holding an
export shows empty diffs, and a file that differs only by CRLF counts as unchanged because a Windows
checkout with `core.autocrlf` would otherwise rewrite every file the export wrote; writes go through a
temp file and a rename, so a reader never sees half a ticket; the export **never deletes** a file, and a
file whose front matter does not carry the generated marker is reported and left exactly as it was
(`@marker`, `export.ex:98-106`; the check looks inside the front matter, so a ticket whose *description*
quotes the marker line is not mistaken for an export); and a value that is not valid UTF-8 fails **that
one ticket** loudly rather than writing replacement characters -- no file for it, every other ticket
still exported (`export.ex:71-79`, `:489`). The format claim was checked rather than asserted: the
round's own record says the output was read back with the fork's own parser -- `SymphonyElixir.Tracker.File.tickets/1`,
the parse the dispatcher uses (`tracker/file.ex:205`), plus `Janitor.Ticket.problems/1`
(`janitor/ticket.ex:283`) -- loaded read-only from the fork's `_build`, and every field round-tripped,
including escaped quotes, a backslash, an embedded newline, CJK, an emoji and a blocker reference. That
check is recorded by the commit and was **not re-run here**; what was measured here is the test file
and the suite. Measured 2026-10-01 at `3e0ad76`: `test/symphony_tickets/export_test.exs` (658 lines) is
**20 passed** (3.5s) and the service's whole suite is **110 passed** (6.9s) -- the 90 recorded at
`87b2efe` plus those 20.

**It is running, by hand, and nothing here survives a reboot.** Measured 2026-10-01: the listener on
`127.0.0.1:4020` is PID 19384, started 2026-09-30 23:59:37, running `mix phx.server`; `GET /health`
answers `{"ok":true}`. The empty-request rule above was then watched live rather than only in its test:
`GET /tickets` answered `{"tickets":[]}` and created **no database file at all**, and the first query
that named a state (`GET /tickets?state=ready`) is what created
`~/.symphony-tickets/tickets.db` (65,536 bytes then; **73,728** bytes and last written 2026-10-01
03:46:45 now -- the `svcprobe` run of §13.1 wrote it first, the SYM-2 run of §14 last). There is **no
auto-start**: no scheduled task and no
`HKCU\...\Run` entry names the service, the hub or any project (re-checked 2026-10-01: no matching
scheduled task, and the `Run` key holds OneDrive, ctfmon, iFlyInput, JianyingPro, WorkBuddy and Edge
and nothing else), so a reboot takes the whole loop down until a person starts the processes. The loop
as it stands is: a ticket is created, the agent develops, runs the check the project declares (§14),
opens its own pull request, and the operator lands it from the phone (§15). The **deploy action landed
after round 25** (`cd04499`, then `5bec515`), and this document still does not describe its design. An
automatic landing sweep is an open decision that needs a policy first: which tickets may merge
unattended (§18).

**Slices 3, 4 and 5 of the replacement are delivered; slice 6 is the one left.** The adapter
(`fb31a7f`) is committed and proved live (§13.1), the console reads whichever tracker a project
configures (`d376ae8`, §12), and the markdown export exists (`3e0ad76`, above). Slice 6 -- retiring the
file tracker, the GitHub mirror, the ticket queue and the janitor's second parser of the ticket format
-- is **not** done: the specification's own order keeps it waiting, because the console's pages had to
read the service before the files they read could go away, and every registry workflow still declares
the file tracker (`docs/ticket-service-spec.md:158-165`). It is also semi-irreversible, so it waits on
the operator's sequencing decision rather than on more code (§18 item 5).

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

### 13.1 The adapter, and the run that proved it (`fb31a7f`, round 26)

The orchestrator is a consumer of the service now. `SymphonyElixir.Tracker.TicketService`
(`elixir/lib/symphony_elixir/tracker/ticket_service.ex`, **457 lines**) is registered under the kind
`ticket_service` (`elixir/lib/symphony_elixir/tracker.ex:21`), and its address lives in the tracker's
free-form `provider` map under `url` (`:15-31`): there is no schema field for it and no default, and
`validate_config/1` fails closed with `:missing_ticket_service_url` rather than polling a port this
adapter guessed at (`:173-182`). It is a **reader** -- it advertises no agent tools, deliberately
(`:10-11`), so writing tickets through a tool stays a separate decision.

It makes two calls (`:35-43`): `GET {url}/tickets?state=<name>`, one repeated `state` parameter per
declared state in the declared order, and `GET {url}/tickets?ids=<id>,<id>`. A state name the service
does not know answers `[]` -- the contract's rule, not a refusal invented here. A requested id the
service cannot read is `{:error, {:ticket_service_ticket_not_found, value}}` rather than the records
that did exist (`:42-43`), so a short list can never look like "that is all there is". The
empty-request rule holds at this boundary too, ahead of resolving the URL (`:116`, `:146`).
`dispatchable` is the **stricter** of two answers (`:52-56`, `:392-400`): the service's stored column
is a veto a person can set, and the blocker rule is derived here from the live blockers and the
workflow's first active state exactly as the file adapter derives it -- so a stored `true` cannot lift
a blocker, and a stored `false` cannot be overridden by an adapter that found none. Labels are **not**
normalized here (`:340-344`), because the store keeps the name it was given and `Issue.routable?/2`
normalizes both sides of every comparison anyway. `GET /states` and `GET /health` are deliberately not
called (`:45-48`), and `secret_environment_names/1` answers `[]` as a value (`:58-62`).

**The contract refused the new kind three times, which is the suite doing its job.** Registering it
broke `tracker_contract_test.exs` in three independent places, and each was answered by hand after
reading the failure text rather than by widening an assertion: the kind list the suite pins
(`@registered_kinds`), the advertised-tool map (`@advertised_tools`, `[]` for this kind, which is a
value), and the per-kind stub function the tool assertion calls (`tool_opts/1` -- `[]`, because there
is nothing to stub). With those added the contract passes **25/25** -- measured 2026-10-01,
`mix test test/symphony_elixir/tracker_contract_test.exs` in `elixir/`: `25 passed`, 1.0s. Its seven
rule groups run against all eight registered kinds (`asana file github gitlab jira linear memory
ticket_service`), and `registered_kinds/0 == @registered_kinds` is itself asserted, so a ninth kind
cannot slip in unacknowledged. The adapter's own file,
`elixir/test/symphony_elixir/ticket_service_tracker_test.exs` (404 lines), reports **30 passed**,
measured the same way.

**And a real deployment ran the whole chain green.** `~/code/symphony-projects/svcprobe.md` (a project
file created for this round, untracked in the registry, created 01:30:25) declares
`tracker.kind: ticket_service` against `http://127.0.0.1:4020` (`:21-23`), its own workspace root
(`~/code/symphony-svcprobe-workspaces`) and the janitor **disabled** (`:65`); its instance was started
on port **4021** (`--port 4021` on the command line; measured 2026-10-01: `Get-NetTCPConnection
-State Listen -LocalPort 4021` answers `127.0.0.1`, PID 2688, started 01:32:16). A ticket created **in
the service** (SYM-1, `ready`/`unstarted`, created 01:32:01+08:00) was picked up and dispatched at
01:32:18, and finished like this:

- the agent's own commit `e8cf28f` (`docs(readme): append the svc-probe-1 marker for SYM-1`) on its
  own branch `symphony/SYM-1`, pushed by the agent -- the ticket's comment carries `git push` exit 0
  and the raw `[new branch]` output;
- **PR #3 opened by the agent itself**, checked against GitHub:
  `gh pr view 3 --repo lanhaolong20161111/symphony-e2e-beta` answers `state OPEN`,
  `headRefName symphony/SYM-1`,
  `headRefOid e8cf28ff3ac8b8e4e0a41fd8b546552546064b15`, base `master`, author
  `app/symphony-agent-2027`;
- the ticket moved to **`in-review` in the service** -- its state object is
  `{"name":"in-review","type":"started","display_name":"in-review"}` -- with the activity trail
  recorded as from-to pairs (`GET /tickets/1/activity`): `state_type` `unstarted`->`started`,
  `state_name` `ready`->`in-progress`, `state_display_name` `ready`->`in-progress`, then
  `state_name`/`state_display_name` `in-progress`->`in-review`. There is no second `state_type` entry
  because the type did not change, which is what a from-to pair means;
- the agent rewrote the ticket's **description** to carry the check it ran and the answer it got (the
  text says the command was run "with Git's grep (D:\Program Files\Git\usr\bin\grep.exe) and returned
  exit 0"), and that rewrite is its own from-to entry in the trail;
- and one comment, authored `codex`, reporting the commit hash, the push result, the pull-request URL,
  the gate result and -- worth keeping -- that `mix lint` / `mix test` / `mix pr_body.check` could not
  run there because the target repository is a README-only repository with no Elixir project.

Nothing in that run touched the file tracker or the mirror: the project's tracker kind is the service,
the janitor is off, and the file the prompt named (`~/code/symphony-work/SYM-1.md`, a *file-tracker*
ticket that happens to share the identifier) was left alone, as the agent's own comment says. That
collision is real and worth knowing before it bites: two deployments can each have a `SYM-1`, and the
prompt a run receives still names a file path that a service-backed tracker never reads.

**The gate was exercised in production for the first time in this run, and the honest shape of that is
narrower than "the tool was used".** The workflow declares `gate.command:
grep -q svc-probe-1 README.md` (`svcprobe.md:150-155`); the agent found it by reading the workflow, and
ran the command **itself**, in its sandbox, with Git's own grep -- which is what the ticket says. The
`symphony_gate` tool was **not** advertised to it: this project's tracker is the service adapter, whose
tool list is empty by design, and the gate tool was then composed only by the file adapter
(`tracker/file.ex:171` at `11af6ed`). Measured: `symphony_gate` appears nowhere in the run's Codex
rollout (`~/.codex/sessions/2026/10/01/rollout-2026-10-01T01-35-03-01a0f362-...jsonl`, whose only call
items are `exec_command` and `write_stdin`), nor anywhere in the 88 rollouts under `~/.codex/sessions`.
So the capability was built, tested and declared, and a service-backed project's agent still got **no
tools at all** -- not the gate, not `ticket_comment`, not `symphony_publish` -- and it finished the run
by writing to the service over HTTP itself. **That gap is closed in round 27** (§14, `df2941a`): running
a gate is a property of the project, so the host's own tools are advertised beside whatever the adapter
offers, for every kind. The *tracker* tools are the part that stays as it was -- the service adapter
still advertises none by design, so a service-backed run is offered the gate and not `ticket_comment`
or `symphony_publish` (§18 item 10).

## 14. The gate, run host-side, where `mix` works

`cf4a7da` gave the agent the one capability the sandbox takes away: it can run its project's gate and
read the answer. `SymphonyElixir.Janitor.GateTool` is
`elixir/lib/symphony_elixir/janitor/gate_tool.ex` (398 lines at `6ba1b04`, the round-27 end; 393 when
`cf4a7da` added it), with
`elixir/test/symphony_elixir/janitor/gate_tool_test.exs` (545 lines, **21 tests**; 417 lines and 18
tests when it landed -- `df2941a` and `6ba1b04` added the rest).

**The problem it solves is measured, not suspected** (§3, §5 round 19): a turn runs in a restricted
local account, and on this machine `mix` dies there before compiling -- `Mix.Sync.PubSub` calls
`Mix.Utils.detect_user_id!/0`, which stats the user profile, and `File.stat("C:\Users\lhl20")` is
`{:error, :eacces}` for that account. So an agent could write code and never check it, and the gate was
the host's job or a person's -- which is why "the agent verifies its own work" was impossible here.
Agent tools already execute in the Symphony process, with the host's own permissions, so this tool is
that same surface pointed at the gate.

**The command is declared, and the agent cannot influence it.** `gate.command` in the workflow is the
only command (`config/schema.ex:583-600`), and an argument that tries to carry one is refused **by
name** rather than ignored -- silently dropping `command` would leave the caller believing it had
chosen what ran. The only argument the schema accepts is a ticket
(`@allowed_arguments [@ticket_argument]`, `gate_tool.ex:34`); anything else comes back with
`"...takes no command..."` and `supportedArguments` beside it (`:279-293`), and a ticket value that is
not a plain identifier is refused rather than sanitised (`:300-311`) -- `SYM-26\n` is exactly what an
unanchored `$` lets through, and that value then gets joined into a path. That is the whole security
rule of the module: a tool that runs what it is handed is a remote shell for anything that can write an
agent prompt, and the host side of this one is not sandboxed at all.

**A project that declares no gate does not get the tool.** `tool_specs/0` answers `[]` (`:65-73`), so
it is not advertised at all -- rather than advertised and failing on every call -- and a call that
arrives anyway (a stale binding, the HTTP tool endpoint) is told `this project declares no gate: add
gate.command to WORKFLOW.md. Nothing was run.` (`:188-190`). `gate.command` is deliberately not
required and not validated for blankness: "this project declares no gate" has to stay a state a
workflow can be in, rather than a workflow that refuses to load over a setting nothing needs
(`config/schema.ex:579-582`).

**Everything about the answer is bounded.** The deadline is the project's `gate.timeout_ms`, default
900,000 ms (`gate_tool.ex:35`, `config/schema.ex:591`); the answer is the last 40 lines
(`@tail_lines`, `:40`), then a hard 8,192-byte cap (`@max_output_bytes`, `:41`) applied through
`Workspace.sanitize_hook_output_for_log/2` (`:335-340`), which already trims back to a **character**
boundary -- the same class of byte-cutting had corrupted a ticket file earlier in the same batch (§5,
round 23), so the bound must not leave a tail that is no longer text. The command runs through
`Shell.run/3`, never `System.cmd/3` (`:120-136`), because that is the runner that owns a **total**
deadline (a command that keeps printing cannot reset it) and kills the **process tree** on expiry, so a
`mix test` that outlives its deadline takes its children with it instead of leaving a survivor holding
the stdout pipe. A refusal, a non-zero exit, a timeout and a command that cannot start all come back as
values in the envelope the other tools use (`%{"success", "output", "contentItems"}`, `:347-359`);
none of them raises, because a raise inside an agent tool becomes a protocol-level error for the whole
session (`:107-111`).

**Where it runs, and how it got there.** The host's tools are now composed at the **tracker boundary**,
not in an adapter (`df2941a`, `6ba1b04`). `SymphonyElixir.Tracker` holds `@host_tool_modules [GateTool]`
(`tracker.ex:54`) and `compose_agent_tool_specs/1` answers the adapter's own tools followed by the
host's (`:96`), so a host tool is advertised **beside** whatever the adapter offers, for **every** kind;
every transport advertises through the one door, `bind_agent_tools/0` -- the Codex app-server as
`dynamicTools`, the ACP path's stdio MCP server on `tools/list`, and the HTTP tool endpoint -- so an
adapter can neither add nor remove it. Dispatch is routed by the same rule the advertisement uses: a
tool whose module says `handles?/1` goes to that module, everything else to the adapter
(`:117`, `:181-182`), and this happens **before** the adapter is consulted, so no adapter's
`execute_agent_tool/3` contract changes. The file adapter keeps its three janitor tools and no longer
composes the gate -- `agent_tool_specs/0` is `AgentTool.tool_specs()` alone (`tracker/file.ex:173`) and
`execute_agent_tool/3` is `AgentTool.execute/3` alone (`:182`) -- so the gate cannot appear twice for a
file-tracked project that declares one. `GateTool.tool_specs/0` still answers `[]` for a project that
declares no gate, so such a project is advertised exactly what its adapter offers and nothing extra.
The directory is the session's own: the Codex path threads `workspace` from the session into the tool
executor (`codex/app_server.ex:94`), so the gate runs in the tree that turn is editing; where there is
no session (the MCP stdio server, the HTTP endpoint) the workspace is derived from the ticket the call
names, through `Workspace.workspace_key/1` (`gate_tool.ex:215-248`) -- either way a path the host
resolved, never one an argument named.

**Measured state: the design rule holds, the fix is deployed, and the tool has been used for real.**
Round 26's reading was "declared and exercised, advertised to nobody"; `df2941a` answered that, and the
answer is the design rule the measurement earned: **running a gate is a property of the project, not of
where its tickets come from**, so the host's own tools are composed at the tracker boundary for every
kind (the paragraph above). The registry both declares and commits the main deployment's declaration --
`symphony.md` carries `gate.command: cd elixir && mix lint && mix test` with `timeout_ms: 900000`
(`:151`, `:155-156`; registry `dfecc0d`, 2026-10-01 03:26:14, whose message says the tool "is advertised
from the tracker boundary, so this declaration is all a project needs"), while `svcprobe.md`
(`grep -q svc-probe-1 README.md`, `:150`, `:154`) is still untracked.

**And then it was measured rather than assumed (`707a11e`).** The escript was rebuilt
(`elixir/bin/symphony`, mtime 2026-10-01 03:36:47, after `6ba1b04` at 03:06:23) and both instances were
restarted from it -- 4001's process at 03:36:47, the `svcprobe` instance's on 4021 at 03:36:51. A ticket
created **in the service** -- SYM-2, labels `[probe]`, 03:36:35, whose description asks the agent to
append a line to `README.md` and then run the project's declared gate and report the exit status -- was
dispatched and worked by a run whose agent called **`symphony_gate`**, which is the answer to the
question round 26 left open. The call is in the run's own record as exactly one `dynamicToolCall`:
`{"ticket": "SYM-2"}`, `status: failed`, the gate's exit code **1**, 516 ms, workspace
`c:/Users/lhl20/code/symphony-svcprobe-workspaces/SYM-2`. The line-count comparison says the same thing
from the other side: the run's rollout
(`~/.codex/sessions/2026/10/01/rollout-2026-10-01T03-36-54-*.jsonl`) carries `symphony_gate` on **31
lines**, where the same check over the earlier run's rollout and over all **88** rollouts existing
before it found **0** (`707a11e`). A rollout is appended to while a run goes, so that count is a
snapshot rather than a total -- a read a few minutes later found **50** lines, and the run's thread was
then ingested into `~/.codex/thread_history_1.sqlite` (thread
`01a0f3d1-e605-7d72-a404-61f40cc08e27`), where the call is one `dynamicToolCall` among 125 items and
`symphony_gate` is named in 25 of them. While the run went, `/api/v1/state` on 4021 reported
`running=1`; it has since finished, and the ticket stands at `in-review`. The gate the tool ran is the
project's own and it **failed on purpose**: `svcprobe.md` declares `grep -q svc-probe-1 README.md`, that
marker belongs to the sibling ticket, and the agent's own comment says it deliberately did not add the
string just to make the gate green. The run reported its own commit (`f6ae91c`) and its own pull request
(#4). What the run does not change is the tool *set*: the service adapter still advertises no tracker
tools, so the gate arrived beside nothing (§18 item 10).

What was measured of the code at `6ba1b04` on 2026-10-01: `mix lint` exits 0 with `found no issues`
(**172** files analysed by credo, 7.2s; the earlier 169 was `11af6ed`, 164 was `979a319`), and the four
test files this round's work touched report **82 passed** together, run both ways (together in one
invocation, and each on its own): `tracker_contract_test.exs` **27 passed** (690 lines; 25 before
`df2941a`), `janitor/gate_tool_test.exs` **21 passed** (545 lines; 18 before), `ticket_reader_test.exs`
**24 passed** (474 lines) and `control_ticket_service_test.exs` **10 passed** (424 lines). The whole suite is measured at this HEAD too,
which round 26 could not get: `mix test` in `elixir/` exits 0 with **1048 passed, 6 skipped, 23
excluded** (289.1s; the same three exclusions, `:needs_symlinks`, `:needs_ssh`, `:posix_paths`). 1048 is
the 949 of `979a319` plus the two rounds between. It is the first whole-suite reading since `979a319`
(912 at `b03d3c5`, 949 there, then none claimed for `5bec515` or `11af6ed`), and unlike round 26's
attempt it did not die in `mix deps.compile` -- the tree had no other Mix process in it.

## 15. Landing a ticket from its own page

The loop stopped one step short of done: the agent opened its own pull request and the ticket sat at
`in-review` until a person merged it by hand. `97329cb` gave the single-ticket page that last step,
and `979a319` pinned the judgement behind it.

**It decides with the project's own judgement, not a second opinion.** The page calls
`SymphonyElixir.Land.land/3` (`elixir/lib/symphony_elixir/land.ex:915`), which is the watcher's
judgement asked **once** instead of in a loop: the facts are read the way `watch/1` reads them and
`verdict/1` decides (`land.ex:231`) -- the one function where the four outcomes live. The page's
handler takes no field at all (`control_ticket_live.ex:123`): the pull request and the branch are the
ticket's own, so the submit is the whole request, and there is nothing a form could say that would
change what runs. The operation is looked up rather than called by name (`land_operation/0`, `:527`),
so the page's tests put their own function in the endpoint config and never make a `gh` call.

**Only one verdict merges.** A verdict to land squash-merges with `gh pr merge <number> --squash
--delete-branch` and nothing else (`@merge_flags`, `land.ex:972`; the test asserts that exact argv and
refuses any `--force`, `--admin` or `--auto`, because a merge carrying one of those is a merge nobody
said yes to). Every other verdict merges nothing and renders the skill's own reason -- 2 feedback, 3
checks, 4 head moved, 5 conflict, the skill's numbers and the skill's names for them
(`control_ticket_live.ex:639-642`).

**Asking once changes three things, and each one is fail-closed.** The pull request is read **twice**
-- once, then its checks are fetched for that head, then it is read again -- because a single read has
nothing to compare against, and a head that moved between the two reads judges 4 exactly as the loop
judges it (`land.ex:930-941`). A check that is still running **refuses** (3) rather than going round
again: nothing here waits, so "we have not heard yet" must not come out as "it passed" (`:966`, the
same rule the loop asks in `clear/4`). And checks that never appeared at all are already past the 120
seconds the watcher waits out (`@checks_absent_deadline_seconds`, `:43`, `:961`) -- this does not wait
two minutes to learn that nothing reported.

**Two refusals that are not verdicts, and both worth naming.** A pull request whose head branch is not
the branch the ticket records is refused rather than merged (`land.ex:923-928`): it is not the pull
request the ticket is talking about, so nothing is guessed at and nothing is searched for -- the test
shows the refusal happens on the first answer, so nothing else is even asked. And a merge that `gh`
itself refuses is reported as `{:error, {:merge_failed, reason}}` (`:974-979`) rather than as one of
the skill's policy refusals: "the merge did not happen" and "the skill said do not merge" are different
facts, and the page renders them as different sentences (`land_reason/1`, `control_ticket_live.ex:644-657`).

**Afterwards the ticket is the audit trail, and it is written in two steps.** A merge is the only thing
that moves the ticket, so the terminal state is written first -- the **first** entry of the workflow's
own `terminal_states`, read from the project's file rather than from a word written in the page code
(`TicketPresenter.terminal_state/1`, `ticket_presenter.ex:137-146`; `declared/1`, `:115-119`) -- and
then the outcome is appended to `## Discussion` signed `operator`, naming who asked, the verdict and
what the merge did (`control_ticket_live.ex:626-631`). The state goes first because it is what the
scheduler reads (`:568-571`). A landing that merged and then failed to record it is reported in **two
halves**, because both halves happened (`:610-621`): losing either one would be the page lying about
the state of the world. A ticket that records no pull request, or no branch, is told so rather than
searched for (`:538-556`), and the four refusals leave the ticket file **byte-identical** -- the page
checks that against the file, not against its own render.

**Tests.** `elixir/test/symphony_elixir/land_test.exs` is 55 tests at `979a319` (45 before it): the new
`describe "land/3"` block is 9 of them, fed the payloads the core is written to read, so no `gh` runs
and "the merge was never run" is checked against a recorded argv rather than assumed. `979a319` also
pins the mapping from facts to verdict as a nine-row table (`@verdict_table`): one row per fact -- a
conflict, a moved head, unanswered feedback, a failed check, checks absent past the deadline, and
nothing in the way -- plus three rows that pin the precedence the code's `cond` encodes, so a
reordering that let a failed check outrank feedback, or a moved head outrank a conflict, fails a test
instead of reaching a merge. The page's own file is
`elixir/test/symphony_elixir_web/control_ticket_land_test.exs` (311 lines): seven `test` call sites,
which are **nine tests** because one of them runs once per refusal kind.

## 16. Reaching this machine from outside

This is real infrastructure now, and it is recorded for the same reason as everything else here: so the
next session does not have to re-derive it. Tailscale is installed on this machine and the device is
named `pc`; `tailscale serve` publishes two mappings, both marked **(tailnet only)** by
`tailscale serve status` (measured 2026-10-01):

| tailnet URL | proxied to | what it is |
|---|---|---|
| `https://pc.tail0a3bfa.ts.net` | `http://127.0.0.1:4001` | the control console |
| `https://pc.tail0a3bfa.ts.net:8443` | `http://127.0.0.1:4020` | the ticket service (§13) |

**The property that matters is that both applications still listen only on loopback.** Measured:
`Get-NetTCPConnection -State Listen -LocalPort 4001,4020` returns `127.0.0.1` for both and nothing
else; the ticket service states the same rule in its own configuration (`symphony-tickets`,
`config/config.exs:21-36`), and the hub has it in §8. Nothing here is exposed publicly, and
**`tailscale funnel` must not be used**: neither service authenticates, so publishing either one would
put an unauthenticated write surface on the internet -- the ticket service's own config says in as many
words that whoever can reach the port can rewrite the tracker. Tailnet-only `serve` is the
SSH-port-forward answer of §17 for a phone, and only because the tailnet is the operator's own devices.

**Two practical facts were measured here, and one earlier note did not survive the re-measurement.**

- **Clash's TUN does not interfere, and the reason is the route table.** Clash Verge is running
  (`clash-verge`, `verge-mihomo`, and its `Meta Tunnel` adapter), and the system proxy is set
  (`ProxyEnable 1`, `ProxyServer 127.0.0.1:7897`), yet the tailnet needs no route of its own: what
  `Get-NetRoute` shows for `100.*` are host routes -- `100.79.45.78/32` (this node),
  `100.65.90.10/32` (the phone) and `100.100.100.100/32` (MagicDNS) -- all on `InterfaceAlias
  Tailscale`, and there is no `100.64.0.0/10` route on the Meta Tunnel at all. An earlier suspicion
  that the tunnel would swallow the tailnet range is retired by that measurement.
- **A self-test from this same machine reaches the service, which corrects an earlier note.** Measured
  2026-10-01: `curl.exe -s -o NUL -w '%{http_code}' https://pc.tail0a3bfa.ts.net/` answers `200` (the
  console, 0.04s) and `:8443` answers `404` with the ticket service's own body,
  `{"error":{"code":"not_found","message":"no such endpoint"}}` -- that payload is the service
  answering, not a proxy -- and `Invoke-WebRequest` agrees on both. An earlier note in this batch
  recorded that such a self-test *fails*, because Tailscale does not hairpin a node to its own `serve`
  endpoint; it does hairpin here, so the measurement above is the fact and the earlier note is
  retired. What the self-test cannot show is the thing that matters: it proves the mapping exists, not
  that a remote device reaches it.

## 17. The plan to deploy on Linux

This is the operator's **stated intent**, recorded here rather than measured: the deployment
eventually moves to Linux. It is attractive for one reason, and it is the reason this whole document
exists -- the Windows-specific adaptations stop being needed:

- the sandbox that cannot run `mix` (§5, round 19: it boots and dies at the first compile because
  `File.mkdir_p/1` cannot stat an ancestor directory), and with it the reason the gate tool of §14
  exists at all: on a host where the sandbox account can stat its own profile, the agent runs the gate
  itself and the tool becomes a convenience rather than the only way;
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
   forward -- or the tailnet-only `tailscale serve` of §16, which keeps the same property -- not a bind
   address.
2. **A `.gitattributes` with `* text=auto eol=lf` belongs in the new repository before it moves.** This
   machine has `core.autocrlf=true` (measured 2026-09-30 in both `symphony` and `symphony-tickets`),
   and the ticket service's repository has no `.gitattributes` today (measured: the file does not
   exist). Without it a fresh clone materialises CRLF, and the shell scripts and checks that assume LF
   break on their first run -- a failure this workspace has already paid for once, in
   `elixir_wechatpay`, whose `.gitattributes` was added for exactly this reason (`ac79620`, "pin line
   endings to LF so the conformance scripts survive a fresh clone").

Nothing in the tree depends on the move, and no slice in `docs/ticket-service-spec.md` needs it; this
section exists so the next session does not re-derive why Linux is the cheap direction. What has to be
carried there has grown, and the shape is already right: the ticket service of §13 on loopback, and the
front door of §16 as a tunnel rather than a bind address.

## 18. Open, after this batch

One item below was closed by the batch that its own measurement called for (item 7, the gate tool's
first real use); the rest are unfinished, and none of them should be read as though it were.

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
5. **Slices 3, 4 and 5 are delivered; slice 6 is not, and almost nothing has been retired.** The
   adapter (`fb31a7f`, §13.1), the console reading whichever tracker a project configures (`d376ae8`,
   §12) and the markdown export (`3e0ad76`, §13) are all in. What is not: **slice 6** -- the file
   tracker, the GitHub mirror, the ticket queue and the janitor's second parser of the ticket file
   format are all still in the tree, and the main deployment still uses the file layer: `symphony.md`'s
   `tracker.kind: file` reads the queue at `C:/Users/lhl20/code/symphony-work`. One part has been
   switched **off** rather than removed: the mirror's `tickets_repo` line is commented in the registry
   with its reason written beside it (`f941278`, 2026-10-01 03:35:34), while `issues_repo`, the tickets
   repository and the boards are untouched. The order the rest happens in is written down as a
   rehearsed procedure (`docs/ticket-service-spec.md:242`): **switch the main deployment to the service
   tracker** -- which needs a plan for the tickets that live in the file queue -- **then remove the
   queue, then delete the second parser**. It stays semi-irreversible, and the specification's own
   precondition (slice 4 before slice 6) holds (`docs/ticket-service-spec.md:158-165`).
6. **The old personal access tokens are still on the machine and can be revoked** (§3). The App
   credential replaced them and no workflow in the registry names them any more, so revocation is the
   operator's call rather than a prerequisite for anything.
7. **Closed in this batch: the gate has a live user now, measured.** `df2941a`/`6ba1b04` moved the
   composition to the tracker boundary (§14); this batch rebuilt the escript (`elixir/bin/symphony`,
   mtime 2026-10-01 03:36:47) and restarted both instances from it, and a service-tracked ticket (SYM-2)
   was worked by a run whose agent called `symphony_gate` -- measured as 31 lines in the run's rollout
   against 0 in the 88 rollouts existing before it (`707a11e`, §14). What that leaves open is not the
   gate but the tools beside it: item 10.
8. **Nothing here survives a reboot** (§13). Re-measured in this batch: all three listeners are still up
   and all three are hand-started -- 4001 (`symphony.md`, PID 20988, started 03:36:47), 4020 (the ticket
   service, PID 19384, started 2026-09-30 23:59:37, `{"ok":true}` on `/health`) and 4021 (`svcprobe.md`,
   PID 19972, started 03:36:51), each bound to `127.0.0.1`. The auto-start half was re-checked this time
   too: no scheduled task names the hub, the service or any project, and `HKCU\...\Run` holds OneDrive,
   ctfmon, iFlyInput, JianyingPro, WorkBuddy and Edge and nothing else. The loop dies with the machine
   and comes back only when a person starts the processes it needs.
9. **An automatic landing sweep has no policy.** Landing exists as one button pressed by a person
   (§15). Which tickets may merge unattended -- which states, which labels, which projects, what
   happens when the verdict is not `ok` -- is a decision nobody has made, and the sweep should not
   exist before the answer does.
10. **A service-backed project is offered the gate, and still no tracker tools.** The question the
    `svcprobe` run left open -- whether the gate tool belongs to the tracker or to the session -- was
    answered in round 27: it belongs to the **project**, and the host's tools are composed at the
    tracker boundary for every kind (§14, `df2941a`). So a service-tracked project is now offered
    `symphony_gate`. What it is still not offered is `ticket_comment` or `symphony_publish`: the
    service adapter is a reader by design (`ticket_service.ex:10-11`), so whether a service-backed
    tracker should advertise **writer** tools is a decision that still nobody has made (§13.1).
11. **The throwaway projects and their instances are still there** (`e2e-alpha.md`, `e2e-beta.md` and
    `svcprobe.md`, all three untracked in the registry root). The `svcprobe` instance is up on 4021 with
    the SYM-1/SYM-2 pair in the service (both `probe`, both `in-review`); the two `e2e` instances,
    started by hand on 4002 and 4003 for the 2026-09-30 four-ticket run, are not up now -- measured:
    4001, 4020 and 4021 are the only loopback listeners. Nothing about them has been cleaned up, and
    `svcprobe.md` is also the file this batch's gate measurement was made with, so it is a probe that
    grew a history rather than a scratch file.

And the one item the upstream audit found that this batch did not touch: the `paused` early return in
`orchestrator.ex` (§6).

## 19. Round log

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
  Next: the five items in §18 -- `shared` decided or its parked slice redone with tests, a hub-side
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
  (§17), with the two things that must not travel: the unauthenticated console, and the missing
  `.gitattributes`.
  Next: slice 3 of `docs/ticket-service-spec.md` -- the adapter in this fork that speaks to port 4020 --
  and the revocation of the old personal access tokens (§3).
- **Round 25 (2026-09-30/10-01)**: the agent can verify its own work, a ticket can be landed from its
  own page, and the deployment got a way in from outside.
  - `cf4a7da` added `SymphonyElixir.Janitor.GateTool`: `symphony_gate` runs the gate the project
    declares (`gate.command`) **on the host**, in the ticket's own workspace, because the sandbox
    cannot start `mix` here (§14). The agent's arguments may not name a command, a shell operator, a
    script or a path -- an extra key is refused by name, and a project that declares no gate is simply
    not advertised the tool. The answer is the tail (40 lines, then 8,192 bytes cut on a character
    boundary), the deadline is the project's own, and expiry kills the process tree. 393 lines, a
    417-line test file, 18 tests.
  - `97329cb` put the last step of the loop on the ticket's own page: it judges the pull request the
    ticket records with `Land`'s pure core, squash-merges with the branch deleted only on a verdict to
    land, then moves the ticket to the workflow's own terminal state and writes the outcome onto the
    ticket as a comment -- who asked, the verdict, what happened (§15). Every other verdict merges
    nothing, and the four refusals leave the ticket byte-identical; a merge that succeeded and a
    recording step that failed are reported as both. `979a319` pinned the judgement as a nine-row
    table (one row per fact, plus three precedence rows) and the one-shot path's own nine tests,
    including the two worth naming: a head that is not the branch the ticket records is refused rather
    than merged, and a merge `gh` itself refuses is an error rather than a policy refusal.
  - **A correction of this batch's own, because this log is where the port's mistakes live.** The
    commit that landed the landing page first said `Verified here: 19 tests in the new file` (it is
    `d4ad5db` in the reflog). The file has seven `test` call sites and one of them runs once per
    refusal kind, so the run reports **9**, and the message was amended to say so (`97329cb`). The rule
    the batch already earned for files applies to commit messages too: a number in a message is a
    claim, and a claim is measured or it is not written. Measured after the amendment: the three test
    files this batch added report 82 passed (18 + 55 + 9).
  - **The deployment got a front door, tailnet-only.** Tailscale is installed, the device is renamed
    `pc`, and `tailscale serve` maps `https://pc.tail0a3bfa.ts.net` to `127.0.0.1:4001` (the console)
    and `:8443` to `127.0.0.1:4020` (the ticket service) -- both "(tailnet only)", and both
    applications still bound to loopback, which is the property that matters and the reason
    `tailscale funnel` must not be used (§16). Two measurements retired a suspicion and a claim:
    Clash's TUN does not touch the tailnet (the routes are host routes on the Tailscale interface, and
    no `100.64.0.0/10` route exists at all), and a self-test from this machine **does** reach the
    service -- the earlier note that Tailscale does not hairpin a node to its own `serve` endpoint did
    not survive being re-measured.
  - **The ticket service is running**, started by hand (`mix phx.server`, PID 19384, 2026-09-30
    23:59:37, one listener on `127.0.0.1:4020`): `/health` answers `{"ok":true}`, and the store's
    empty-request rule was watched live -- `GET /tickets` answered `{"tickets":[]}` and created no
    database file, while the first query that named a state created `~/.symphony-tickets/tickets.db`
    (§13). No scheduled task and no `Run` entry starts it or the hub, so nothing survives a reboot. The
    loop's last missing piece before the phone is the deploy action, being written as this round closed:
    `deploy.ex` and its two test files were uncommitted in the tree when it was measured, and two
    commits for it (`cd04499`, `5bec515`) landed while these documents were being written -- so HEAD is
    now past this round, and the deploy action is the next round's account rather than this one's. An
    automatic landing sweep has no policy yet (§18).
  - The gate this round, measured at its own last commit `979a319` (HEAD has since moved to `5bec515`):
    `mix lint` exits 0 with `found no issues` (164 source files), the three test files the batch added
    report 82 passed on their own, and the suite exits 0 with **949 passed, 6 skipped, 23 excluded**
    (208.4s). That last number is quoted with its caveat: the run went in while the next feature was
    already being written into the same working tree, and its total equals HEAD's own test set (912 at
    `b03d3c5` plus 37 -- 18 + 10 + 9), which is what makes it a reading of this commit's tests rather
    than of a clean tree (§6 item 6).
  Next: the deploy action's own round; then a policy for the landing sweep, so "merge unattended" is a
  decision rather than an absence of one; then `gate.command` in a registry workflow, so the gate tool
  stops being untested-in-use; and then the paused slice 3 of the ticket service.
- **Round 26 (2026-10-01)**: the orchestrator became a consumer of the ticket service, and a real
  deployment proved the chain end to end.
  - `fb31a7f` added `SymphonyElixir.Tracker.TicketService`
    (`elixir/lib/symphony_elixir/tracker/ticket_service.ex`, **457 lines**), registered under the kind
    `ticket_service` (`tracker.ex:21`), reading the service's list and by-id calls with the address in
    the tracker's free-form `provider.url` and no default (`:15-31`, `:173-182`). It is a
    **reader** -- no agent tools -- and `dispatchable` is the stricter of the service's stored column
    and the file adapter's own blocker rule (`:52-56`, `:392-400`). Its test file,
    `elixir/test/symphony_elixir/ticket_service_tracker_test.exs` (404 lines), reports **30 passed**.
  - Registering the kind broke the executable contract in **three independent places**, and all three
    were acknowledged by hand after reading the failure text instead of widening an assertion: the
    pinned kind list, the advertised-tool map, and the per-kind stub function. The contract then passed
    **25/25** (measured 2026-10-01: `25 passed`, 1.0s) -- seven rule groups over all eight registered
    kinds, with `registered_kinds/0 == @registered_kinds` asserted so a ninth cannot slip in.
  - A throwaway project, `~/code/symphony-projects/svcprobe.md`, ran on port **4021** with
    `tracker.kind: ticket_service` against 4020, its own workspace root and the janitor off. A ticket
    created **in the service** (SYM-1, `ready`) was dispatched at 01:32:18 and finished with the
    agent's own commit **`e8cf28f`**, the agent's own **PR #3** (`symphony/SYM-1`; verified on GitHub:
    `state OPEN`, head `e8cf28ff3ac8b8e4e0a41fd8b546552546064b15`, author `app/symphony-agent-2027`),
    and the ticket moved to `in-review` **in the service** with a from-to activity trail (`state_type`
    `unstarted`->`started`, `state_name` and `state_display_name` `ready`->`in-progress`, then
    `in-progress`->`in-review`), a description the agent rewrote to carry the gate command and its
    exit status, and one comment authored `codex`. Nothing in the run touched the file tracker or the
    mirror -- and the *file-tracker* ticket that happens to share the identifier `SYM-1` was left
    alone, which is a collision worth knowing about before it bites (§13.1).
  - The gate **declaration** ran in production for the first time there, and the host-side **tool** did
    not: the project's tracker advertises no tools, so `symphony_gate` was never offered, and the agent
    ran the declared `grep -q svc-probe-1 README.md` itself with Git's grep -- `symphony_gate` appears
    0 times in that run's rollout, and in all 88 rollouts under `~/.codex/sessions`. `symphony.md`
    itself now declares `cd elixir && mix lint && mix test` as its gate, as an uncommitted change.
    Built, tested and declared; what is missing is a project whose tracker can offer it
    (§18 items 7 and 10).
  - **Three mistakes of this round, recorded because this log is where the port's errors live.**
    (a) A failed ticket creation was reported by the round's own script as a success, because the
    script parsed the service's error body happily. The service's failure envelope is
    `{"error": {"code": ..., "message": ...}}` with a status that says what happened -- a duplicate
    identifier is **409** `duplicate_identifier`, an unknown state **400**
    (`symphony-tickets`, `lib/symphony_tickets_web/store_error.ex:18-29`) -- so a script that wants to
    believe a 201 must put the body through a file and check for the `error` key first.
    (b) The adapter was committed without rebuilding `bin/symphony`, so the first start failed with
    `unsupported_tracker_kind`: the running escript is a build artifact, not the source. Measured: the
    commit is 01:29:44, the failed attempt's logs directory was created 01:30:27, the escript was
    rebuilt at **01:32:16** (its own mtime), and the surviving log's first line is 01:32:18. The
    failure itself left no log line here, so it is recorded as that account plus those timestamps.
    (c) The new project's workflow was generated from `symphony.md` and carried its
    `cd elixir && mix deps.get` hook line, which is right for the fork's own repository and fatal for a
    README-only target. The log shows the trap firing **four times** --
    `Workspace hook failed hook=after_create ... status=1 output="Cloning into '.'...\n/usr/bin/bash: line 15: cd: elixir: No such file or directory\n"`
    at 01:32:20, 01:32:32, 01:32:55 and 01:33:37, each followed by
    `{:workspace_hook_failed, "after_create", 1, ...}` and a retry -- before the line
    was removed; `svcprobe.md`'s `after_create` still ends with the comment that introduced it and no
    command after it (`:94-95`). The earlier end-to-end round had already paid for this trap, which is
    why it is a mistake rather than a discovery.
  - The gate, measured with HEAD at `11af6ed`: `mix lint` exits 0 with `found no issues` (**169**
    source files; the earlier 164 was `979a319`), the contract file **25 passed** and the adapter's own
    file **30 passed** on their own, and the service's suite **90 passed** (9s, `mix test` in
    `symphony-tickets` at `87b2efe`). The whole-suite figure is **not** claimed for this HEAD:
    `mix test` failed before running a test, three times, in `mix deps.compile`
    (`** (File.Error) could not remove ... _build/test/lib/lazy_html: file already exists`) with
    another Mix process working in the same tree.
  Next: a decision about which tools a service-backed project is advertised, so "the agent verifies its
  own work" reaches the deployment that currently has no tools at all; then slice 4 of
  `docs/ticket-service-spec.md` -- the console reading through the service -- which is what unblocks
  slice 6; then a policy for the landing sweep; and then the two registry gate declarations, which are
  still uncommitted.
- **Round 27 (2026-10-01)**: the gate moved to where the project is, and the console stopped reading one
  tracker's file format. Round 26 had measured two gaps; this round showed that one of them was a design
  mistake and the other a missing slice.
  - `df2941a`, finished by `6ba1b04`, moved the host's gate tool to the **tracker boundary**: `Tracker`
    holds `@host_tool_modules [GateTool]` (`tracker.ex:54`) and `compose_agent_tool_specs/1` answers the
    adapter's own tools followed by the host's (`:96`). Running a gate is a property of the **project**,
    not of where its tickets come from, so a host tool is advertised beside whatever the adapter offers,
    **for every kind**, through the one door every transport uses (`bind_agent_tools/0`), and dispatch
    routes a host tool to its module **before** the adapter is consulted (`:117`, `:181-182`), so no
    adapter's `execute_agent_tool/3` contract changed. The file adapter keeps its three janitor tools and
    no longer composes the gate (`tracker/file.ex:173`, `:182`), which is what stops it appearing twice;
    a project that declares no gate is still advertised nothing extra (`GateTool.tool_specs/0` -> `[]`).
    The executable contract refused the change in its pinned per-kind tables -- the
    "what each adapter advertises *itself*" table, the new `@host_tools ["symphony_gate"]` table beside
    it (`tracker_contract_test.exs:62`), and the per-kind stub function those assertions call -- and
    each was written by hand from the failure text rather than by widening an assertion.
    Measured: the contract **27 passed** (25 before) and `gate_tool_test.exs` **21 passed** (18 before).
  - `d376ae8` gave a ticket's deep read one seam: `elixir/lib/symphony_elixir_web/ticket_reader.ex` (584
    lines), which the presenter resolves through (`ticket_presenter.ex:14`, `:71`, `:93`) and which maps
    the workflow's kind string (`"file"` -> the file reader, `"ticket_service"` -> the service's own
    call, `ticket_reader.ex:154-155`). The file tracker's answer is byte-for-byte what it was; the
    service's is one call, `GET {url}/tickets/:ref`, carrying the description, the comments, the labels
    and the blockers; and a kind that cannot answer returns
    `{:error, {:ticket_kind_not_readable, kind}}` (`:157-158`) so the page renders that sentence rather
    than an empty board -- the failure mode that matters being a page that looks empty and invites
    someone to redo finished work. Read-only: no write path, no tool, no agent-facing surface. Measured:
    `ticket_reader_test.exs` **24 passed**, `control_ticket_service_test.exs` **10 passed**.
  - `3e0ad76` in `symphony-tickets` delivered slice 5, the **markdown export**
    (`mix symphony_tickets.export --out DIR [--db PATH]`): one `<identifier>.md` per ticket, in the
    vocabulary the file tracker's own parser reads (`Tracker.File.tickets/1`, `tracker/file.ex:205`),
    which is what replaces the offline, diffable property the retired mirror provided. It is
    deterministic (fixed key order, no export timestamp, stable ordering), **does not touch an unchanged
    file** (a CRLF-only difference included, so a Windows checkout does not trigger a rewrite), writes
    through a temp file and a rename, **never deletes** a file it did not write, refuses a file whose
    front matter lacks its generated header (`@marker`, `export.ex:98-106`), and **fails one ticket
    loudly** when a value is not valid UTF-8 rather than writing replacement characters
    (`export.ex:71-79`, `:489`); the task exits non-zero when any ticket failed, after the writable ones
    are written, and deliberately does not start the application. Its format claim was checked out of
    band rather than asserted -- the round's own record says the output was read back with the fork's own
    parser (`Tracker.File.tickets/1` plus `Janitor.Ticket.problems/1`, `janitor/ticket.ex:283`, loaded
    read-only from the fork's `_build`) and every field round-tripped, including escaped quotes, a
    backslash, an embedded newline, CJK, an emoji and a blocker reference; that check was **not** re-run
    here. Measured here: `export_test.exs` **20 passed** (658 lines, 3.5s) and the service's whole suite
    **110 passed** (6.9s), which is `87b2efe`'s 90 plus those 20.
  - **What this round did not do, stated as open** (§18): slice 6 is not started -- the file tracker,
    the GitHub mirror, the ticket **queue** and the janitor's second parser of the ticket format are all
    still in the tree and in use, because every registry workflow still declares the file tracker, and
    the retirement is semi-irreversible, so it waits on the operator's sequencing decision (item 5).
    Nothing survives a reboot (item 8); the unattended-merge policy is still an operator decision, so a
    pull request opened by a service-tracked run sits at `in-review` until a person presses a button
    (item 9); and the ticket service still runs by hand on 4020 (§13). The registry's own gate
    declaration was committed in this window (`symphony.md`, registry `dfecc0d`, 03:26:14), but **no
    running instance serves any of this round**: the 4001 escript's mtime is 01:32:16, before
    `d376ae8`/`df2941a`/`6ba1b04`, so the fix is committed and tested and not deployed (item 7).
  - **And this round's own two process lessons, because this log is where the port's errors live.**
    (a) Running two `mix test` invocations in the same checkout at once breaks both before any test runs
    -- `** (File.Error) could not remove files and directories recursively from
    "...\_build\test\lib\lazy_html": file already exists` -- so concurrency has to be serialised around
    the gate, and that cost several rounds; the same family bit this round's own measurement, when a
    long `mix test` run's output was held in a pipe and the run had to be repeated with the output
    redirected to a file before a single line appeared. (b) A documented claim of mine was wrong and was
    corrected by evidence: I wrote that the host-side gate tool had been used in production, and that
    run's own rollout shows `symphony_gate` appearing **zero** times, because the tool was not
    advertised to that project at all -- the *declaration* was exercised and the agent ran the command
    itself. `df2941a` is the fix for the design mistake that claim was hiding.
  - The gate, measured 2026-10-01 with HEAD at `6ba1b04`: `mix lint` exits 0 with `found no issues`
    (**172** files analysed by credo, 7.2s; 169 at `11af6ed`), the four test files this round touched
    report **82 passed** together and each on its own (**27 + 21 + 24 + 10**), the whole suite exits 0
    with **1048 passed, 6 skipped, 23 excluded** (289.1s), and the service's suite is **110 passed** at
    `3e0ad76`.
  Next: rebuild `bin/symphony` and restart, because every commit of this round postdates the running
  escript (mtime 01:32:16); then run one ticket against the service, so "the gate is advertised to every
  kind" stops being a tested code path and becomes a measured deployment; then decide when slice 6
  happens, since the specification's precondition for it now holds; and then a policy for the landing
  sweep.
- **Round 28 (2026-10-01)**: the fix stopped being a tested code path and became a measured deployment,
  and the mirror was switched off by decision.
  - **Rebuilt and restarted.** `elixir/bin/symphony` was rebuilt (mtime 2026-10-01 03:36:47, after
    `6ba1b04` at 03:06:23) and both instances were restarted from it -- 4001 (`symphony.md`, PID 20988,
    03:36:47) and 4021 (`svcprobe.md`, PID 19972, 03:36:51) -- so the running hub is finally the one that
    serves the tracker-boundary gate tool.
  - **And a service-tracked ticket used it.** SYM-2 in the service (`[probe]`, created 03:36:35) asks
    for one line appended to `README.md`, then the project's declared gate run and its exit status
    reported. The run's agent called **`symphony_gate`** -- the run's own record holds exactly one
    `dynamicToolCall`: `{"ticket": "SYM-2"}`, `status: failed`, the gate's exit code 1, 516 ms -- and the
    ticket ended at `in-review` in the service, its description rewritten to carry the gate's exit code,
    with a comment naming the run's own commit `f6ae91c` and its own pull request (#4). The gate
    "failed" because `svcprobe.md` declares `grep -q svc-probe-1 README.md`, the sibling ticket's marker,
    and the agent says it did not write that string just to make the gate green. The counts are in §14
    (`707a11e`): `symphony_gate` on 31 lines of the run's rollout against 0 in the 88 rollouts before it.
  - **The mirror is off, by decision** (registry `f941278`, 2026-10-01 03:35:34). The tickets live in the
    service and the console reads it, and the export can write them back out as markdown whenever a
    diffable copy is wanted, so the mirror stops earning its keep: `symphony.md`'s `tickets_repo` line is
    **commented, not deleted**, with the reason written beside it and "uncomment to mirror to GitHub
    again" in the commit message. `issues_repo`, the tickets repository and the boards are untouched.
  - **The cutover, written down as a rehearsed sequence** (`949b16e`, `docs/ticket-service-spec.md` §10):
    know what the queue holds and that its tickets are non-active, land or park them, clear the throwaway
    ticket from the service, import the queue through an HTTP body in a **file**, rebuild the escript
    **before** switching the tracker block, verify through the console and a dispatched ticket, and only
    then remove the queue and the janitor's second parser -- with rollback being the old tracker block
    and the queue left in place. The import path was rehearsed against a copy of the database.
  - **And what is still open, re-stated rather than dropped** (§18): the file tracker, the queue and the
    janitor's second parser are not retired, and the order they go in is the §10 procedure above;
    nothing survives a reboot (item 8, re-measured); the unattended-merge policy is still an operator
    decision (item 9); the ticket service still runs by hand on 4020 (§13); and the throwaway projects
    and instances are still there (item 11).
  Next: decide when slice 6 happens, since its precondition holds and the procedure for it now exists;
  then the decision item 10 leaves open (whether a service-tracked tracker advertises **writer** tools);
  then a policy for the landing sweep; and then the registry's two still-untracked project files
  (`svcprobe.md`, `e2e-alpha.md`, `e2e-beta.md`).
