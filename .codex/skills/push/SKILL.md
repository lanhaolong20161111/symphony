---
name: push
description:
  Push current branch changes to origin and create or update the corresponding
  pull request; use when asked to push, publish updates, or create pull request.
---

# Push

## Prerequisites

- `gh` CLI is installed and available in `PATH`.
- `gh auth status` succeeds for GitHub operations in this repo.

> **Differs from upstream:** the credential may instead be `GH_TOKEN` in this process or the OS credential store, and this port adds two preconditions: the working tree is committed (see the `commit` skill) on the branch you mean, and a session that advertises a host-side publish tool publishes through that tool instead of pushing here.

- The working tree is committed (see the `commit` skill) and the branch is the one you mean (`git branch --show-current`).
- If this session advertises a host-side publish tool (a deployment may offer one, for example `symphony_publish`), the host owns git in that deployment: call that tool with the ticket identifier and stop here. Two publishers are idempotent but wasteful.

## Goals

- Push current branch changes to `origin` safely.
- Create a PR if none exists for the branch, otherwise update the existing PR.
- Keep branch history clean when remote has moved.

## Related Skills

- `pull`: use this when push is rejected or sync is not clean (non-fast-forward,
  merge conflict risk, or stale branch).

## Steps

1. Identify current branch and confirm remote state.

> **Differs from upstream:** the gate here is `mix lint` (specs.check + credo --strict) followed by `mix test`, run from `elixir/` -- upstream's `make -C elixir all` is not applicable, because there is no `make` on this host and this repository's `mix.exs` has no `all` alias -- and it can fail to start in the agent sandbox; see the paragraph below.

2. Run the gate the change needs -- `mix lint` followed by `mix test` for this repository, from `elixir/`, or the narrower command the ticket names -- and confirm it passes. Do not push with a failing gate, and do not skip it because the change "looks small".

   If a gate command streams a lot, redirect it to a file and read the file rather than piping it through a pager: piping is how a test run gets killed halfway.

   **If the gate cannot even start in your sandbox**, say so in your final message and continue with the check the ticket names. Measured on SYM-53: inside the agent sandbox `mix` dies at `Mix.Sync.PubSub` before it runs anything, so demanding either gate command there would block every push for a reason that has nothing to do with the change. The repository gate is re-run where it can run -- by CI, or by the host that publishes -- and a run that reports "the gate did not start" is more useful than one that stalls.

> **Differs from upstream:** upstream says only "push the branch"; ours names which branch a run may publish -- the ticket's, never `main`.

3. Push the ticket's branch to `origin` with upstream tracking if needed, using whatever remote URL is already configured. **A run never pushes `main`**: the branch is `symphony/<ticket>`, or the `branch_name` the ticket names.
4. If push is not clean/rejected:
   - If the failure is a non-fast-forward or sync problem, run the `pull` skill to merge `origin/main`, resolve conflicts, and rerun validation.
   - Push again; use `--force-with-lease` only when history was rewritten.
   - If the failure is due to auth, permissions, or workflow restrictions on the configured remote, stop and surface the exact error instead of rewriting remotes or switching protocols as a workaround.
5. Ensure a PR exists for the branch:
   - If no PR exists, create one.
   - If a PR exists and is open, update it.
   - If branch is tied to a closed/merged PR, create a new branch + PR.
   - Write a proper PR title that clearly describes the change outcome
   - For branch updates, explicitly reconsider whether current PR title still matches the latest scope; update it if it no longer does.

> **Differs from upstream:** nothing to change here -- upstream's step 6 applies as written. This repository does have `.github/pull_request_template.md` (Context, TL;DR, Summary, Alternatives, Test Plan), so fill every section; do not write a free-form body.

6. Write/update the PR body explicitly; when the repository has a `.github/pull_request_template.md`, follow it:
   - Fill every section with concrete content for this change.
   - Replace all placeholder comments (`<!-- ... -->`).
   - Keep bullets/checkboxes where template expects them.
   - If PR already exists, refresh body content so it reflects the total PR scope (all intended work on the branch), not just the newest commits, including newly added work, removed work, or changed approach.
   - Do not reuse stale description text from earlier iterations.

> **Differs from upstream:** nothing to change here -- upstream's step 7 applies as written. This repository has `mix pr_body.check`, run from `elixir/` as `mix pr_body.check --file <path>` (`elixir/AGENTS.md`, `## PR Requirements`), and CI runs it too (`.github/workflows/pr-description-lint.yml`).

7. Validate the PR body with `mix pr_body.check --file <path>`, from `elixir/`, and fix everything it reports before pushing.
8. Reply with the PR URL from `gh pr view`.

## Commands

> **Differs from upstream:** upstream's block is POSIX `sh`; PowerShell 5.1 cannot parse `&&`, `||` or `|| true` (read `$LASTEXITCODE` and test the value), has no `mktemp`, and `$env:TEMP` replaces `/tmp`. The block below is the equivalent -- `mix lint` then `mix test`, from `elixir/`, for `make -C elixir all`; `$branch` in place of `HEAD`; and a body file written UTF-8 without a BOM.
> **Differs from upstream:** upstream never asks which branch is current before pushing; ours refuses `main` outright, because a run that published `main` had to be force-with-leased back (SYM-57, 2026-09-29).

```powershell
# Identify the branch and the remote. Push to the remote already configured --
# do not rewrite it or switch protocols to make a failure go away.
$branch = git branch --show-current
git remote -v

# A run never pushes main. Publish the ticket's branch -- symphony/<ticket>, or the
# branch_name the ticket names. Stopping here is the correct outcome: what the
# SYM-57 run did instead (push main first, move the commit, force-with-lease main
# back) is an incident to hand to the operator, not a recovery step to repeat.
if ($branch -eq "main") {
  Write-Error "refusing to push main; push the ticket's branch (symphony/<ticket>, or the ticket's branch_name)"
  exit 1
}

# Minimal validation gate, from `elixir/` (the Mix project root): `mix lint` first,
# then `mix test`.
Push-Location elixir
mix lint
mix test
Pop-Location

# Long gate output: redirect it to a file and read that file rather than piping
# it. A log is only read back with Get-Content, so its encoding does not matter;
# a PR body file is consumed by gh, so its encoding does (see below).
Push-Location elixir
mix lint *> "$env:TEMP\gate.log"
Get-Content "$env:TEMP\gate.log" -Tail 80
mix test *> "$env:TEMP\gate.log"
Get-Content "$env:TEMP\gate.log" -Tail 80
Pop-Location

# Initial push: respect the current origin remote.
git push -u origin $branch

# If that failed because the remote moved, use the `pull` skill. After its
# resolution and a re-run of the gate, retry the normal push:
git push -u origin $branch

# If the configured remote rejects the push for auth, permissions or workflow
# restrictions, stop and surface the exact error. Do not reach for --force, and
# do not change remotes or protocols to get around it.

# Only after history was rewritten locally, deliberately:
git push --force-with-lease origin $branch

# Does a PR exist already? With no PR for the branch, gh exits non-zero and
# $state is empty. PowerShell has no `|| true`, so test the value, not the exit
# code. MERGED/CLOSED means this branch's PR is dead: start a new branch.
$state = gh pr view --json state -q .state 2>$null
if ($state -eq "MERGED" -or $state -eq "CLOSED") {
  Write-Error "This branch is tied to a closed PR; create a new branch and a new PR."
  exit 1
}

# A clear, human-friendly title that summarizes the shipped change.
$prTitle = "<clear PR title written for this change>"

# Write the body into `.github/pull_request_template.md`'s own sections
# (Context, TL;DR, Summary, Alternatives, Test Plan) -- this repository has the
# template (see Steps 6-7). Write the file with the editor tool: UTF-8, no BOM.
# `>` writes UTF-16 and `Set-Content -Encoding UTF8` writes a BOM; both produce a
# file the tooling rejects. If you must capture command output into a file, use
# [IO.File]::WriteAllText($p, $s, [Text.UTF8Encoding]::new($false)) instead.
$bodyFile = "$env:TEMP\pr_body.md"

# Validate the body against the template before opening or editing the PR.
# `pr_body.check` runs from `elixir/` and takes the body by path.
Push-Location elixir
mix pr_body.check --file $bodyFile
Pop-Location

# Create only if missing; otherwise update the existing PR in place.
if (-not $state) {
  gh pr create --title $prTitle --body-file $bodyFile
} else {
  # Reconsider the title on every branch update; edit it if the scope shifted.
  gh pr edit --title $prTitle --body-file $bodyFile
}

# Show the PR URL for the reply.
gh pr view --json url -q .url
```

## Notes

> **Differs from upstream:** upstream has no branch rule and no recovery rule; ours never pushes `main`, and restoring a shared branch with `--force-with-lease` is an incident rather than a recovery step.

- **A run never pushes `main`.** Publish the ticket's branch -- `symphony/<ticket>`, or the `branch_name` the ticket names. If a run did push `main`, restoring it with `--force-with-lease` is not a routine recovery step: stop and hand it to the operator, because that rewrite moves the shared branch every other run and CI build from, and having made the mistake is not what makes the rewrite safe.
- Do not use `--force`; only use `--force-with-lease` as the last resort.
- Distinguish sync problems from remote auth/permission problems:
  - Use the `pull` skill for non-fast-forward or stale-branch issues.
  - Surface auth, permissions, or workflow restrictions directly instead of
    changing remotes or protocols.
- Measured 2026-09-30: this repository has both of the pieces step 6 and step 7 look for -- `.github/pull_request_template.md` (Context, TL;DR, Summary, Alternatives, Test Plan) and the `mix pr_body.check` task (run from `elixir/`, `--file <path>`). Fill the template and run the check; do not write a free-form body. (Steps 6-7.)

> **Differs from upstream:** upstream's push block needs neither `jq` nor `python3`, but neither works here -- `gh --jq` is built in, and the interpreter is `python`, not `python3`.

- 2026-09-29 measured on this host: there is no `make`, no `jq` (use `gh ... --jq`, which is built in), and no working `python3` (the real interpreter is `python`).
- PowerShell 5.1 has no `&&` / `||`; use separate statements and read `$LASTEXITCODE`.
- `$env:TEMP` is the writable scratch directory; `/tmp` only means anything inside Git bash, and Git's `usr/bin` is not on `PATH` by default.
- Credentials: the token comes from this process's environment or from the OS credential store. If neither has it, say so plainly in your final message instead of trying workarounds.

## Differences from upstream (this host)

- **Gate.** Upstream step 2: `make -C elixir all`. Here: `mix lint` (specs.check + credo --strict) followed by `mix test`, from `elixir/`, or the narrower command the ticket names -- this host has no `make`, and the two-command gate is the rule this fork holds (`docs/windows-port.md`, acceptance item 6). (Step 2, Commands.)
- **Gate that cannot start.** Upstream assumes validation runs. Measured on SYM-53: in the agent sandbox `mix` dies at `Mix.Sync.PubSub` before it runs anything, so the push is not blocked on either gate command -- say so and continue with the check the ticket names, and CI or the publishing host re-runs the repository gate. (Step 2.)
- **Never push `main`.** Upstream says only "the current branch"; here a run publishes the ticket's branch -- `symphony/<ticket>`, or the ticket's `branch_name` -- and never `main`. Measured on SYM-57 (2026-09-29): a run pushed `main` first, then moved the commit to `symphony/SYM-57` and used `--force-with-lease` to restore `main`; nothing was lost, but the skill has to make that path impossible, and restoring a wrong push to a shared branch is an incident for the operator, not a routine recovery. (Step 3, Commands, Notes.)
- **PR template.** Upstream step 6 uses `.github/pull_request_template.md`; this repository has it, so the step applies as written -- fill Context, TL;DR, Summary, Alternatives and Test Plan, and keep each field inside the template's own limits (Context <= 240 chars, TL;DR <= 120, each Summary bullet <= 120). (Step 6, Notes, Commands.)
- **PR body check.** Upstream step 7 runs `mix pr_body.check` (under `elixir/`); this repository has the task, so the step applies as written: `mix pr_body.check --file <path>` from `elixir/`. CI runs the same check in `.github/workflows/pr-description-lint.yml`. (Step 7, Commands.)
- **Shell.** Upstream's block is `sh` and uses `&&`, `||`, `|| true`, `$( )` and `2>/dev/null`, which PowerShell 5.1 cannot parse: separate statements, `$LASTEXITCODE`, a value test on `$state` instead of `|| true`, `$branch` in place of `HEAD`, and `2>$null` for the redirect. (Commands.)
- **Scratch files and encoding.** Upstream writes `/tmp/pr_body.md` via `mktemp` and removes it. Here: `$env:TEMP\pr_body.md`, written UTF-8 **without** a BOM -- never `>` (UTF-16) or `Set-Content -Encoding UTF8` (BOM). (Commands, Notes.)
- **Credentials.** Upstream relies on `gh auth status` alone; here the token may be `GH_TOKEN` in this process or in the OS credential store, and if neither has it the run says so plainly instead of working around it. (Prerequisites, Notes.)
- **Extra preconditions.** Upstream lists only the two `gh` facts. Added here: the working tree is committed on the intended branch, and a session that advertises a host-side publish tool calls that tool instead of pushing. (Prerequisites.)
- **Host tools.** No `jq` (use `gh --jq`, which is built in) and no usable `python3` (the interpreter is `python`); do not reach for either. (Notes.)
