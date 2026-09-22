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
| `mix workflow.check` (`lib/mix/tasks/workflow.check.ex`) | validates WORKFLOW.md: the front matter against the config schema **and** the prompt body by rendering it once | a Mix task, run by hand or by the gate; it starts nothing and changes no runtime behaviour |
| `POST /api/v1/pause` / `resume`, `paused` in the snapshot (`orchestrator.ex`, `presenter.ex`, `observability_api_controller.ex`, `router.ex`) | drains the queue: no new issues are dispatched, while runs in flight keep being reconciled and can finish | nothing is paused unless the endpoint is called; the default is `paused: false`, and `maybe_dispatch/1`'s unpaused path is the original code unchanged |
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
