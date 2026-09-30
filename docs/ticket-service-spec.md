# Ticket service specification

A design document for replacing the file tracker and its mirror with one small service that
owns tickets. **Nothing described here is built.** This document states what we intend to
build, what is verified and what is not, and what still needs a decision.

## 0. Provenance and confidence (read this first)

This document was written by an agent that did **not** have the two research reports in its
context. Every claim therefore carries one of three marks:

| Mark | Meaning |
|---|---|
| `[verified]` | Read or measured by this document's author in this workspace. The path is given; line numbers are given only where they were actually read. |
| `[carried]` | Taken from the delegating agent's summary of the two research reports (the tracker contract survey and the Linear brief). **The underlying citations were not available here and are not reproduced.** Whoever holds those reports must re-attach their `path:line` and URLs before this section is relied on. |
| `[open]` | Not established. Stated as a question, not as a fact. |

No Linear URL appears in this document. That is deliberate: inventing a citation is worse than
recording a gap, and the brief's per-claim URLs must be carried over from the brief itself.

## 1. What this is and why

A simplified Linear, as a service: one store that owns tickets, one HTTP surface over it, and
the console's existing ticket pages as its first client.

The reason is specific rather than aesthetic. The file tracker plus its mirror produced a
family of accidents, all measured in this workspace:

1. An agent edited a ticket with PowerShell 5.1's `Get-Content`/`Set-Content`, whose default
   encoding is the ANSI code page, and the pair **re-encoded the whole file**; replaying that
   codec over the last good revision reproduced the damaged commit byte for byte. `[verified]`
   (fixed in commit `4fd8f70`; the damaged file and its two revisions were examined at
   `C:\Users\lhl20\code\symphony-e2e-alpha-work\ALPHA-2.md`).
2. The janitor's label names are handed to `gh` as **process arguments**, and on Windows Erlang
   encodes argument binaries through the ANSI code page, so a three-character CJK label reached
   `gh` as mangled bytes and no mirror round ever succeeded. `[verified]` (observed in the
   janitor log as `could not add label: '<mangled bytes>' not found`).
3. A byte-order mark at the head of a ticket file made it vanish from the queue until both
   parsers were taught to strip it. `[verified]` (recorded earlier in the port; ticket `SYM-48`).

Every one of these is a property of "tickets are files that other programs re-encode, re-sync
and re-parse", not of any single bug. A service removes the class: one writer, one reader, one
source of truth. `[carried]` - the same conclusion the contract survey reached from the other
direction, that a tracker adapter is already the system's single interface to work.

## 2. Decisions taken

Each row is a decision or explicitly open. Rationale is one line.

| # | Decision | State | Rationale |
|---|---|---|---|
| D1 | Store tickets in the service's database, not in files | decided | Removes the re-encode/re-sync class outright. |
| D2 | Model a state as a **type plus a name**: type in `backlog, unstarted, started, completed, cancelled`; name free | decided `[carried]` for the split, our mapping below | Types drive scheduling and terminality; names are what a person reads, and our names are Chinese today. |
| D3 | Map today's vocabulary onto those types: `ready`->`unstarted`, `paused`->`unstarted` (parked, still schedulable by hand), `in-progress`->`started`, `in-review`->`started`, `done`->`completed`, `cancelled`->`cancelled`, `failed`->`cancelled` | decided | Preserves today's behaviour while making "first active state" and "terminal" answerable from the type rather than from a name list. `[carried]` - the survey's point that state names in the file tracker are load-bearing by position. |
| D4 | `blocked-by` is the scheduling gate, and it is only consulted in the workflow's **first** active state | decided | The survey's trap: gating applied anywhere else would strand a ticket that a later state legitimately needs. `[carried]` |
| D5 | Every state change records an **activity entry as a from-to pair**, plus one **creation** entry granted a grace period before it is treated as staleness | decided | History is the audit surface; the grace period stops a ticket created seconds ago from reading as neglected. `[carried]` |
| D6 | **Attachments are keyed by URL** | decided | This is where branch, PR and CI links hang; they are facts about the outside world, not files we store. `[carried]` |
| D7 | **Comments, with threads** | decided | One flat stream cannot carry review back-and-forth; threads can, and the agent's own replies stay distinguishable from a person's. `[carried]` |
| D8 | **Autosave asymmetry**: fields autosave, utterances do not | decided | A changed field is reversible and idempotent; a posted comment is neither, so it takes an explicit submit. `[carried]` for the principle. |
| D9 | The console keeps the pages it has and gains writes on the single-ticket page first | decided | The read side already exists and is the visible argument for the service. `[verified]` (`control_tickets_live.ex`, `control_ticket_live.ex`, `ticket_presenter.ex` under `elixir/lib/symphony_elixir_web/`; write actions dispatched as of this writing). |
| D10 | Existing tickets are imported, then the file tracker becomes an **export**, not a source | decided | Preserves the offline/diff property without letting two sources of truth diverge. |
| D11 | The service is a standalone application (own repository, own SQLite, own port) | **open** - recommendation below | The recorder precedent in this workspace is exactly this shape, and it keeps the fork free of a database dependency. `[verified]` that Ecto is already a dependency but **no database adapter is** (`elixir/mix.exs`). |
| D12 | GitHub issues stay in the picture | **open** | The mirror exists so a person can watch work in GitHub; the service must either keep a one-way publish or drop it. |
| D13 | `tracker.secret_environment_names` is fixed as part of this work | **open** | It is a schema field that the application does not act on, while the specification calls it a MUST. |

## 3. The contract the service must satisfy

The service exists to feed Symphony's tracker interface, so the interface is the specification.

### 3.1 Operations

| Operation | Must answer | Note |
|---|---|---|
| list tickets by state | the tickets currently in the given states | Called on every poll; must not be expensive. `[carried]` |
| list tickets by identifier | those tickets, in the requested order | `[carried]` |
| fetch one ticket | its fields, body, comments and links | `[carried]` |
| set state | the new state, recorded as an activity entry | `[verified]` that the file tracker's write path for this is `Janitor.set_ticket_state/3`. |
| add comment | the appended entry | `[verified]` that the file tracker's write path is `Janitor.comment_on_ticket/3`. |
| create ticket | the created ticket | `[verified]` that a JSON surface already creates tickets: `elixir/lib/symphony_elixir_web/controllers/task_api_controller.ex` (`index`, `create`, `update`). |

### 3.2 Rules the survey established, which the service must keep

| Rule | Statement | Mark |
|---|---|---|
| Empty list is not an exemption | An adapter asked for no states or no ids returns `[]` and does no work; it does not fall back to "everything". | `[verified]` as a requirement (fixed for the file adapter earlier: commit `7ea7c36`), `[carried]` as a survey finding. |
| A malformed record fails the operation rather than being skipped | A record that cannot be read is an error, never silently absent, because "absent" and "unreadable" must not look alike to a scheduler. | `[carried]` |
| One envelope shape | Errors and results travel in one shape so every caller handles them the same way. The exact shape is not reproduced here. | `[carried]`, `[open]` on the shape |
| Fail closed on unknown state | A state the service does not recognise is refused, not coerced. | `[verified]` as the behaviour of the isolation flag (`5e33746`) and a principle this project has applied consistently. |

### 3.3 Fields

| Field | Source of truth | Note |
|---|---|---|
| identifier | service | Stable, human-quotable, used in branch names. |
| title, description | service | The body is the ticket. |
| state (type + name) | service | See D2/D3. |
| priority | service | `[verified]` that tickets carry it (used to order dispatch today). |
| labels | service | `[verified]` that the workflow filters dispatch by `required_labels` (field read from `elixir/lib/symphony_elixir/config/schema.ex`). |
| assignee | service | `[verified]` that the schema has it; unused in this deployment. |
| branch name | host, reflected back | The host publishes; the ticket records where the work went. `[verified]` (`branch_name` written by the host, observed on probe tickets). |
| links / attachments | host, by URL | D6. |
| comments | service | D7. |
| activity | service | D5. |
| blockers | service | D4. |

### 3.4 Agent tools

The agent reaches the tracker through tools, and a service-backed tracker must implement what
those tools promise. `[verified]` that the file adapter currently advertises **three** tools,
one of which (`ticket_state`) was added so that an agent changes state through the host rather
than by editing the file with a shell.

`[open]`: the tool list's exact names, arguments and return shapes were not read here. They must
be taken from the adapter and reproduced in this document before implementation begins.

## 4. The HTTP surface

Minimal, and deliberately not Linear-shaped. `[carried]` that the Linear adapter is GraphQL and
that pagination and its error codes exist for Linear's reasons, not Symphony's; we should not
copy them.

| Method and path | Body | Answers | Must carry |
|---|---|---|---|
| `GET /tickets?state=<s>&state=<s>` | - | a list | states filter, empty list when no states asked |
| `GET /tickets?identifier=<id>` | - | a list | order preserved |
| `GET /tickets/:id` | - | one ticket | body, comments, activity, attachments |
| `PATCH /tickets/:id` | `{state, priority, labels, assignee, title, description}` | the ticket | state change records a from-to activity entry |
| `POST /tickets/:id/comments` | `{body, parent_id?}` | the comment | explicit submit semantics (D8) |
| `POST /tickets` | `{identifier?, title, description, state?}` | the ticket | identifier generated when omitted |
| `GET /projects/:project/tickets` | - | a list | the service is multi-project; the queue directory is what disappears |
| `GET /health` | - | `{ok: true}` | used by the console's project table, as `/api/v1/state` is used today `[verified]` |

Rules for this surface: no pagination until a list can exceed a page in practice; no GraphQL;
errors in one shape; a request that names an unknown state is refused rather than coerced.

## 5. The interface spec

The console keeps its shape. What changes is that the pages read and write a service instead of
reading files.

| Surface | Becomes | Mark |
|---|---|---|
| Ticket list | unchanged in layout; filters and sorts now answered by the service | `[carried]` for the Linear conventions, `[verified]` that the page exists |
| Single-ticket pane | body and comments in the main column; state, assignee, labels, blockers, branch, PR/CI links in the right sidebar | `[carried]` |
| Create flow | one field first (title), everything else derivable or defaulted; this matches the operator's standing instruction that only a name should be required | `[verified]` as an instruction from the operator; `[carried]` as Linear's convention |
| Command menu | grouped by object (tickets, projects, states), keyboard-first | `[carried]` |
| Inbox | the human-in-the-loop queue: tickets whose state is waiting on a person | `[carried]` |

**Not building**, carried from the brief's verdict table and adopted as-is: cycles, roadmaps,
initiatives, estimates, SLAs and analytics. Also not building: Linear's GraphQL surface, its
pagination model, and its permission system; this service runs on the operator's machine behind
loopback, like the rest of this console.

## 6. Slices

Each slice is independently verifiable and ends with `mix lint` and `mix test` green.

| # | Slice | Delivers | Does not deliver | Verified by |
|---|---|---|---|---|
| 1 | Contract freeze | this document's sections 3 and 4 with every `[carried]` and `[open]` resolved from the code | any code | every operation, field and tool cited `path:line`; the four open contract items answered |
| 2 | Store and API | service with SQLite, the endpoints in section 4, and tests | no console changes, no fork changes | API tests over a temporary database; each endpoint's semantics pinned, including empty-list and unknown-state refusals |
| 3 | Thin adapter in the fork | one tracker adapter that speaks section 4, alongside the existing ones | the file tracker is not yet retired | adapter tests against a stub service; the orchestrator's dispatch tests still pass with the adapter selected |
| 4 | Console write actions | state and comment from the single-ticket page | create/edit, inbox | page tests asserting the service call and the page's response; failures render and change nothing `[verified]` as the pattern already used for the publish-mode form and the tickets-repo button |
| 5 | Markdown export | the offline/diff property as an export | no write path back into files | an export test that round-trips a known ticket set, plus a documented command |
| 6 | Retire the file tracker and the mirror | the mirror's configuration, background sweep and second parser removed | nothing kept "just in case" | `mix lint` + `mix test` green with the mirror's files deleted; the console's pages still answer |

## 7. Open questions for the operator

1. **Standalone service or embedded?** Recommended: standalone (own repository, own SQLite, own
   port), following the recorder precedent, so the fork gains no database dependency. `[verified]`
   that the fork has Ecto but no database adapter today.
2. **Do issues still need to exist on GitHub?** Tonight's mirror is what let a person watch work
   there; if the service is the console, the mirror can be dropped instead of ported.
3. **What happens to the janitor's second parser of the ticket file format?** It exists to read
   files the service would no longer write; it should be deleted with slice 6, not left reading
   an empty directory.
4. **Does `tracker.secret_environment_names` get fixed here?** It is declared in the schema and
   not acted on, while the specification calls it a MUST.
5. **Which state names survive as the human-facing vocabulary?** D3 keeps the Chinese names;
   the service can carry both a name and a type, so nothing forces a rename.

## 8. What this document does not settle

- The two research reports' contents are not reproduced, and their citations are not carried.
  Any `[carried]` claim above must be re-checked against them before slice 1 closes.
- The envelope shape for errors and results is named but not specified. `[open]`
- The agent tool list is known to be three tools in the file adapter and is otherwise unread. `[open]`
- Whether the service should speak to the recorder (which already owns a SQLite database on port
  4010 and is not running) is not decided. `[open]`

## 9. Answers to the open questions (decided by the operator, 2026-09-30)

The questions in section 7 were put to the operator; these are the answers, and they supersede the
recommendations recorded there.

1. **Standalone service or embedded?** **Standalone.** Its own application, its own SQLite, its own
   port (4020). The fork gains no database dependency, and a crashed service cannot take the
   orchestrator down with it. The recorder is the precedent on this machine: same shape, same
   operating model.
2. **Do issues still need to exist on GitHub?** **The mirror goes away.** The console becomes the
   surface. This is the decision that removes the whole family of accidents this document opens
   with: no mirrored files, no tickets repository, no second writer, no link that has to be
   guessed or dropped. Work still reaches GitHub where it belongs -- as branches and pull requests
   on the code repository.
3. **What happens to the janitor's second parser of the ticket file format?** **It is deleted with
   slice 6**, not left reading a directory nothing writes to.
4. **Does `tracker.secret_environment_names` get fixed here?** **Yes, in this work.** The field is
   declared and silently discarded, while the specification calls it a must; it is small, and it
   sits directly on the credential boundary this project cares about.
5. **Which state names survive as the human-facing vocabulary?** **Both.** The internal vocabulary
   stays English and machine-facing (the Linear-style type plus a stable name), and the console
   carries a Chinese display name alongside it: the Chinese copy that exists today stays as it is,
   and an English name is available for anyone who wants it. The scheduler branches on the type,
   never on the display name.

### What this changes in the earlier sections

- Section 6's slice 5 (markdown export) no longer carries the mirror; it is export only, for the
  offline and diffable property.
- Section 6's slice 6 now includes retiring the tickets repository and the janitor's file parser,
  not just the file tracker.
- Section 6's slice 2 targets port 4020, and slice 3's adapter talks to it over HTTP.
- The state model in D3 gains a display-name field; nothing else in D1-D10 changes.
- Section 0's first unresolved item stands: the research citations are still marked carried rather
  than verified, and whoever builds slice 1 should re-derive them from the code as they go rather
  than trusting a citation that was never in this file.

### Carried defect, found while adding write actions to the ticket page

`Janitor.Ticket.split/1` uses a regular expression whose closing delimiter is followed by
`\s*` before the body is captured, so every write rebuilds the file as
front-matter, delimiter, body -- and a ticket whose front matter is followed by a blank line
loses that blank line the first time its state or a comment is written. It is cosmetic (no
content is lost, no encoding is touched, and a refused write is still byte-identical), but it
means `set_ticket_state/3` is not literally byte-preserving for a ticket the janitor itself
created from an issue.

Two regular expressions have to change together to fix it: the one in `janitor/ticket.ex` and
the one in `tracker/file.ex`. Recorded here rather than fixed in passing, and it disappears
with slice 6 if the file tracker and the janitor's parser are retired as decided.

## 10. Cutting a deployment over to this service (procedure, rehearsed)

The mirror is already off by the operator's decision (the registry's `symphony.md` has its `tickets_repo`
line commented, `f941278`). What remains of the replacement is moving a deployment's *tracker* from the
file tracker to this service, which touches the main deployment's configuration and the two tickets
currently living in its file queue -- so it is done in this order, and steps 1-3 are reversible by
putting the old tracker block back and restarting.

**0. Know what is in the queue.** The queue directory (`workspace` of the file tracker) holds the real
tickets; the `BOARD-*.md`, `GUIDE.md` and `README.md` files beside them are the board and the notes, not
tickets. A queue in the state this one was in held two tickets, both `in-review` -- that is a
**non-active** state, so the engine does not touch them either way and the cutover cannot strand a
running agent. Check that before starting: a ticket in `ready` or `in-progress` must be dealt with first.

**1. Land or park the in-review tickets.** Their pull requests are the deliverable; landing them from the
ticket page is the console's job and is unaffected by this procedure. Do this first so the queue being
migrated is a record, not work in flight.

**2. Clear the throwaway ticket from the service (if any).** Any ticket created while proving the
adapter works is not a real ticket; the service has no delete, so the clean way is: stop the service,
move `~/.symphony-tickets/tickets.db` aside as a backup, start it again (an empty database is created on
first use), and keep the backup until the cutover is verified.

**3. Import the queue's tickets.** `POST /tickets` once per ticket, with the body in a **file** and
`--data-binary @file`: never build JSON by string interpolation in a shell, because a Windows shell
mangles the quotes and the service answers `malformed request body` -- a mistake this project made twice.
Send `title`, `description` (the body of the markdown file, below its front matter) and
`state: {type, name, display_name}`; omit `state` entirely to take the store's default. Then read each one
back with `GET /tickets/:ref` and confirm the description arrived. **This path was rehearsed** against a
copy of the database on a scratch port: two real queue tickets imported, both readable, descriptions
intact.

**4. Switch the tracker block.** In the deployment's workflow, `tracker.kind` changes from `file` to
`ticket_service`, the `provider.path` line is replaced by `provider.url: http://127.0.0.1:4020`, and
`active_states` / `terminal_states` stay exactly as they are -- they are the workflow's own vocabulary
and the adapter sends those names through unchanged. The running escript must be rebuilt first
(`mix escript.build`): the service adapter only exists in a build made after it landed, and a stale
escript fails at boot with `unsupported_tracker_kind`.

**5. Verify, then retire the file layer.** After a restart, `GET /api/v1/state` on the deployment's port
should show the imported tickets; the ticket pages under `/control/tickets` should render their bodies
read through the adapter; and the next dispatched ticket should reach `in-review` with its state and its
report written back into the service. Keep the queue directory **read-only** for a few rounds -- it is the
only copy of the old record until then, and it is also what makes the rollback one line. Only after that:
remove the queue, and then delete the janitor's second parser of the ticket format.

**Rollback.** Point `tracker.kind` back at `file` and restart. The queue was never deleted, the service
keeps whatever it was given, and the export (`mix symphony_tickets.export --out DIR`) can produce a
diffable markdown copy of the service's tickets at any time -- which is how the property the mirror used
to provide is kept without the mirror.
