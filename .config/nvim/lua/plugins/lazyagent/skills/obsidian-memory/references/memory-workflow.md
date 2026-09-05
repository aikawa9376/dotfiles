# Note Structure and Reorganization

Use this reference for new component notes, splits, or conflict repair.
The retrieval and update rules in `SKILL.md` also apply.

## New Notes

Choose one coherent responsibility under `notes/agent-memory/<project>/`.
Use the existing vault conventions; a minimal note can start with:

```markdown
---
id: <timestamp>-<suffix>
aliases: []
type: agent-memory
source: lazyagent
status: seed
created: YYYY-MM-DD
updated: YYYY-MM-DD
project: <repository-name>
---

# Project / component

One-sentence responsibility and current design.

## Behavior and Boundaries

Responsibilities, interfaces, flows, state ownership, and invariants.

## Decisions and Evidence

Design reasons, constraints, and source or test anchors for the claims above.

## Open Work

Unresolved questions and what would settle them.
```

Generate a fresh ID using the vault's timestamp-plus-suffix convention.
Adapt headings to the component and omit empty sections. An existing canonical
specification may need only a locator and any missing durable context.

## Reorganization

Split when unrelated responsibilities make selective retrieval difficult,
not merely because a note is long. Keep shared behavior with its owning
component and link to it. An optional project `index.md` can map responsibilities
and cross-component flows when discovery becomes difficult.

For overlapping or conflicting notes, identify the owner, reconcile claims
against current evidence, and repair affected links. Leave unresolved claims
explicit; preserve the context needed to verify them.
