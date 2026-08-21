# Durable Memory Workflow

## Retrieval

Start narrow. Useful cues usually come from four groups:

- project: repository name, product, branch, or subsystem
- subject: component, protocol, API, or feature
- symptom: exact error fragment, failure mode, or performance issue
- decision: approach names, rejected alternatives, constraint, or invariant

Search filenames and content with `rg`, then inspect context around matches.
Prefer permanent notes under `notes/`; consult `daily/` only when reconstructing
recent progress or when permanent-note search finds nothing. Follow links only
when their titles or surrounding sentences indicate direct relevance.

Stop when the evidence is sufficient to act. A useful retrieval result is a
small set of concrete facts with note paths, not a catalog of every match.

## What Deserves to Be Written

Write memory when at least one of these is true:

- future work could repeat an expensive investigation without it;
- a choice has non-obvious rationale or a rejected alternative likely to
  return;
- a failure mode, root cause, and proven resolution generalize beyond the
  current turn;
- an environmental or architectural constraint is easy to overlook;
- substantial unfinished work needs an accurate resumption point;
- existing memory was proven stale and the correction matters later.

Do not write when the result is merely a list of changed files, commands run,
passing tests, conversational context, or a fact easily recovered from current
source. Prefer updating one useful note over creating a session report.

## Note Shape

Keep durable memories in the vault's existing `notes/` hierarchy rather than
a separate memory silo. Preserve the vault's established frontmatter. A new
agent-authored note should normally use this shape:

```markdown
---
id: 1787273693-ABCD
aliases: []
tags: []
type: knowledge
source: lazyagent
status: seed
created: YYYY-MM-DD
updated: YYYY-MM-DD
project: <repository-slug>
---

# Concrete stable title

One-sentence conclusion.

## Decision or finding

The durable fact and enough context to apply it correctly.

## Rationale

Why this is true, including rejected alternatives when they may recur.

## Verification

The current source, test, or authoritative reference that confirmed it.
```

Generate a fresh ID using the vault's existing timestamp-plus-suffix pattern;
the values above only illustrate its shape. Replace or omit the example
`project` property rather than copying a placeholder. Omit optional properties
and sections that add no value. Keep `created`
unchanged on updates, change `updated` only for meaningful content changes,
and preserve unknown properties.

## Updating and Superseding

1. Search by title, aliases, project, component, and distinctive phrases.
2. Update the most specific existing note that owns the knowledge.
3. Replace stale statements rather than appending contradictory chronology.
4. Preserve a short “Previously” or decision-history note only when knowing
   the old behavior prevents a future mistake.
5. Link related concepts and the project's existing index when one exists.
6. Do not create or update a daily note unless chronological retrieval is
   genuinely useful or the user requested it.

If current evidence cannot resolve a conflict, record what is known, what is
uncertain, and how to verify it. Never promote a guess into durable memory.
