---
name: obsidian-memory
description: Retrieve and maintain cross-project working and durable memory in the configured Obsidian vault. Use before and after non-trivial or repeated work to reuse decisions, failures, constraints, and progress. Do not use for raw conversation archival.
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

## Before Non-trivial Work

Read [memory workflow](references/memory-workflow.md), then:

1. Derive a small set of retrieval cues from the repository or project,
   component, error or symptom, and decision being made.
2. Search the matching project/component under
   `$VAULT_ROOT/notes/agent-memory` first, then the rest of `notes/` before
   broadening to daily notes or archived material.
3. Read only the matching sections and the few directly linked notes needed
   to understand them.
4. Extract relevant decisions, known failures, constraints, and unfinished
   progress. Ignore coincidental keyword matches.
5. Verify memory against current files, tests, external sources when needed,
   and the user's current instructions. Current evidence wins.

Treat related turns as one task. Search when work revisits an earlier decision,
changes architecture/defaults/paths/workflows, retries a failed fix, or reaches
a second correction turn. Routine, isolated, low-risk edits still need no pass.

## After the Task

Write back a concise working memory when the result may guide a later turn.
This includes decisions, failures and causes, constraints, reliable procedures,
or unfinished state. Prefer an imperfect useful memory over losing context.

Update `notes/agent-memory/<project>/<component>.md` rather than creating a
note per task. Promote stable, human-facing knowledge into the most relevant
regular note and link the two when useful. Read [memory workflow](references/memory-workflow.md)
for storage and promotion details.

Do not store full conversations, generic summaries, tool logs, routine status,
temporary observations, secrets, credentials, or facts obvious from the code.

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
