# Durable Memory Workflow

## Retrieval

Start narrow. Useful cues usually come from four groups:

- project: repository name, product, branch, or subsystem
- subject: component, protocol, API, or feature
- symptom: exact error fragment, failure mode, or performance issue
- decision: approach names, rejected alternatives, constraint, or invariant

Search filenames and content with `rg`, then inspect context around matches.
Search the relevant project/component under `notes/agent-memory/` first, then
permanent notes under `notes/`; consult `daily/` only when reconstructing recent
progress or when those searches find nothing. Follow links only when their
titles or surrounding sentences indicate direct relevance.

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

## Storage Tiers

Use `notes/agent-memory/<project>/<component>.md` for working memory. Keep one
note per component and revise it in place; do not create chronological task
notes. Keep concise sections for current behavior, decisions, known failures,
constraints, verification, and open work.

Keep durable knowledge in agent memory by default, even when it describes a
specification or design. Create, update, or promote content into a human-facing
regular note under `notes/` only when the user explicitly asks for it to be
summarized into such a note, documented there, or made into a specification.
When promotion is requested, update an existing canonical note before creating
one, link it to working memory when useful, and remove or supersede stale
working-memory claims.

## Canonical Specifications

Research may establish a specification, design, protocol, behavioral contract,
or implementation plan and still remain agent-only knowledge. Do not create or
update a human-facing canonical note merely because the research is durable or
should guide future work.

Create or update a human-facing specification only when the user explicitly
asks for the knowledge to be summarized into a human-facing note, documented
there, promoted, or made into a specification. A request to answer,
investigate, or summarize within the conversation is not by itself
authorization to create such a note.

When the user requests a human-facing specification, choose scope by the
lifetime of the knowledge:

- project-wide or branch-independent knowledge belongs to the project's
  canonical notes;
- branch-specific proposals, temporary deviations, and unfinished designs
  belong to the corresponding project or branch note;
- after a branch-specific design becomes accepted project behavior, promote it
  to the project-level specification and remove or supersede the temporary
  branch-scoped version.

Update an existing specification before creating a new one. When the subject
needs multiple files, create a coherent specification directory with a clear
index note that identifies the canonical documents. Keep the agent-memory note
concise and link it to the specification rather than duplicating the full
content.

Without an explicit request for a human-facing document, capture qualifying
behavior, constraints, interfaces, architecture, acceptance criteria, and
decisions only in the relevant agent-memory note.

## Note Shape

Keep working memory under `notes/agent-memory/` and canonical knowledge in the
vault's existing `notes/` hierarchy. Preserve established frontmatter. A new
working-memory note should normally use this shape:

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

One-sentence conclusion.

## Current behavior

The current state needed to continue safely.

## Decisions and failures

Non-obvious choices, rejected approaches, root causes, and fixes.

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
2. Update the component working-memory note. Update a canonical human-facing
   note only when the user explicitly requested that documentation work.
3. Replace stale statements rather than appending contradictory chronology.
4. Preserve a short “Previously” or decision-history note only when knowing
   the old behavior prevents a future mistake.
5. Link related concepts and the project's existing index when one exists.
6. Do not create or update a daily note unless chronological retrieval is
   genuinely useful or the user requested it.

If current evidence cannot resolve a conflict, record what is known, what is
uncertain, and how to verify it. Never promote a guess into durable memory.
