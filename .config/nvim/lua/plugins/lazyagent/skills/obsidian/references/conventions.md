# Obsidian Vault Conventions

Use these conventions when reading or writing notes in this environment.

## Layout

- Vault root: `~/workspace/obsidian`
- Permanent notes: `~/workspace/obsidian/notes`
- Daily notes: `~/workspace/obsidian/daily`
- Templates: `~/workspace/obsidian/templates`
- Image attachments: `~/workspace/obsidian/assets/imgs`

## Note Shape

Regular notes should follow the existing `obsidian.nvim` style:

```markdown
---
id: 1779496407-LYHF
aliases:
- hello obsidian
tags: []
---

# hello obsidian

One concise idea per note.
```

## Writing Rules

1. Search first, then create or update.
2. Prefer `[[wiki links]]` for note-to-note references.
3. Keep notes easy to scan: short intro, short sections, tight bullets.
4. Preserve useful aliases when renaming or consolidating a note.
5. Prefer links over large tag taxonomies.

## Daily Notes

Daily notes belong in `daily/` and should usually include:

- short summary of the day or session
- tasks or follow-ups
- links to permanent notes created or updated that day

If a daily note does not exist yet, create `daily/YYYY-MM-DD.md`.
