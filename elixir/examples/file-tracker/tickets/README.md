# Example tickets

This directory is a working `kind: file` backlog. Copy it somewhere and point
`tracker.provider.path` at the copy (see the commented block in `elixir/WORKFLOW.md`).

- One file per ticket. Markdown with YAML front matter; the **body becomes the issue
  description**, so write it like a task brief.
- Move work along by editing `state:`. It only has to match the `active_states` /
  `terminal_states` your workflow declares.
- `active_states: [open, ready]` means `T-1` is picked up and `T-2` is held back by its
  `blocked_by:` entry (held back = visible as blocked, not silently dropped).

This file has no front matter, which is exactly why it is ignored rather than parsed as a
ticket -- notes may live next to the backlog.
