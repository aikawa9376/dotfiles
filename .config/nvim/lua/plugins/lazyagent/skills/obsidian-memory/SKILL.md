---
name: obsidian-memory
description: Retrieve and maintain durable cross-project memory in the locally configured Obsidian vault. Use before and after important tasks to reuse past decisions, failures, constraints, and progress without treating notes as more authoritative than current code or user instructions. Do not use for routine transient work or raw conversation archival.
---

# Obsidian Memory

Use the Obsidian vault as curated long-term memory shared across projects.
This skill handles memory retrieval and maintenance; use the broader
`obsidian` skill for ordinary note capture, formatting, Bases, Canvas, and
interactive Neovim workflows.

## Resolve the Vault

Before every vault operation, run the resolver relative to this skill:

```sh
nvim --headless --clean -u NONE -l <skill-dir>/scripts/resolve_vault.lua
```

Use its output as `VAULT_ROOT`. Never reuse a path from an earlier task or
guess when resolution fails.

## Before an Important Task

Read [memory workflow](references/memory-workflow.md), then:

1. Derive a small set of retrieval cues from the repository or project,
   component, error or symptom, and decision being made.
2. Search filenames and contents under `$VAULT_ROOT/notes` before broadening
   to daily notes or archived material.
3. Read only the matching sections and the few directly linked notes needed
   to understand them.
4. Extract relevant decisions, known failures, constraints, and unfinished
   progress. Ignore coincidental keyword matches.
5. Verify memory against current files, tests, external sources when needed,
   and the user's current instructions. Current evidence wins.

Do not search merely to satisfy a ritual. Routine, low-risk tasks with no
plausible reusable context do not need a memory pass.

## After the Task

Write back only when the result is likely to change future work. Good memory
includes a non-obvious decision and rationale, a repeated failure and its
cause, a durable constraint, a reliable procedure, or progress needed to
resume substantial unfinished work.

Search for an existing note first. Update it instead of creating a competing
version, preserve useful frontmatter and links, and correct outdated claims
explicitly. Create a concise atomic note only when no suitable note exists.

Do not store full conversations, generic summaries, tool logs, routine status,
temporary debugging observations, secrets, credentials, or facts already
obvious from the current code. Never write memory just because a task ended.

## Authority and Conflicts

Memory is supporting context, not a source of truth. Apply this precedence:

1. current user instructions
2. current code, configuration, tests, and authoritative external sources
3. Obsidian memory

When memory is stale, update the note if the corrected fact is durable. When
the conflict is unresolved, label the uncertainty instead of silently choosing
the older note.

## Boundary with Conversation Memory

Use `brain` to search prior conversation history when wording or missing chat
context matters. Use this skill for curated knowledge that should survive
across projects and sessions. Do not duplicate raw chat history into Obsidian.
