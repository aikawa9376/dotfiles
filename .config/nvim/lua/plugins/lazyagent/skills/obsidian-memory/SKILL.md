---
name: obsidian-memory
description: Build and reuse durable project expertise in the configured Obsidian vault. Use before and after work beyond minor changes, or repeated work, to retain component behavior, architecture, interfaces, decisions, failures, constraints, and progress. Do not use for raw conversation archival.
---

# Obsidian Memory

Use the Obsidian vault as an external project brain. Grow component-level
knowledge so future work starts from an experienced engineer's map of how the
system behaves, where responsibilities live, and what code is likely to change.

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

## Learn From the Work

After the task, update memory when investigation revealed durable project
knowledge that would help a future engineer understand or change the system.
Capture existing behavior even when no new design decision was made. Valuable
knowledge includes:

- component responsibilities and boundaries;
- runtime or data flow, lifecycle, state ownership, and ordering;
- interfaces, protocols, contracts, invariants, and accepted behavior;
- source entry points, important symbols, and non-obvious change hotspots;
- design rationale, rejected alternatives, failures and causes, constraints,
  reliable verification, and substantial unfinished work.

Keep synthesized knowledge that required tracing multiple files, connecting
concepts, or resolving ambiguity, even though it can ultimately be derived
from code. Skip facts obvious from one local source location and facts unlikely
to affect future understanding or changes.

Update `notes/agent-memory/<project>/<component>.md` in place; do not create a
note per task. Replace stale claims instead of appending contradictory history.
Keep the note concise enough to retrieve selectively. The result should help a
future agent know what area and symbols to inspect, while still requiring
verification against current source.

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

When memory is stale, correct it if the result is durable. If current evidence
cannot resolve a conflict, record the uncertainty and how to verify it.

## Boundary with Conversation Memory

Use `brain` when missing chat wording or conversation history matters. Use this
skill for curated project knowledge that should survive across sessions. Do not
duplicate raw chat history into Obsidian.
