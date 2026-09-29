---
name: commit
description:
  Create a well-formed git commit from current changes using session history for
  rationale and summary; use when asked to commit, prepare a commit message, or
  finalize staged work.
---

# Commit

## Goals

- Produce a commit that reflects the actual code changes and the session context.
- Follow common git conventions (type prefix, short subject, wrapped body).
- Include both summary and rationale in the body.

## Inputs

- Codex session history for intent and rationale.
- `git status`, `git diff`, and `git diff --staged` for actual changes.
- Repo-specific commit conventions if documented.

> **Differs from upstream:** here those conventions are named -- the module rules in `elixir/AGENTS.md`, and the gate (`mix lint`, then `mix test`) in its `## Tests and Validation` and in `docs/quickstart.md` section 5. This repository has no `GATE.md`.

## Steps

1. Read session history to identify scope, intent, and rationale.
2. Inspect the working tree and staged changes (`git status`, `git diff`, `git diff --staged`).

> **Differs from upstream:** upstream stages with a blanket `git add -A`; this workspace carries unrelated untracked files from other work, so stage **explicit paths** instead.

3. Stage intended changes, including new files, after confirming scope.
4. Sanity-check newly added files; if anything looks random or likely ignored (build artifacts, logs, temp files), flag it to the user before committing.
5. If staging is incomplete or includes unrelated files, fix the index or ask for confirmation.
6. Choose a conventional type and optional scope that match the change (e.g., `feat(scope): ...`, `fix(scope): ...`, `refactor(scope): ...`).
7. Write a subject line in imperative mood, <= 72 characters, no trailing period.
8. Write a body that includes:
   - Summary of key changes (what changed).
   - Rationale and trade-offs (why it changed).
   - Tests or validation run (or explicit note if not run).

> **Differs from upstream:** upstream's step 9 appends a `Co-authored-by: Codex <codex@openai.com>` trailer; that identity would be false for this agent, so no trailer is added and the template below omits it.

9. Do not append a `Co-authored-by` trailer for the agent.
10. Wrap body lines at 72 characters.

> **Differs from upstream:** upstream builds the message with a here-doc or a temp file and `git commit -F <file>`; PowerShell 5.1 has no here-doc and `>` writes UTF-16, so use repeated `-m`, one per paragraph, as shown below.

11. Create the commit message with repeated `-m`, one `-m` per paragraph, so newlines are literal.
12. Commit only when the message matches the staged changes: if the staged diff includes unrelated files or the message describes work that isn't staged, fix the index or revise the message before committing.

> **Differs from upstream:** upstream names no validation command and allows `not run (reason)` in the `Tests:` line; here the gate is run before you finish -- `mix lint` (specs.check + credo --strict), then `mix test`, both from `elixir/`.

13. Run the gate the change needs -- `mix lint` followed by `mix test`, from `elixir/`, or the narrower command the ticket names -- and put the result in the `Tests:` line.

Each `-m` below is its own paragraph, with real newlines:

```powershell
git commit -m "fix(web): stop the recorder proxy from swallowing /api/*" `
  -m "Summary: the mount matched every path under /api, so the recorder's own routes never ran." `
  -m "Rationale: the recorder is a separate process now; the proxy only needs its two prefixes." `
  -m "Tests: mix lint, then mix test (green)."
```

If you must use `-F`, write the file under `$env:TEMP` with the editor tool (UTF-8, no BOM) or `[IO.File]::WriteAllText($path, $body, [Text.UTF8Encoding]::new($false))`. Never `Set-Content -Encoding UTF8` (it adds a BOM) and never `>` (UTF-16).

## Output

- A single commit created with `git commit` whose message reflects the session.

## Template

Type and scope are examples only; adjust to fit the repo and changes.

```
<type>(<scope>): <short summary>

Summary:
- <what changed>
- <what changed>

Rationale:
- <why>
- <why>

Tests:
- <command or "not run (reason)">
```

## Differences from upstream (this host)

- **Staging.** Upstream: a blanket `git add -A`. Here: explicit paths only, because this workspace carries unrelated untracked files from other work and a blanket add commits them. (Steps 2-3.)
- **Message construction.** Upstream: a here-doc or a temp file with `git commit -F <file>`. Here: repeated `-m`, because PowerShell 5.1 has no here-doc and `>` writes UTF-16; `-F` stays as the fallback, on a file under `$env:TEMP` written UTF-8 without a BOM (never `Set-Content -Encoding UTF8`, which adds one). (Step 11 and the example above.)
- **`Co-authored-by` trailer.** Upstream appends `Co-authored-by: Codex <codex@openai.com>` in step 9 and in the template. Not applicable here: that identity would be false for this agent, so no trailer is added. (Step 9.)
- **Gate.** Upstream names no validation command and allows `not run (reason)`. Here the gate is `mix lint` (specs.check + credo --strict) followed by `mix test`, both from `elixir/` (or the command the ticket names), and its result goes in the `Tests:` line. (Step 13.)
- **Named conventions.** Upstream: "Repo-specific commit conventions if documented." Here they are named: `elixir/AGENTS.md` (module rules, and the gate under `## Tests and Validation`) and `docs/quickstart.md` section 5. There is no `GATE.md` in this repository. (Inputs.)
