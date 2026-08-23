---
name: obsidian-memory
description: Build and reuse durable project expertise while maintaining living component specifications in the configured Obsidian vault. Use before and after work beyond minor changes, or repeated work. Do not use for raw conversation archival.
---

# Obsidian Memory

Use the Obsidian vault as an external project brain. Grow component notes into
living specifications so future work starts with an experienced engineer's map
of the system and the durable knowledge likely to affect later decisions.

This skill handles retrieval and maintenance of agent-only expertise. Use the
broader `obsidian` skill for ordinary notes, formatting, Bases, Canvas, and
interactive Neovim workflows.

## Resolve the Vault

Before every vault operation, run the resolver relative to this skill:

```sh
nvim --headless --clean -u NONE -l <skill-dir>/scripts/resolve_vault.lua
```

Use its output as `VAULT_ROOT`. Never reuse a path from an earlier task or
guess when resolution fails.

## Retrieve Before Work Beyond Minor Changes

1. Derive a few cues from the project, component, feature, symptom, and likely
   responsibility involved.
2. Search the matching project/component under
   `$VAULT_ROOT/notes/agent-memory` first, then the rest of `notes/` only when
   needed. Search filenames, headings, and distinctive terms with `rg`.
3. Read only the relevant sections and the few directly linked notes needed to
   act. Stop when the evidence is sufficient.
4. Recover the component's current behavior and responsibilities, important
   flows and interfaces, invariants, source anchors and likely change points,
   plus relevant decisions, failures, constraints, and unfinished work.
5. Verify memory against current code, tests, authoritative sources, and the
   user's instructions. Use memory as a navigation map, not as source of truth.

Treat related turns as one task. Search again when work revisits a component,
changes architecture, defaults, paths, or workflows, retries a failed fix, or
reaches a second correction turn. Routine isolated edits need no pass.

## Learn and Maintain Through Work

Update the owning component note when work reveals or verifies reusable project
knowledge, whether investigation was explicitly requested or happened
incidentally. Preserve both future-useful non-obvious insight and ordinary facts
needed to make the touched specification coherent. If the work did not improve
project understanding, do not force an update. Valuable knowledge includes:

- component responsibilities and boundaries;
- runtime or data flow, lifecycle, state ownership, and ordering;
- interfaces, protocols, contracts, invariants, and accepted behavior;
- source entry points, important symbols, and non-obvious change hotspots;
- design rationale, rejected alternatives, failures and causes, constraints,
  reliable verification, and substantial unfinished work.

Use each update to complete or correct the specification within the task's
verified scope. Fill adjacent gaps when the evidence is already available, but
do not audit unrelated components or guess. Prefer synthesis over copied source;
skip ephemeral observations, redundant detail, and exhaustive inventories.

Update `notes/agent-memory/<project>/<component>.md` in place; do not create a
note per task. Treat these notes collectively as the project's agent-facing
specification. Replace stale claims instead of appending contradictory history,
and keep each note concise enough to retrieve selectively.

Write agent-memory headings and prose in English by default so source symbols,
errors, and architectural terms remain directly searchable. Preserve Japanese
aliases and distinctive Japanese symptom phrases when they improve retrieval.
Do not bulk-translate existing notes; migrate them when materially updating the
owning component note.

Do not store conversations, generic summaries, command logs, passing-test
lists, secrets, credentials, or routine status.

For a new component note, a note that needs splitting or conflict repair, read
[memory maintenance](references/memory-workflow.md). Do not read it for an
ordinary search or focused update. Create or update a human-facing regular note
only when the user explicitly requests documentation; then read
[human-facing notes](references/human-facing-notes.md).

## Authority and Conflicts

Apply this precedence:

1. current user instructions
2. current code, configuration, tests, and authoritative external sources
3. Obsidian memory

When memory is stale in the task's scope, correct it. If current evidence cannot
resolve a conflict, record the uncertainty and how to verify it.

## Boundary with Conversation Memory

Use `brain` when missing chat wording or conversation history matters. Use this
skill for curated project knowledge that should survive across sessions. Do not
duplicate raw chat history into Obsidian.
