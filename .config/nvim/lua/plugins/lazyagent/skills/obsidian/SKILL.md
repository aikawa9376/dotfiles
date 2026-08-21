---
name: obsidian
description: Capture, organize, retrieve, and visualize knowledge in the locally configured Obsidian vault. Use for daily or permanent notes, agent-result capture, web articles, paired Markdown and HTML reports, Obsidian Markdown, properties, wiki links, Bases dashboards, JSON Canvas maps, note refactors, and interactive obsidian.nvim workflows.
---

# obsidian

## Instructions

Before any vault operation, resolve `scripts/resolve_vault.lua` relative to the
directory containing this `SKILL.md`, run it with Neovim, and use its output as
`VAULT_ROOT`:

```sh
nvim --headless --clean -u NONE -l <skill-dir>/scripts/resolve_vault.lua
```

The script reads the current `opts.workspaces` value from
`${XDG_CONFIG_HOME:-~/.config}/nvim/lua/plugins/obsidian.lua`, preferring the
workspace named `main`. Resolve the vault on every task; do not copy its
current value into this skill or fall back to an old hard-coded path. If
resolution fails, inspect that Neovim configuration and ask the user rather
than guessing.

Before creating a new note, search the vault for an existing note on the same topic and prefer linking over duplicating.

Route the task to the smallest relevant reference:

- Read [upstream](references/upstream.md) when auditing this skill against,
  updating from, or troubleshooting differences with Steph Ango's
  `kepano/obsidian-skills` repository.
- Read [conventions](references/conventions.md) whenever creating or rewriting a note.
- Read [markdown](references/markdown.md) for Obsidian-specific links, embeds,
  properties, callouts, comments, tags, math, diagrams, or formatting.
- Read [workflows](references/workflows.md) for daily capture, permanent notes, agent results, refactors, and linking.
- Read [web capture](references/web-capture.md) when a URL or online article should become a note.
- Read [HTML artifacts](references/html-artifacts.md) when the request uses `#obsidian-html` or explicitly asks for an HTML companion.
- Read [bases](references/bases.md) when creating or debugging a `.base` file,
  including filters, formulas, summaries, and table, card, list, or map views.
- Read [canvas](references/canvas.md) when creating or editing a mind map,
  architecture map, or other `.canvas` visualization.
- Read [commands](references/commands.md) for interactive work in Neovim or
  when the user explicitly requests the official Obsidian CLI. Prefer
  `obsidian.nvim` for normal work in this setup.

### Vault Conventions

- Vault path: the dynamically resolved `VAULT_ROOT`
- Regular notes: `notes/`
- Daily notes: `daily/`
- Templates: `templates/`
- Image attachments: `assets/imgs/`
- HTML artifacts: `assets/html/`
- Bases dashboards: `bases/`
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
- **[upstream](references/upstream.md)**: Source provenance, upstream mapping, and synchronization procedure.
- **[markdown](references/markdown.md)**: Obsidian-specific Markdown, wikilinks, embeds, callouts, and validation.
- **[commands](references/commands.md)**: `obsidian.nvim` commands available in the current Neovim configuration.
- **[workflows](references/workflows.md)**: Practical workflows for daily notes, permanent notes, refactors, and linking.
- **[web capture](references/web-capture.md)**: Extract, distill, and save online articles with Defuddle.
- **[HTML artifacts](references/html-artifacts.md)**: Pair a searchable Markdown note with a polished standalone HTML document.
- **[bases](references/bases.md)**: Build `.base` dashboards from standardized note properties.
- **[canvas](references/canvas.md)**: Build and validate JSON Canvas maps.

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
