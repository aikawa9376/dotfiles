# Obsidian Vault Conventions

Use these conventions when reading or writing notes in this environment.

## Layout

- Vault root: `~/workspace/obsidian`
- Permanent notes: `~/workspace/obsidian/notes`
- Daily notes: `~/workspace/obsidian/daily`
- Templates: `~/workspace/obsidian/templates`
- Image attachments: `~/workspace/obsidian/assets/imgs`
- HTML artifacts: `~/workspace/obsidian/assets/html`
- Bases: `~/workspace/obsidian/bases`

## Note Shape

Regular notes should follow the existing `obsidian.nvim` style:

```markdown
---
id: 1779496407-LYHF
aliases:
- hello obsidian
tags: []
type: knowledge
source: manual
status: seed
created: 2026-07-25
updated: 2026-07-25
---

# hello obsidian

One concise idea per note.
```

Keep `id`, `aliases`, and `tags` compatible with `obsidian.nvim`. Add the
following properties to new permanent notes when they are meaningful:

| Property | Values and use |
| --- | --- |
| `type` | `knowledge`, `reference`, `report`, `project`, `meeting`, or `daily` |
| `source` | `manual`, `lazyagent`, or `web` |
| `status` | `seed`, `evergreen`, or `archived` |
| `created` | Creation date as `YYYY-MM-DD` |
| `updated` | Last meaningful content update as `YYYY-MM-DD` |
| `project` | Repository or project name; omit when unrelated |
| `branch` | Git branch for a branch-scoped project note; omit otherwise |
| `source_url` | Canonical URL for a web reference; omit otherwise |
| `artifact` | Vault-relative companion file such as `assets/html/topic.html` |

Do not add empty optional properties. Preserve unknown existing properties.
When updating a note, keep `created` unchanged and update `updated`.

## Writing Rules

1. Search first, then create or update.
2. Prefer `[[wiki links]]` for note-to-note references.
3. Keep notes easy to scan: short intro, short sections, tight bullets.
4. Preserve useful aliases when renaming or consolidating a note.
5. Prefer links over large tag taxonomies.
6. Use properties for stable facets used by Bases; use links for conceptual relationships.

## Daily Notes

Daily notes belong in `daily/` and should usually include:

- short summary of the day or session
- tasks or follow-ups
- links to permanent notes created or updated that day

If a daily note does not exist yet, create `daily/YYYY-MM-DD.md`.

## Branch-Scoped AI Notes

When an agent creates or meaningfully updates a permanent note while working
inside a Git repository:

1. Set `source: lazyagent` on agent-authored notes.
2. Set `project` to the repository slug and `branch` to the exact Git branch.
3. Do not turn repository or branch names into tags. They are high-cardinality,
   short-lived facets and belong in properties.
4. Open or create the matching branch note at
   `notes/projects/<repo>/<branch>.md`. Branch names containing `/` use nested
   directories, matching `:ObsidianBranchNote`.
5. Give a new branch note `type: project`, `project`, `branch`,
   `source: manual`, and `status: seed`.
6. Add the permanent note once under the branch note's `## AI notes` heading.
   Use a `[[wiki link]]` and do not duplicate an existing link.

This uses properties for filtering, `source: lazyagent` for provenance, and the
branch note as the human-readable index. If there is no Git repository or
branch context, omit `project` and `branch` and do not invent a branch note.
