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

## 5. Capture an Agent Result

Use when a request contains the `#obsidian` transform or asks to preserve an
answer, investigation, implementation outcome, or decision for later reuse.

Workflow:

1. Complete the requested work before writing the note so the capture reflects
   the final result.
2. Search `notes/` for the same concept and update an existing note when
   possible.
3. Unless the user requested exact text, turn the result into a concise,
   self-contained permanent note rather than copying the conversation.
4. Keep the durable parts: conclusion, rationale, decisions, references, and
   follow-ups. Leave out tool logs and conversational scaffolding.
5. Add links to related notes that already exist.
6. Add a link to the permanent note from today's `daily/YYYY-MM-DD.md`.
7. For repository work, set `source: lazyagent`, `project`, and `branch` on the
   permanent note. Do not encode repository or branch names as tags.
8. Open or create `notes/projects/<repo>/<branch>.md` and add the permanent
   note once under `## AI notes`. Follow the branch-note shape in
   `conventions.md`; do not wait for the branch note to exist already.
9. Tell the user which files were created or updated.

This creates three retrieval paths without requiring a large tag taxonomy:
concept links, a chronological daily link, and a project or branch link.

## 6. Choose the Output Form

- Use a normal `.md` note for one durable concept or reference.
- For `#obsidian`, create or update Markdown only, even when the result could be
  presented visually.
- For `#obsidian-html`, create a concise Markdown summary plus a companion HTML
  artifact. Follow `html-artifacts.md`.
- Treat an explicit request for an HTML companion like `#obsidian-html`.
- Use a `.base` file when the request is primarily about filtering, sorting,
  grouping, or browsing many notes by properties.
- Use a `.canvas` file when spatial relationships communicate the idea better
  than prose.
- For a web URL, capture a distilled reference note first. Create a Base or
  Canvas only when the user also needs an overview.
