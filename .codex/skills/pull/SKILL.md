---
name: pull
description:
  Merge the latest origin/main into the current branch and resolve conflicts (aka update-branch).
  Use when the branch needs to sync with origin, or when a merge conflict has to be resolved.
---

# Pull

> **Differs from upstream:** upstream has no `## Preconditions` section -- its workflow step 1 covers the
> clean tree, and it has no line-ending rule or committer-identity rule. Ours adds all three
> (docs/windows-port.md section 5).

## Preconditions

- The working tree is clean, or you commit/stash first.
- The checkout has a committer identity (`git config user.name` and `git config user.email`). This
  repository's identity is *local* config, so a fresh clone inherits none and `git commit` stops with
  `Author identity unknown` until it is set.
- Line endings: this repository declares `* text=auto eol=lf` in `.gitattributes`. Keep it that way --
  without those rules a Windows checkout arrives as CRLF and every merge shows whole-file churn
  instead of the three lines that actually conflict. Check with
  `git check-attr text -- <file>` and `git config --get core.autocrlf`.

## Workflow

1. Verify git status is clean or commit/stash changes before merging.
2. Ensure rerere is enabled locally:
   - `git config rerere.enabled true`
   - `git config rerere.autoupdate true`

> **Differs from upstream:** upstream states the remote/branch check in prose; the two commands below are
> what we run, and `$branch` is the name step 5 reuses.
3. Confirm remotes and branches:
   - `git remote -v` -- the `origin` remote has to exist.
   - `$branch = git branch --show-current` (PowerShell; no `$( )` needed) -- this must be the branch
     that receives the merge.
4. Fetch latest refs:
   - `git fetch origin`

> **Differs from upstream:** `$branch` from step 3 replaces upstream's inline
> `$(git branch --show-current)`; the branch is resolved once and reused.
5. Sync the remote feature branch first:
   - `git pull --ff-only origin $branch`
   - This pulls branch updates made remotely (for example, a GitHub auto-commit) before merging
     `origin/main`.

> **Differs from upstream:** upstream titles this step "Merge in order:" and keeps the no-rebase rule in
> its front-matter description only.
6. Merge -- a merge, never a rebase:
   - Prefer `git -c merge.conflictstyle=zdiff3 merge origin/main` for clearer conflict context.
   - Keep `zdiff3`: it is what gives each conflict region its surrounding context.
> **Differs from upstream:** upstream's bare `git commit` opens an editor; here the merge commit is made
> with `--no-edit`, because `core.editor` on this host is VS Code with `--wait` (`git var GIT_EDITOR`),
> and a bare `git commit` or `git merge --continue` blocks there until a human closes the window.
7. If conflicts appear, resolve them (see conflict guidance below), then:
   - `git add <files>`
   - `git commit --no-edit` -- the merge message is already prepared (`MERGE_MSG`), so no editor is
     needed; `git merge --continue` is the same commit and needs `--no-edit` too.

> **Differs from upstream:** upstream says "Verify with project checks (follow repo policy in
> `AGENTS.md`)"; ours names the gate -- `mix lint` (specs.check + credo --strict), then `mix test`, both
> from `elixir/` -- where its steps are documented, and the one-time install a fresh clone needs before
> the gate can start.
8. Re-run the gate:
   - `mix lint` followed by `mix test`, from `elixir/` -- this repository's gate; `elixir/AGENTS.md` has
     the toolchain and the module rules, and `docs/quickstart.md` section 5 the full check list. This
     repository has no `GATE.md`.
   - In a fresh clone, run `mix setup` from `elixir/` first: dependencies are not vendored, so the gate
     otherwise stops at `** (Mix) Can't continue due to errors on dependencies`.
9. Summarize the merge:
   - Call out the most challenging conflicts/files and how they were resolved.
   - Note any assumptions or follow-ups.

> **Differs from upstream:** this section is ours -- upstream goes from the workflow straight to the
> checklist below. We state the rule that checklist implies: settle the behaviour before the code.

## Resolving conflicts: decide the behaviour first

- State what each side is trying to achieve, find the shared goal, decide the final behaviour, and
  only then write the code that matches that decision.

**Conflict Resolution Guidance (Best Practices)** below is the fuller checklist for this same
procedure; read it when a conflict is not obvious.

## Conflict Resolution Guidance (Best Practices)

> **Differs from upstream:** upstream says "use `git diff` or `git diff --merge` to see conflict hunks";
> ours names which command shows what -- `--merge` prints the combined (`--cc`) view, and the marker
> regions themselves are only in the file.

- Inspect context before editing:
  - Use `git status` to list conflicted files.
  - Use `git diff --merge` for the combined (`--cc`) view of both sides; it does not print the
    `<<<<<<<` / `|||||||` / `>>>>>>>` regions, so open the file for the exact conflict region.
  - Use `git diff :1:path/to/file :2:path/to/file` and
    `git diff :1:path/to/file :3:path/to/file` to compare base vs ours/theirs
    for a file-level view of intent.
  - With `merge.conflictstyle=zdiff3`, conflict markers include:
    - `<<<<<<<` ours, `|||||||` base, `=======` split, `>>>>>>>` theirs.
    - Matching lines near the start/end are trimmed out of the conflict region,
      so focus on the differing core.
  - Summarize the intent of both changes, decide the semantically correct
    outcome, then edit:
    - State what each side is trying to achieve (bug fix, refactor, rename,
      behavior change).
    - Identify the shared goal, if any, and whether one side supersedes the
      other.
    - Decide the final behavior first; only then craft the code to match that
      decision.
    - Prefer preserving invariants, API contracts, and user-visible behavior
      unless the conflict clearly indicates a deliberate change.
  - Open files and understand intent on both sides before choosing a resolution.
- Prefer minimal, intention-preserving edits:
  - Keep behavior consistent with the branch's purpose.
  - Avoid accidental deletions or silent behavior changes.
- Resolve one file at a time and rerun tests after each logical batch.
- Use `ours/theirs` only when you are certain one side should win entirely.
- For complex conflicts, search for related files or definitions to align with
  the rest of the codebase.
- For generated files, resolve non-generated conflicts first, then regenerate:
  - Prefer resolving source files and handwritten logic before touching
    generated artifacts.
  - Run the CLI/tooling command that produced the generated file to recreate it
    cleanly, then stage the regenerated output.

> **Differs from upstream:** upstream says "run lint/type checks"; ours is the gate, `mix lint` then
> `mix test`, from `elixir/` -- `mix format` is a separate command here, not folded into the gate.
- For import conflicts where intent is unclear, accept both sides first:
  - Keep all candidate imports temporarily, finish the merge, then run the gate
    (`mix lint`, then `mix test`; `mix format` is its own command) to remove unused or
    incorrect imports safely.
- After resolving, ensure no conflict markers remain:
  - `git diff --check`
- When unsure, note assumptions and ask for confirmation before finalizing the
  merge.

## When To Ask The User (Keep To A Minimum)

Do not ask for input unless there is no safe, reversible alternative. Prefer
making a best-effort decision, documenting the rationale, and proceeding.

Ask the user only when:

- The correct resolution depends on product intent or behavior not inferable
  from code, tests, or nearby documentation.
- The conflict crosses a user-visible contract, API surface, or migration where
  choosing incorrectly could break external consumers.
- A conflict requires selecting between two mutually exclusive designs with
  equivalent technical merit and no clear local signal.
- The merge introduces data loss, schema changes, or irreversible side effects
  without an obvious safe default.
- The branch is not the intended target, or the remote/branch names do not exist
  and cannot be determined locally.

Otherwise, proceed with the merge, explain the decision briefly in notes, and
leave a clear, reviewable commit history.

## Differences from upstream (this host)

The index for every inline note above, plus what upstream says that cannot work here.

- **Front-matter description.** Upstream's says "perform a merge-based update (not rebase), and guide
  conflict resolution best practices"; ours names the merge and the two triggers. YAML cannot carry a
  `>` note, so this bullet is its marker.
- **`## Preconditions` (not upstream's).** Upstream checks the clean tree in step 1 and has no
  line-ending rule or committer-identity rule; ours states all three (docs/windows-port.md section 5 --
  `core.autocrlf=true` with no `.gitattributes` rule turns a `zdiff3` merge into whole-file churn).
  A fresh clone inherits no identity on this host -- this repository's is local config -- so `git
  commit` stops with `Author identity unknown` until it is set.
- **Workflow step 3.** Upstream asks for the remote and the branch in prose; ours runs `git remote -v`
  and binds `$branch = git branch --show-current`.
- **Workflow step 5.** Upstream inlines `$(git branch --show-current)`; ours uses `$branch`, bound once
  in step 3 (docs/windows-port.md section 5 lists this as one of the two changes `pull` needs).
- **Workflow step 6.** Upstream titles it "Merge in order:" and leaves the no-rebase rule in its front
  matter; ours states the rule at the command.
- **Workflow step 7, the merge commit.** Upstream's bare `git commit` opens an editor; here the commit
  is made with `--no-edit`, because `core.editor` is VS Code with `--wait` (`git var GIT_EDITOR`) and a
  bare `git commit` or `git merge --continue` blocks until a human closes the window. (Step 7.)
- **Workflow step 8, the gate.** Upstream says "follow repo policy in `AGENTS.md`"; ours is
  `mix lint` (specs.check + credo --strict) followed by `mix test`, from `elixir/` -- this repository's
  gate, and the rule `docs/windows-port.md` records as its acceptance item 6. Upstream's
  `make -C elixir all` is not applicable here: this host has no `make`. There is no `GATE.md` in this
  repository; the gate's steps are in `elixir/AGENTS.md` (`## Tests and Validation`) and
  `docs/quickstart.md` section 5. A fresh clone needs `mix setup` from `elixir/` before the gate can
  start: dependencies are not vendored, so the gate stops at
  `** (Mix) Can't continue due to errors on dependencies`.
- **`## Resolving conflicts: decide the behaviour first` (ours).** Upstream keeps the same rule inside
  the checklist below, as one of the bullets under "Summarize the intent"; ours makes it the step that
  precedes resolution.
- **Conflict hunks.** Upstream says "use `git diff` or `git diff --merge` to see conflict hunks"; ours
  names which command shows what -- `--merge` is the combined (`--cc`) view, and the
  `<<<<<<<` / `|||||||` / `>>>>>>>` regions are only in the file. (Conflict Resolution Guidance.)
- **Import conflicts.** Upstream says "run lint/type checks"; ours runs the gate (`mix lint`, then
  `mix test`, from `elixir/`), with `mix format` as a separate command.
- **`&&` / `||` are not applicable, because** PowerShell 5.1 cannot parse them: run upstream's steps
  one at a time and check `$LASTEXITCODE` after each. Upstream assumes a POSIX shell.
- **`jq` and `python3` are not applicable to this skill, because** neither is usable here -- `gh --jq`
  stands in for `jq`, and the `python3` on PATH is the Store stub. `pull` never calls either; recorded
  so a later edit does not reach for them.
- **Writing a file.** Never rewrite a conflict file through `>` (UTF-16) or `Set-Content -Encoding UTF8`
  (a BOM); a BOM makes the loader reject the file (docs/windows-port.md section 5).
- **ASCII and LF.** Upstream has a typographic apostrophe ("branch's purpose"); ours is plain ASCII,
  LF, one trailing newline -- the same writing rule as above.
