---
name: land
description:
  Land a PR by monitoring conflicts, resolving them, waiting for checks, and
  squash-merging when green; use when asked to land, merge, or shepherd a PR to
  completion.
---

# Land

> **Differs from upstream:** this file is upstream's `land` skill with this host's (Windows, PowerShell, Elixir) differences marked; `## Differences from upstream (this host)` indexes every one.

## Goals

- Ensure the PR is conflict-free with main.
- Keep CI green and fix failures when they occur.
- Squash-merge the PR once checks pass.
- Do not yield to the user until the PR is merged; keep the watcher loop running
  unless blocked.

> **Differs from upstream:** upstream does not delete the remote branch, because it
> says the repo auto-deletes head branches; that is not confirmed for this repository.

- Delete the remote branch on merge with `--delete-branch`; if this repository
  turns out to auto-delete head branches, drop the flag and confirm the branch is
  gone instead of treating a "branch not found" message as a failed merge.

## Preconditions

- `gh` CLI is authenticated.
- You are on the PR branch with a clean working tree.

## Steps

1. Locate the PR for the current branch.

> **Differs from upstream:** the gate here is `mix lint` (specs.check + credo --strict) followed by
> `mix test`, from `elixir/`, and inside the agent sandbox Mix dies at the first compile
> (SYM-53/SYM-58, `Mix.Sync.PubSub` -> `File.mkdir_p/1`), so the full gate is re-run where it can run.
> A fresh checkout also needs `mix setup` before the gate can start at all.

2. Confirm the gate is green before any push: `mix lint`, then `mix test`, from `elixir/`, or the
   narrower check the ticket names when the gate cannot start in the sandbox. In a fresh checkout, run
   `mix setup` from `elixir/` first: dependencies are not vendored, so the gate otherwise stops
   at `** (Mix) Can't continue due to errors on dependencies`.

3. If the working tree has uncommitted changes, commit with the `commit` skill
   and push with the `push` skill before proceeding.
4. Check mergeability and conflicts against main.
5. If conflicts exist, use the `pull` skill to fetch/merge `origin/main` and
   resolve conflicts, then use the `push` skill to publish the updated branch.
6. Ensure Codex review comments (if present) are acknowledged and any required
   fixes are handled before merging.
7. Watch checks until complete.
8. If checks fail, pull logs, fix the issue, commit with the `commit` skill,
   push with the `push` skill, and re-run checks.
9. When all checks are green and review feedback is addressed, squash-merge and
   delete the branch using the PR title/body for the merge subject/body.
10. **Context guard:** Before implementing review feedback, confirm it does not
    conflict with the user's stated intent or task context. If it conflicts,
    respond inline with a justification and ask the user before changing code.
11. **Pushback template:** When disagreeing, reply inline with: acknowledge +
    rationale + offer alternative.
12. **Ambiguity gate:** When ambiguity blocks progress, use the clarification
    flow (assign PR to current GH user, mention them, wait for response). Do not
    implement until ambiguity is resolved.
    - If you are confident you know better than the reviewer, you may proceed
      without asking the user, but reply inline with your rationale.
13. **Per-comment mode:** For each review comment, choose one of: accept,
    clarify, or push back. Reply inline (or in the issue thread for Codex
    reviews) stating the mode before changing code.
14. **Reply before change:** Always respond with intended action before pushing
    code changes (inline for review comments, issue thread for Codex reviews).

## Commands

> **Differs from upstream:** PowerShell 5.1 has no `&&` / `||` and this host has no
> `make` and no `jq` (`gh` has its own `--jq`), so upstream's POSIX block is
> replaced and every `gh` call is checked with `$LASTEXITCODE`.
> **Differs from upstream:** the merge body is passed as a file, and the merge
> deletes the branch explicitly, because `>` writes UTF-16 here.
> **Differs from upstream:** upstream's helper owns the waiting; here the agent polls, so both waits
> carry a deadline and the check loop reads `gh pr checks` exit 8 as "still pending", not failure.
> **Differs from upstream:** the review filter runs in PowerShell instead of `gh --jq`, because
> PowerShell 5.1 breaks a jq program that contains double quotes.

The manual loop below is the agent's **primary path**: it needs nothing built and no file outside this
repository, while the watch helper has to exist on the machine already. The helper *does* run in the
agent sandbox, though -- through `escript` or `elixir`, never through `mix`; `## Async Watch Helper`
gives both invocations and the measured reason. These are PowerShell 5.1, run from the repository root.

```powershell
# Ensure branch and PR context
$branch = git branch --show-current
$pr = gh pr view --json number,url,title,body,mergeable | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { Write-Error "no PR for $branch"; exit 1 }

# Check mergeability and conflicts. GitHub computes `mergeable` asynchronously, so UNKNOWN is not a
# verdict: wait and re-read until it is known, and keep both fields, because the helper treats
# `mergeable` = CONFLICTING or `mergeStateStatus` = DIRTY as a conflict.
if ($pr.mergeable -eq "CONFLICTING" -or $pr.mergeStateStatus -eq "DIRTY") {
  # `pull` skill: fetch and merge origin/main, resolve the conflicts, then `push`.
  # Re-check mergeability afterwards: the field is computed asynchronously.
}
$mergeDeadline = (Get-Date).AddSeconds(120)
while ($pr.mergeable -eq "UNKNOWN" -and (Get-Date) -lt $mergeDeadline) {
  Start-Sleep -Seconds 10
  $pr = gh pr view --json number,url,title,body,mergeable,mergeStateStatus | ConvertFrom-Json
}
if ($pr.mergeable -eq "UNKNOWN") { Write-Error "mergeability still UNKNOWN; do not merge"; exit 1 }

# Wait for review feedback -- bounded, never forever. Codex reviews arrive as issue comments whose
# body starts with "## Codex Review". Treat them as reviewer feedback and answer with an issue
# comment prefixed [codex] (see `## Review Handling`) -- before changing any code. This repository's
# own workflows (make-all, pr-description-lint, burrito-nightly, burrito-release) post no such
# comment, so it may never arrive: time out and continue rather than blocking this step forever.
# The filter runs in PowerShell rather than through `gh --jq`, because PowerShell 5.1 does not escape
# a jq program's inner double quotes when it hands the argument to gh (measured: the unescaped form
# fails with "accepts 1 arg(s), received 3").
$pending = 0
$deadline = (Get-Date).AddSeconds(120)
while ($pending -eq 0 -and (Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 10
  $comments = gh api "repos/{owner}/{repo}/issues/$($pr.number)/comments" | ConvertFrom-Json
  $pending = @($comments | Where-Object { $_.body -match '^\s*## Codex Review' }).Count
}
if ($pending -eq 0) { Write-Host "No Codex review comment after 120s; continue." }

# Watch checks without an unbounded watch: `gh pr checks --watch` has no timeout and blocks for as
# long as anything is pending. Poll instead -- gh pr checks exits 0 when every check passed, 1 when
# one failed, and 8 while checks are still pending (`gh pr checks --help`), so 8 means keep waiting,
# not failure.
$deadline = (Get-Date).AddMinutes(15)
while ($true) {
  gh pr checks
  if ($LASTEXITCODE -eq 0) { break }
  if ($LASTEXITCODE -eq 1) {
    # Identify the failing run and read its log, then fix/commit/push and watch again:
    # gh run list --branch $branch
    # gh run view <run-id> --log
    exit 1
  }
  if ((Get-Date) -ge $deadline) {
    Write-Error "checks still pending after the wait; do not merge"
    exit 1
  }
  Start-Sleep -Seconds 15
}

# Squash-merge only when the branch is actually landable: checks green, review feedback
# answered, no conflicts. Delete the remote branch after the merge.
# $bodyFile is the merge body written as UTF-8 without a BOM (see the bullet below); it is passed to
# gh, never written with a redirect.
$bodyFile = "$env:TEMP\pr_body.md"
gh pr merge --squash --delete-branch --subject $pr.title --body-file $bodyFile

# Ask for a Codex review only when there are new commits since the last request.
gh pr comment $pr.number --body "@codex review"
```

- Write `$bodyFile` with the editor tool (UTF-8, no BOM, LF). A bare `>` in PowerShell writes UTF-16,
  so never use a redirect for a file you pass to `gh ... --body-file`.
- If this repository auto-deletes head branches on merge, drop `--delete-branch` and confirm the
  branch is gone instead of treating a "branch not found" message as a failed merge.
- This repository has `.github/pull_request_template.md` (Context, TL;DR, Summary, Alternatives, Test
  Plan) and the `mix pr_body.check` task, so the merge body is written into the template's sections and
  validated with `mix pr_body.check --file $bodyFile` from `elixir/` before the merge -- the same step
  the `push` skill runs.

## Async Watch Helper

> **Differs from upstream:** `land_watch.py` cannot run on this machine at all -- no
> working `python3` (the one on PATH is the Store stub) -- so it is not the watcher here: upstream's
> script is still in the tree at `.codex/skills/land/land_watch.py`, unused, and the watcher is the
> Elixir module `SymphonyElixir.Land` instead.

> **Differs from upstream:** upstream's agent runs the watch helper itself from a relative path; here
> the host starts it with `--no-start`, and the agent reaches the same helper inside the sandbox
> through `escript` or `elixir` -- never through `mix`, which cannot compile there.

The helper exists as an Elixir module, `SymphonyElixir.Land`, in this repository, under `elixir/` (the
Mix project root). It is **not** host-only: measured 2026-09-29 (SYM-58), a **sandboxed agent ran it**
-- `Waiting for CI checks...` on stdout, `land watch failed: gh exited 1: no pull requests found for
branch "main"` on stderr, exit 1. Two invocations reach it from inside the sandbox, and neither one
needs `mix`:

```powershell
# The escript. A bare `bin\land` does NOT work: on Windows the file has no executable extension, so
# cmd answers "'...\bin\land' is not recognized as an internal or external command". It has to go
# through escript/escript.exe, which is on PATH from the Erlang install.
# Run from the repository root; `elixir/bin` is git-ignored, so a fresh checkout has to build it
# first (`mix build_land` from `elixir/`).
escript elixir\bin\land
```

```powershell
# The compiled beams, straight out of this repository's build tree -- but `_build` is git-ignored, so
# the checkout has to have been compiled (`mix compile` from `elixir/`) for this form to work.
elixir -pa elixir\_build\dev\lib\symphony_elixir\ebin -e SymphonyElixir.Land.cli()
```

A ticket's workspace is a clone of the **target** repository, and the target is now this same fork, so
these relative paths resolve from the workspace root.

`mix` is the one that cannot be used there, and the reason is measured rather than assumed. Mix
**boots** -- `mix.bat --version` exits 0 and prints `Mix 1.20.4` -- and dies at the first compile, in
`Mix.Sync.PubSub` -> `Mix.Utils.detect_user_id!/0` -> `File.mkdir_p!/1` returning `{:error, :enotdir}`:

```
** (File.Error) could not make directory (with -p) "C:\\Users\\lhl20\\AppData\\Local\\Temp": not a directory
    (elixir 1.20.4) lib/file.ex:380: File.mkdir_p!/1
    (mix 1.20.4) lib/mix/utils.ex:1030: Mix.Utils.detect_user_id!/0
    (mix 1.20.4) lib/mix/sync/pubsub.ex:281: Mix.Sync.PubSub.base_path/0
```

`File.mkdir_p/1` walks up to the drive root and requires every ancestor to stat as a directory; in the
sandbox `File.stat("C:\Users\lhl20")` is `{:error, :eacces}` (measured), so every `File.mkdir_p` under
that profile directory returns `:enotdir`. `%TEMP%` itself is writable and carries a `Modify` ACE for
`CodexSandboxUsers`, so **no `TEMP` redirect helps** -- not even to a workspace path, because the
workspace is under `C:\Users\lhl20` too (SYM-55 set `TEMP`/`TMP`/`TMPDIR` to a workspace directory and
reproduced the same `not a directory`). The escript and the `elixir -pa` form work for that same
reason: neither one compiles, so neither one calls `File.mkdir_p`.

The **host** reaches the same watcher through Mix, from this repository's own checkout. `mix run` alone
boots `SymphonyElixir.Application`, which stops at `** (EXIT) :missing_github_token` with no
`GITHUB_TOKEN`/`GH_TOKEN` in the environment, printing nothing and exiting 1, so `mix run --no-start`
is what reaches the watcher:

```powershell
# From the Mix project root in this repository.
cd elixir
# `--no-start` runs the watcher without booting the application, so the run does not depend on the
# application's token.
mix run --no-start -e "SymphonyElixir.Land.cli()"
```

It prints `Waiting for CI checks...` first, then one verdict, and exits with the matching code. The
wording is part of the contract -- report it as printed, do not paraphrase it. Measured 2026-09-29, in
a checkout whose current branch has no PR, it printed `Waiting for CI checks...` and then, on stderr,
`land watch failed: gh exited 1: no pull requests found for branch "<owner>:<branch>"`, exit 1 -- the
1 row in the table below.

| output | exit |
|---|---|
| `Checks passed` | 0 |
| `Review comments detected. Address before merge.` | 2 |
| `Checks failed:` then one `- <name>: <conclusion>` line per failing check | 3 |
| `No checks detected after 120s; check CI configuration` | 3 |
| `PR head updated; pull/amend/force-push to retrigger CI` | 4 |
| `PR has merge conflicts. Resolve/rebase against main and push before running land_watch again.` | 5 |
| `land watch failed: <reason>` on stderr | 1 |

## Failure Handling

The agent's manual loop has to reproduce the helper's codes, so read this against the table above.
Codes 2 and 3 both mean go back to work on this branch; neither is ever a signal to merge anyway.

> **Differs from upstream:** the helper's rule and the manual loop's detector are not the same rule
> here; measured on PR 63, the helper reported 2 where the manual loop saw nothing.

- **2 -- feedback to address before merging.** `Review comments detected. Address before merge.`
  means at least one of: a human issue comment, a human review comment, a blocking review, or a
  Codex-bot comment that arrived **after** the most recent `@codex review` request. Go back to work on
  this branch: reply to each item (accept / clarify / push back), implement the accepted ones, run the
  gate where it can run (`mix lint`, then `mix test`, from `elixir/`; see `## Steps`), commit, push,
  then re-run the watch. This is never a signal to merge anyway.

  Measured on PR 63 (2026-09-29): with no `@codex review` request ever made there is no request time
  for a Codex-bot comment to be stale against, so the helper reported 2 on a PR whose only comment was
  the bot's "You have reached your Codex usage limits for code reviews." notice -- while the manual
  loop, which waits for the `## Codex Review` marker, saw nothing. Read the comment before acting: 2
  stays fail-closed, so do not merge over it, but do not report a usage-limit notice as review
  feedback either.

> **Differs from upstream:** upstream lets a flaky failure proceed unfixed; here judgment is the same,
> but a real failure is never merged over.

- **3 -- a check failed, or no checks appeared within 120 seconds.** On `Checks failed:` take the
  `- <name>: <conclusion>` lines as the list of failing checks; get details with `gh pr checks` and
  `gh run view <run-id> --log`, fix locally, run the gate, commit, push and re-run the watch.
  Use judgment on a flake (e.g. a timeout on one platform only) -- but a real failure is never merged
  over. `No checks detected after 120s` is a configuration problem (workflow not triggered, or a
  branch/path filter excluded it), not permission to merge with nothing verified. Either way, 3 means
  go back to work on this branch.

> **Differs from upstream:** upstream force-pushes to retrigger CI after an auto-fix commit; a bare
> force-push is never used here.

- **4 -- the PR head moved.** Someone pushed, or an auto-fix bot committed; an auto-fix commit does not
  trigger a fresh CI run, which is why a commit of your own is added. CI for the previous head says
  nothing about the new one, so: `git pull` (fetch and merge/rebase `origin/main` if needed), inspect
  what arrived, add your own commit if the fix is still owed, push, then re-run the watch.
  `git push --force-with-lease` only when you deliberately rewrote history; never a bare force-push.
- **5 -- merge conflicts.** Resolve against `main` and push, then re-run: `pull` skill (fetch and
  merge `origin/main`), resolve, run the gate, `push`. Re-run the watch afterwards, because the merge
  itself can invalidate a previously green run.
- **1 -- the watcher could not observe the PR.** A `gh` failure (auth, unknown repository, rate limit
  exhausted); fix that and re-run rather than guessing at a verdict.
- `UNKNOWN` mergeability is not a verdict: wait and re-check.
- Do not merge while review comments (human or Codex review) are outstanding.
- Codex review jobs retry on failure and are non-blocking; use the presence of `## Codex Review` issue
  comments (not job status) as the signal that review feedback is available.
- Do not enable auto-merge; this repo has no required checks so auto-merge can skip tests.
- If the remote PR branch advanced due to your own prior force-push or merge, avoid redundant merges;
  re-run the formatter locally if needed and `git push --force-with-lease`.
- The safety rules hold throughout: never merge with failing checks or unresolved review feedback,
  never force-push without a deliberate history rewrite, and only squash-merge a branch that is
  actually landable.

> **Differs from upstream:** upstream also remediates corrupted `pnpm` lockfile failures; not
> applicable here, because this repository has no pnpm lockfile.

- Not applicable: the pnpm-lockfile remediation (fetch latest `origin/main`, merge, force-push, rerun
  CI).

## Review Handling

> **Differs from upstream:** the local helper matches any body starting `## Codex Review`, the way
> upstream's own script does, not upstream's prose `## Codex Review -- <persona>`.

- Codex reviews arrive as issue comments posted by GitHub Actions. They start with `## Codex Review`
  and include the reviewer's methodology + guardrails used. Treat these as feedback that must be
  acknowledged before merge.
- Human review comments are blocking and must be addressed (responded to and resolved) before
  requesting a new review or merging.
- If multiple reviewers comment in the same thread, respond to each comment (batching is fine) before
  closing the thread.
- Fetch review comments via `gh api` and reply with a prefixed comment.
- Use review comment endpoints (not issue comments) to find inline feedback:
  - List PR review comments:
    ```
    gh api repos/{owner}/{repo}/pulls/<pr_number>/comments
    ```
  - PR issue comments (top-level discussion):
    ```
    gh api repos/{owner}/{repo}/issues/<pr_number>/comments
    ```
  - Reply to a specific review comment:

> **Differs from upstream:** PowerShell 5.1 has no `\` line continuation, so the reply is one line.

```
gh api -X POST /repos/{owner}/{repo}/pulls/<pr_number>/comments -f body='[codex] <response>' -F in_reply_to=<comment_id>
```

- `in_reply_to` must be the numeric review comment id (e.g., `2710521800`), not the GraphQL node id
  (e.g., `PRRC_...`), and the endpoint must include the PR number (`/pulls/<pr_number>/comments`).
- If GraphQL review reply mutation is forbidden, use REST.
- A 404 on reply typically means the wrong endpoint (missing PR number) or insufficient scope; verify
  by listing comments first.
- All GitHub comments generated by this agent must be prefixed with `[codex]`.
- For Codex review issue comments, reply in the issue thread (not a review thread) with `[codex]` and
  state whether you will address the feedback now or defer it (include rationale).
- If feedback requires changes:
  - For inline review comments (human), reply with intended fixes (`[codex] ...`) **as an inline reply
    to the original review comment** using the review comment endpoint and `in_reply_to` (do not use
    issue comments for this).
  - Implement fixes, commit, push.
  - Reply with the fix details and commit sha (`[codex] ...`) in the same place you acknowledged the
    feedback (issue comment for Codex reviews, inline reply for review comments).

> **Differs from upstream:** upstream says a Codex review issue comment stays unresolved "until a newer `[codex]` issue comment is posted acknowledging the findings"; the helper here clears it on a new `@codex review` request instead, and that is the safer rule.

- Supersession is by request, not by acknowledgement: an issue-level Codex review stops counting as
  feedback when a **new `@codex review` request** makes it stale, and such a request is itself only
  made after new commits. Do not "fix" this back to the acknowledgement -- the acknowledgement is
  written *before* the fix exists ("reply with intended fixes" comes first, the commits follow), so
  gating the block on it would clear the watcher with the review still unaddressed, while the request
  is written *after* the commits land.
- Only request a new Codex review when you need a rerun (e.g., after new commits). Do not request one
  without changes since the last review.
  - Before requesting a new Codex review, confirm there are zero outstanding review comments (all
    have `[codex]` inline replies).
  - After pushing new commits, ask for the review explicitly:
    `gh pr comment <pr_number> --body "@codex review"`. Post a concise root-level summary comment so
    reviewers have the latest delta:
    ```
    [codex] Changes since last review:
    - <short bullets of deltas>
    Commits: <sha>, <sha>
    Tests: <commands run>
    ```
  - Only request a new review if there is at least one new commit since the previous request.
  - Wait for the next Codex review comment before merging.

## Scope + PR Metadata

- The PR title and description should reflect the full scope of the change, not just the most recent
  fix.
- If review feedback expands scope, decide whether to include it now or defer it. You can accept,
  defer, or decline feedback. If deferring or declining, call it out in the root-level `[codex]`
  update with a brief reason (e.g., out-of-scope, conflicts with intent, unnecessary).
- Correctness issues raised in review comments should be addressed. If you plan to defer or decline a
  correctness concern, validate first and explain why the concern does not apply.
- Classify each review comment as one of: correctness, design, style, clarification, scope.
- For correctness feedback, provide concrete validation (test, log, or reasoning) before closing it.
- When accepting feedback, include a one-line rationale in the root-level update.
- When declining feedback, offer a brief alternative or follow-up trigger.
- Prefer a single consolidated "review addressed" root-level comment after a batch of fixes instead of
  many small updates.
- For doc feedback, confirm the doc change matches behavior (no doc-only edits to appease review).

## Differences from upstream (this host)

- **POSIX vs PowerShell.** Upstream's `## Commands` is bash (`$(...)`, `if ! ...`, `\` continuations).
  This host is PowerShell 5.1: separate statements, `$LASTEXITCODE` instead of `&&` / `||`, no `make`,
  no `jq` (`gh` has its own `--jq`), and no `\` line continuation.
- **The manual loop bounds its waits and carries both mergeability fields.** Upstream's Python helper
  owns the waiting; here the agent polls by hand, so the mergeability re-check, the review wait and
  the check wait each carry a deadline and the refreshed `$pr` is assigned back. Unbounded, the
  review wait never ends in this repository (none of its workflows posts a `## Codex Review`
  comment) and `gh pr checks --watch` blocks with no timeout. Exit 8 from
  `gh pr checks` means "still pending", not failure. A conflict is `mergeable` = CONFLICTING **or**
  `mergeStateStatus` = DIRTY -- the same pair the helper's `conflicting?/1` reads -- so the loop keeps
  `mergeStateStatus` too. (Commands.)
- **`gh api` paths and `--jq` programs need PowerShell quoting.** `{owner}` and `{repo}` must sit
  inside quotes, or PowerShell reads them as a script block; measured: `gh api
  repos/{owner}/{repo}/pulls/63/comments` fails with "The command parameter was already specified".
  A `--jq` program's inner double quotes must be escaped, or measured: the unescaped form fails with
  "accepts 1 arg(s), received 3". The review filter therefore runs through `ConvertFrom-Json` in
  PowerShell instead. (Commands, Review Handling.)
- **The helper runs in the sandbox too, and the host starts it with `--no-start`.** Upstream's agent
  runs `python3 .codex/skills/land/land_watch.py` itself. Here there is no working `python3`, so the
  watcher is `SymphonyElixir.Land` -- upstream's script is still in the tree at
  `.codex/skills/land/land_watch.py` and is not invoked. The **host** runs it from this repository's
  Mix project root, `elixir/`, with `mix run --no-start -e "SymphonyElixir.Land.cli()"`; `--no-start`
  is measured: `mix run` boots `SymphonyElixir.Application`, which stopped at
  `** (EXIT) :missing_github_token` with no `GITHUB_TOKEN`/`GH_TOKEN` set, printing nothing and
  exiting 1. The **agent** runs the same watcher inside the sandbox -- measured 2026-09-29 (SYM-58),
  with `escript elixir\bin\land` and with
  `elixir -pa elixir\_build\dev\lib\symphony_elixir\ebin -e SymphonyElixir.Land.cli()`, both printing
  `Waiting for CI checks...`, then `land watch failed: ...` on stderr, exit 1. A bare `bin\land`
  fails: on Windows the file has no executable extension, so it has to go through
  `escript`/`escript.exe`. Both forms need a build in the checkout -- `elixir/bin/` and
  `elixir/_build/` are git-ignored -- so a fresh clone runs `mix build_land` (escript) or
  `mix compile` (`elixir -pa`) from `elixir/` first. `mix` is what cannot run inside the sandbox --
  `## Async Watch Helper` has the measured reason. It prints the same lines upstream's Python prints,
  and an agent that runs the manual loop instead reproduces its codes by hand, checking review
  comments itself with the `gh api` listings in `## Commands`.
- **Exit codes 5 and 1 are documented too.** Upstream's `## Async Watch Helper` lists 2, 3 and 4.
  Its script also exits 5 on merge conflicts and 1 when the watcher cannot observe the PR, and the
  Elixir port prints `land watch failed: <reason>` for 1 -- so the local table carries all five.
- **Code 2 is broader than the manual loop's detector.** Measured on PR 63 (2026-09-29): with no
  `@codex review` request ever made, a Codex-bot usage-limit notice counted as feedback and the helper
  exited 2, while the manual loop's `## Codex Review` marker saw nothing. 2 stays fail-closed. (Failure
  Handling.)
- **`gh pr checks` covers CI only.** It does not watch review feedback or a moved PR head, which is
  exactly what codes 2 and 4 add; when the agent runs the manual loop instead of the helper, those two
  signals are the agent's own polling rather than the helper's.
- **The gate cannot run in the agent sandbox.** Upstream says to confirm the full gauntlet locally,
  and to re-run the formatter when the branch advanced; here the gate is `mix lint` (specs.check +
  credo --strict) followed by `mix test`, from `elixir/`, and Mix dies inside the sandbox at the first
  compile (`Mix.Sync.PubSub` -> `File.mkdir_p/1`; measured, see `## Async Watch Helper`), so the agent
  runs the check the ticket names, reports that, and CI or the host runs the rest. A fresh checkout
  needs `mix setup` from `elixir/` first: dependencies are not vendored, so the gate stops at
  `** (Mix) Can't continue due to errors on dependencies`. (Step 2.)
- **Head-branch deletion.** Upstream relies on the repository auto-deleting head branches; that is not
  confirmed here, so the merge passes `--delete-branch` and the notes say when to drop it.
- **Merge body.** Upstream passes `--body "$pr_body"`; here `--body-file $bodyFile`, written UTF-8
  without a BOM, because a bare `>` writes UTF-16 and `gh` then rejects or mangles the file.
- **PR template and body check.** Upstream has `.github/pull_request_template.md` and a
  `mix pr_body.check` task; this repository has both (Context, TL;DR, Summary, Alternatives, Test
  Plan; `mix pr_body.check --file <path>` run from `elixir/`), so the merge body is written into the
  template's sections and checked before the merge.
- **Flaky failures.** Upstream lets a flake proceed without fixing it; here judgment is the same, but
  a real failure is never merged over and code 3 always means go back to work on the branch.
- **No bare force-push.** Upstream's auto-fix bullet force-pushes to retrigger CI; here
  `--force-with-lease` is the only rewriting push, and only after a deliberate history rewrite.
- **Codex review marker.** Upstream's prose says reviews start with `## Codex Review -- <persona>`;
  the local helper, like upstream's own script, matches any body starting `## Codex Review`.
- **Supersession is by request, not by acknowledgement.** Upstream's `## Review Handling` says a Codex
  review issue comment stays unresolved "until a newer `[codex]` issue comment is posted acknowledging
  the findings"; the helper clears it when a new `@codex review` request makes it stale (it compares
  against the latest request, `latest_review_request/1`). The acknowledgement is written before the fix
  exists and the request only after new commits, so the request is the safer gate -- do not change the
  helper back to the acknowledgement. (Review Handling.)
- **No Codex review workflow.** Upstream's review workflow reruns on PR synchronization; this
  repository's workflows are `make-all`, `pr-description-lint`, `burrito-nightly` and
  `burrito-release`, none of which posts a Codex review, so a review is requested with
  `gh pr comment <pr_number> --body "@codex review"`.
- **pnpm lockfile remediation.** Not applicable: this repository is an Elixir project gated by
  `mix lint` and `mix test` and has no pnpm lockfile to corrupt.
