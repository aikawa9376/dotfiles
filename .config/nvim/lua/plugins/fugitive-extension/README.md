# Fugitive extension

## Commit details

`features.commit` owns the custom commit view. Status and log selections, commit
previews, `:GitCommit [revision]`, and Fugitive commit-object URIs open it by
default. File/index/blob objects continue to use Fugitive.

The view shows immutable changes against the first parent (the empty tree for a
root commit). `gp` selects another parent of a merge. File rows, addition/deletion
counts, and syntax/word-diff highlighting share the status presentation. Files
start collapsed; patches are loaded only when expanded. The header retains
Fugitive's tree, parent, author, committer, and optional encoding fields, plus the
commit hash, using the native Git syntax colors. Header metadata comes from
`commit_info.header()`, the same formatter used by C floats and pinned blame
information, including HEAD relationship, relative dates and refs. The model
caches this header until it is reloaded; editable message text stays separate.
Help is available through g?.

Clean commit buffers use Fugitive's `bufhidden=delete` lifecycle: they disappear
from bufferline when no window displays them. Merely focusing another window does
not delete a still-visible commit. Unwritten message edits are kept when hidden.
Deleted commit URIs reload on reentry, restoring the selected parent, file
expansion, cursor, and scroll position. Only view metadata survives unloading;
explicitly wiping the buffer discards it. Blob files use custom read-only buffers and normal window defaults, including
line numbers. Enter on a removed (`-`) line opens the selected parent blob at
the old line; added and context lines open the displayed commit at the new line.
Deleted file headers also open the parent, using the old path for renames.
When Gitsigns is available, an explicit repository context compares
the blob with the selected parent (using the old path for renames). New files
receive addition signs; binary files skip this integration. Panel display options stay
local to the panel. Bufferline displays the short commit hash,
and the URI ends with the full hash. Flog ownership follows commit navigation;
closing the commit view with q also closes Flog.

| Keys | Action |
| --- | --- |
| `o`, `=` / `>`, `<` | Toggle / expand / collapse file or section |
| `]m`, `[m` / `J`, `K` | Move between files / hunks |
| `]]`, `[[` | Move between files and expand |
| `<CR>` / `gf` | Open immutable file version / current worktree file |
| `d`, `dv`, `dd` / `dh`, `ds` | Vertical / horizontal immutable diff |
| `D` | Open Diffview for the commit |
| `A`, `cw` | Move to the editable message |
| `:w` | Reword the displayed commit |
| `gA` | Original message-edit float |
| `X` (normal/visual) | Remove file, hunk, or selected lines; choose Hard or Mixed |
| `~` / `p` / `gp` | Parent / previous commit affecting the file / merge parent |
| `C` / `<C-Space>` / `O` | Commit information / Flog / pull request |
| `gq` / `<C-y>` | File quickfix / copy short hash |
| `<Leader>wd` | Cycle word-diff style |
| `R` / `q` / `g?` | Collapse and reload / close / help |
| `gL` | Open this commit in the legacy view |

Inside the message, ordinary text-editing keys such as `i`, `o`, `d`, `cw`, `A`,
`p`, and `J` retain their native meaning. Expanding diffs preserves a draft,
including added message lines. Metadata and diffs are not writable: saving a
buffer with edits outside the message fails without changing Git. `q` offers to
save, discard, or keep an unsaved message. Other buffers/windows retain Neovim's
normal modified-buffer protection; hidden drafts remain available in the buffer
list.

Saving rewrites the displayed commit, not necessarily HEAD. Historical edits
also rewrite descendants and preserve merge topology. The view then follows the
rewritten target. The operation rejects an unrelated commit, changed HEAD, or an
active Git operation. Staged, unstaged, and untracked changes are stashed and
restored with their index state. A failed rebase is aborted; failed restoration
keeps the stash and reports recovery information. An empty commit can be kept or
explicitly dropped after discarding its changes. Dropping merges or the sole root
commit is not supported by this action.

LazyAgent Notes retain immutable file/line identity and follow a file header when
its diff is collapsed, returning to their selection on expansion. Their source
identity is preserved by the existing Notes session persistence.

## Legacy view

The original implementation is retained in `features.commit_legacy`.
`:GitCommitLegacy [revision]`, `:GitCommit! [revision]`, or `gL` opens it explicitly.
To keep it as the default, set:

```lua
vim.g.fugitive_extension_commit_view = 'legacy'
```

`features.commit.open_edit_commit()` and the original message-float callbacks
remain compatible with status and other consumers. The original global
`fugitive_foldtext()` remains available for legacy folds.

## Implementation and checks

- `commit.lua`: view, editable-message validation, navigation, actions, routing.
- `commit_model.lua`: immutable metadata, file inventory, statistics, lazy patches.
- `commit_rewrite.lua`: guarded history changes and worktree restoration.
- `commit_notes.lua`: optional Notes identity and row mapping.
- `change_display.lua`: file rows and statistics shared with status.

Run checks from this directory with
`nvim --headless --clean -u NONE -l tests/<name>.lua`.
The commit checks are `commit_view`, `commit_rewrite`, `commit_discard`,
`commit_notes`, `commit_lifecycle`, `commit_entrypoints`, and `commit_blob_return`
(the last two use installed vim-fugitive; `commit_blob_return` also uses Gitsigns).

## Reflog recovery markers

`Greflog` colors a `HEAD@{n}` selector green when it identifies the state before
an amend, a reset that changed HEAD, or the start of an entire rebase. Rebase
internal amend/reset records do not create additional markers. Ordinary commits,
checkouts, and no-op resets are not marked. The marker identifies a history
recovery candidate; it does not execute a reset or restore worktree contents.

Detection follows Git's reflog operation labels in chronological order. If a
rebase start is outside the 1000-entry window, no pre-rebase destination is
invented. Only the exact destination selector is green; duplicate-hash navigation
and highlighting remain independent. `FugitiveReflogCheckpoint` defaults to
`GitSignsAdd`. See `tests/reflog_checkpoints.lua` for real Git and truncated/
ongoing/aborted rebase cases.

## Blame

`<Leader>gb` and `:GitBlame` open an independent, Git-backed blame panel beside
its code window. Panel names use the stable repository/revision/path identity
`git-blame://<root>//<revision-or-worktree>/<path>` rather than a session counter.
Initial blame loads into a hidden buffer before the split is opened at its final
content width; moving away cancels that pending opening. View restoration runs
with binding disabled, and cursor synchronization has a single owner rather than
combining cursorbind with CursorMoved updates. The annotation panel has no winbar; the code winbar shows its path, revision and
commit subject (HEAD subject for the working tree). They load fugitive-extension directly; Fugitive is not needed
for the new view. `features.blame` owns the view and paired history;
`blame_model` parses line-porcelain metadata and maps new lines back to old lines.
The leftmost range markers and hashes share deterministic commit colors. Hash,
date, and author appear only on the first row of each contiguous commit group;
continuations contain only the marker, without trailing spaces. The panel disables
list characters and fits its content width plus one right-padding column while
reserving room for code. The
commit under the cursor uses `#002b36` for all its rows; all other
commits use `#073642`. There is no special cursor-row color,
underline, or foreground override.
Uncommitted groups show only a right-aligned virtual `Not committed` label, with
no date or zero hash; tab settings do not affect its alignment. Dates retain the existing 13-color
heatmap, including the global absolute/relative mode and ColorScheme refresh.
The independent `GitHeatmap`/Snacks file-background toggle is unchanged.

| Keys in blame | Action |
| --- | --- |
| `-` / `s` / `u` | Reblame at the commit that introduced this line |
| `~` / `<BS>` | Reblame before the change; counts follow first parents |
| `{count}P` | Reblame at the numbered parent of a merge |
| `Ctrl-o` / `Ctrl-i` | Back/forward through paired blame and code views |
| `gk` | Toggle full commit message near the code cursor; follows the cursor |
| `Ctrl-p` / `p` | Toggle/open a following commit diff preview |
| `<CR>` / `i` / double click | Open the commit at its file/diff line in another tab; `q` or jumping back to blame with `Ctrl-o` returns to the preserved blame/code pair |
| `o` / `O` | Open the commit in a split/tab, keeping blame |
| `d` | Open an immutable before/after diff in a new tab |
| `c` | Switch absolute/relative date coloring |
| `(` / `)` | Previous/next contiguous commit block |
| `y` | Copy the full commit hash |
| `.` | Insert the commit hash on the command line |
| `A` / `C` / `D` | Fit full content/show hash/show date columns |
| `R` | Refresh working-tree blame |
| `g?` / `<F1>` | Show available actions |
| `q` / `gq` | Close blame and restore the original code buffer/view |

When viewing a historical revision, a separate top-right Commit Info float shows
the viewed revision’s hash, tree, parents, author/committer dates and message. It
uses the shared `commit_info` metadata also used by C floats: an exact HEAD~N
label on the first-parent chain, explicit merged/diverged/ahead relationships
otherwise, relative author/committer dates, and directly attached branch/tag refs.
It stays pinned as the cursor moves between attributed commits, updates on history
navigation and closes on return to the working tree or session exit. The `gk`
float removes Git’s trailing separator blank lines while preserving message
paragraphs. It is independent and anchors to the selected code row, choosing above/below
to fit the window. Both floats adjust to resizing/scrolling.

`gk`, `Ctrl-p`, and paired history keys also work in the code pane. Existing
buffer-local mappings are restored when the session ends. Initial working-tree
blame includes unsaved buffer contents and refreshes after edits/writes. Untracked
files or files without a committed version are rejected with a notification
before any buffer/window is created or source options are changed. History
frames retain both panes' cursor/scroll positions and immutable historical code;
returning to the working tree restores the real buffer, preserving edits.
Rename-aware porcelain metadata and diff line mapping keep the target aligned;
newly inserted lines map to an adjacent old line when no exact old line exists.
Root/file-creation boundaries report that no previous version exists.

A source custom blob is kept alive while the session uses it, then regains its
original hidden-buffer behavior. Closing either paired window, wiping the panel,
or replacing the code window's buffer cleans up the session, pending requests,
floats and historical buffers. Opening a commit/diff in another split/tab keeps
the original pair. Both sides of a blame diff map q to a deferred tab close and
return to the blame panel, without quitting Neovim. Float layout updates are
coalesced after window events and run only while the blame tab is current. Historical buffers remain unlisted and are released at exit.

`:GitBlameLegacy [flags]` retains the original Fugitive view and extensions in
`features.blame_legacy`; raw `:Git blame` remains available. Specialized Fugitive
modes (such as reverse/range blame and its generic Git-operation mappings) remain
in that legacy entry point. The new panel's commit opening always uses the custom
commit view, including boundary commits; `p` opens the following diff float.

Validation: `tests/blame_layout.lua` checks deep-file cursor/scroll stability and
no loading split; `tests/blame_model.lua`, `tests/blame_view.lua`, and
`tests/blame_history.lua` cover quoted/Unicode paths, renames, insertion/deletion
line mapping, merge parents, root boundaries, real Ctrl-o/Ctrl-i mappings,
following floats, date modes, live edits, source blobs, commit/diff entry points,
legacy extensions, heatmaps, cleanup and pending-result rejection.
