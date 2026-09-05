---
name: obsidian-memory
description: Build and reuse project knowledge as living design specifications in Obsidian. Use before and after non-minor work, and when revisiting or correcting prior work. Do not use for conversation archival.
---

# Obsidian Memory

Grow component notes into a coherent design specification as work teaches us
how the project behaves and why. Future work should recover responsibilities,
flows, constraints, and decisions without repeating the investigation.

User instructions and current evidence take precedence over memory. Check
notes against code, tests, and authoritative specifications before relying on
them; preserve unresolved differences rather than silently choosing a winner.

## Locate and Retrieve

At the start of each retrieval or write-back pass, resolve the vault:

```sh
nvim --headless --clean -u NONE -l <skill-dir>/scripts/resolve_vault.lua
```

Use the output as `VAULT_ROOT`; do not guess on failure or reuse a path from
an earlier task.

1. Find candidate notes with `rg --files "$VAULT_ROOT/notes/agent-memory"`,
   using repository, component, feature, and symptom cues. Reuse the existing
   project owner: a plugin's notes may belong under `dotfiles/`. For a new
   project, use the repository name rather than the current subdirectory.
2. Search matching notes' headings and content with `rg`. Expand into the
   rest of `notes/` only when needed. Read relevant sections and direct links,
   then follow source anchors to verify the behavior involved in the task.

Treat related turns as one task. Search again when revisiting prior work,
retrying a failed fix, or changing architecture, defaults, paths, or workflows.
Routine isolated edits need no pass.

## Maintain the Specification

Integrate reusable knowledge learned deliberately or incidentally into
`notes/agent-memory/<project>/<component>.md`. Update the owning note in place;
if project understanding did not improve, do not force a write.

- Build coverage of responsibilities, interfaces, flows, state ownership,
  invariants, design rationale, and substantial open work. Include ordinary
  facts needed to make the design coherent, without auditing unrelated areas.
- Distinguish implemented behavior, intended design, and unverified hypotheses.
  Anchor material claims to source symbols or tests and the conditions they
  actually cover. A note's update date does not mean every claim was rechecked.
  For unresolved differences, retain both sources and how to resolve them.
- When a coherent specification exists in the repository or a system such as
  Confluence, keep a locator: repository-relative path plus symbol or heading,
  or page title plus stable URL/ID and section. Add only missing durable context
  or discrepancies. Line numbers are optional navigation hints.
- Replace stale claims and consolidate overlapping passages. Reduce past
  failures to the cause, constraint, or rejected approach that matters for
  future decisions. Preserve useful reasoning while removing task chronology.
- Preserve IDs, `created`, and unknown frontmatter; set `updated` to today's
  date for meaningful content changes. Reread the touched section for
  contradictions, duplicate claims, and broken source anchors.

Write headings and prose in English, retaining Japanese aliases and distinctive
symptoms when useful for retrieval. Migrate existing prose only when materially
updating its component. Never store chats, logs, secrets, routine status, or
passing-test lists.

## Conditional References

- For a new note, splitting, or conflict repair, read
  [note structure](references/memory-workflow.md). Ordinary updates need only
  this file.
- Agent memory is maintained through normal work. Create or update regular
  human-facing notes only when the user requests documentation; then read
  [human-facing notes](references/human-facing-notes.md).
- Use `obsidian` for general vault and editor workflows; use `brain` when exact
  conversation history is needed.
