# Agent Memory Maintenance

Read this reference only when creating a component note, reorganizing or
splitting one, or resolving stale or conflicting memory. Ordinary retrieval and
focused updates are defined in `SKILL.md` and do not require this file.

## Placement

Keep working knowledge under `notes/agent-memory/<project>/`. Prefer one note
per coherent component or responsibility. Revise it in place instead of
creating chronological task notes.

Choose component boundaries that match how engineers navigate the system. A
component may be a subsystem, protocol, feature area, service, or cross-cutting
responsibility. Split a note when unrelated concerns make selective retrieval
difficult; do not split merely because the note has grown.

When a project has many component notes or important cross-component flows, an
optional `notes/agent-memory/<project>/index.md` may map responsibilities and
links. Keep it architectural and stable rather than listing every file or task.

## New Note Shape

Preserve established frontmatter. A new note should normally use this shape:

```markdown
---
id: 1787273693-ABCD
aliases: []
tags: []
type: agent-memory
source: lazyagent
status: seed
created: YYYY-MM-DD
updated: YYYY-MM-DD
project: <repository-slug>
---

# Project / component memory

One-sentence responsibility and conclusion.

## Responsibilities and boundaries

What this component owns, what it delegates, and what it must not do.

## Current behavior

Lifecycle, state ownership, ordering, data flow, interfaces, and invariants.

## Source anchors

Stable entry points and symbols, with a short explanation of why each matters.

## Decisions and failures

Non-obvious rationale, rejected approaches, root causes, fixes, and constraints.

## Verification

Current source, tests, or authoritative references that confirmed the claims.

## Open work

Substantial unfinished work needed for safe continuation.
```

Generate a fresh ID using the vault's existing timestamp-plus-suffix pattern;
the values above only illustrate the shape. Replace or omit the example
`project` property rather than copying a placeholder. Omit optional properties
and sections that add no value. Keep `created` unchanged on updates, change
`updated` only for meaningful content changes, and preserve unknown properties.

## Maintenance

1. Search by project, component, responsibility, feature, title, aliases, and
   distinctive behavior before creating a note.
2. Update the note that owns the responsibility. Link another component note
   rather than duplicating shared behavior.
3. Prefer current synthesized behavior over investigation chronology. Preserve
   a short `Previously` item only when the old behavior prevents a future
   mistake.
4. Keep source anchors selective. Record architectural entry points and
   important symbols, not a changed-file inventory or fragile line numbers.
5. If a claim is stale, replace it and re-check linked notes or an optional
   project index for the same claim.
6. If evidence cannot resolve a conflict, state what is known, what is
   uncertain, and the exact source or test that can resolve it.

Never promote a guess into durable knowledge. Do not create or update a daily
note unless chronology itself is useful or the user requested it.
