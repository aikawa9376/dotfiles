# obsidian.nvim Commands in This Setup

These commands are already enabled in the local Neovim configuration.
Prefer them over the external Obsidian CLI in this setup.

## Navigation and Search

- `:Obsidian` / `:ObsidianMenu` — open a described picker of commonly useful Obsidian actions
- `:ObsidianSidebar` — toggle a right sidebar with note metadata, headings, outgoing links, and backlinks; use `<CR>` to open, `R` to refresh, and `q` to close
- `:ObsidianQuickSwitch` — fuzzy switch to another note
- `:ObsidianSearch` — search note content
- `:ObsidianRelated [text]` — rank notes by the current Git project/branch, wiki-link graph, and optional text
- `:ObsidianOpen` — open the current note in the Obsidian app
- `:ObsidianFollowLink` — follow the link under cursor
- `gf` — follow links via the configured `gf_passthrough()`

## Creating and Updating Notes

- `:ObsidianNew` — create a new note
- `:ObsidianTemplate` — apply a template to the current note
- `:ObsidianNewFromTemplate` — create from template
- `:ObsidianRename` — rename a note and update links
- `:ObsidianExtractNote` — extract selected content into a new note

## Linking and Structure

- `:ObsidianLink` — link selected text to an existing note
- `:ObsidianLinkNew` — create and link a new note from selected text
- `:ObsidianLinks` — show links in the current note
- `:ObsidianBacklinks` — show backlinks to the current note
- `:ObsidianTOC` — insert or update a table of contents
- `:ObsidianTags` — inspect tags

## Daily Notes

- `:ObsidianToday`
- `:ObsidianYesterday`
- `:ObsidianTomorrow`
- `:ObsidianDailies`

## Misc

- `:ObsidianPasteImg` — paste an image into `assets/imgs`
- `:ObsidianToggleCheckbox` — toggle markdown checkboxes
- `:ObsidianWorkspace` — switch workspace
- `:ObsidianGit [message]` — save modified vault buffers, `git add -A`, then commit and push with a default message like `2026-05-23 22:17:53**obsidian`
- `:ObsidianBranchNote` — if the current buffer or cwd is inside a git repo, open or create `notes/projects/<repo>/<branch>.md`
- `:ObsidianRepoNote` — if the current buffer or cwd is inside a git repo, open or create `notes/projects/<repo>/index.md`
- `:ObsidianKnowledgeBase` — open or create `bases/knowledge.base` with Seeds, Evergreen, and References views
- `:ObsidianNoteStatus seed|evergreen|archived` — update the current note's knowledge-gardening status
- `:ObsidianOpenArtifact` — open the file or HTTPS URL in the current note's `artifact` property

When the user is already inside Neovim and asks for an interactive note workflow, prefer these commands over manual file editing where possible.
