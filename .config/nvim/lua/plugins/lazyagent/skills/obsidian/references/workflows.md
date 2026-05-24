# Obsidian Workflows

## 1. Daily Capture

Use for prompts like:

- `今日の daily note に追記して`
- `この作業内容を日報として残して`

Workflow:

1. Open or create today's daily note in `daily/YYYY-MM-DD.md`.
2. Add a short summary, tasks, and relevant links.
3. Link any permanent notes that were created or updated during the work.

## 2. Permanent Note Creation

Use for prompts like:

- `この会話を Obsidian に保存して`
- `このアイデアを再利用しやすい note にして`

Workflow:

1. Search for an existing note on the same concept.
2. If one exists, update it instead of creating a duplicate.
3. If none exists, create a note in `notes/` with frontmatter, an H1 title, and a concise body.
4. Add links to adjacent concepts or source notes.

## 3. Refactor and Split

Use for prompts like:

- `このノートを整理して`
- `話題ごとに分割して`

Workflow:

1. Identify distinct topics in the source note.
2. Keep the source note as an index or overview when that helps navigation.
3. Extract stable subtopics into separate notes.
4. Replace duplicated prose with `[[wiki links]]`.

## 4. Linking and Retrieval

Use for prompts like:

- `関連ノートをつないで`
- `検索しやすくして`

Workflow:

1. Prefer explicit links between related notes.
2. Add aliases for alternate names or abbreviations.
3. Add a small number of meaningful tags only when they improve retrieval.
