---
name: obsidian
description: Work effectively with the local Obsidian vault in ~/workspace/obsidian. Use this for daily notes, permanent notes, wiki links, tags, and note refactors that match the current obsidian.nvim setup.
---

# obsidian

Use this skill when the task is about capturing, organizing, or refining knowledge in the local Obsidian vault.

## Instructions

Before creating a new note, search the vault for an existing note on the same topic and prefer linking over duplicating.

### When to Use

- **Daily capture**: Add a progress log, journal entry, or meeting memo to today's daily note.
- **Permanent note creation**: Turn a conversation, idea, or task outcome into a durable note under `notes/`.
- **Note refactoring**: Split a large note, extract a subtopic, rename a note, or improve links and tags.
- **Knowledge gardening**: Add backlinks, related-note links, tags, and concise summaries so notes stay discoverable.
- **Obsidian command guidance**: Suggest the right `obsidian.nvim` command when the user is working inside Neovim.

### Vault Conventions

- Vault path: `~/workspace/obsidian`
- Regular notes: `notes/`
- Daily notes: `daily/`
- Templates: `templates/`
- Image attachments: `assets/imgs/`
- Preferred internal link style: wiki links like `[[note title]]`
- Existing note shape:

```markdown
---
id: 1779496407-LYHF
aliases:
- hello obsidian
tags: []
---

# hello obsidian
```

When you create or rewrite a note directly, preserve that structure: frontmatter first, then an H1 title, then concise body content.

## Available References

- **[conventions](references/conventions.md)**: Vault layout, note shape, and writing conventions for this setup.
- **[commands](references/commands.md)**: `obsidian.nvim` commands available in the current Neovim configuration.
- **[workflows](references/workflows.md)**: Practical workflows for daily notes, permanent notes, refactors, and linking.

## Guidelines

- Prefer small, atomic notes over long mixed-topic notes.
- Prefer links to other notes over repeating the same explanation in multiple places.
- Keep titles concrete and stable; rename notes only when it improves retrieval.
- Use tags sparingly. Prefer links first, tags second.
- When summarizing a coding task or discussion, keep the final note readable without the chat transcript.
- If the user asks for a note update but does not name the file, infer the best location from the vault conventions above.

## Examples

### 1. Add work log to today's note

> 今日やったことを daily note に追記して、関連ノートがあればリンクして

### 2. Turn a discussion into a permanent note

> この会話を Obsidian に整理して保存して。重複ノートがあれば新規作成せず更新して

### 3. Refactor a rough note

> この雑多なメモを、1 トピック 1 ノートになるように分割して wiki link を張って
