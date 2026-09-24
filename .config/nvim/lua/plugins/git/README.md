# Git

Standalone Neovim Git UI, loaded by `plugins.git`. It does not load vim-fugitive.
Flog is available lazily through a native Git backend. The retired
`fugitive-extension` source and its old plugin specification can be restored by
reverting the commit that removed them.

## Commands

| Command | Behavior |
| --- | --- |
| `G`, `Git`, `Git status`, `GitStatus` | Open the custom status panel |
| `Git <args>` | Run Git in the current buffer's repository; quoted arguments and `%` paths are supported |
| `Gedit`, `Gsplit`, `Gvsplit`, `Gtabedit [object]` | Open a commit, tree, or file blob; no argument opens the current file's index |
| `Gedit HEAD:%`, `Gedit :0:%` | Current file at HEAD or in the index; `:1:`, `:2:`, `:3:` select conflict stages |
| `Gwrite[!] [path]`, `Gwq[!] [path]` | Write and stage the current content, optionally to another worktree path; `:0:path` writes only the index |
| `Gread[!] [object]` | Replace buffer content from the index/object; a range inserts after its last line; unsaved replacement requires `!` |
| `Gdiff`, `Gdiffsplit`, `Gvdiffsplit`, `Ghdiffsplit [revision]` | Diff the current file against index/revision; an index buffer defaults to its working file; `!` shows available conflict sides |
| `Gclog[!]`, `Gllog[!] [args]` | File history (repository history outside a file) in quickfix/location list |
| `Glog`, `FugitiveLog [args]` | Custom log panel |
| `Gblame`, `GitBlame`, `GitHeatmap` | Custom paired blame and heatmap |
| `DiffDim [revision / latest / older / newer / clear]` | Dim lines outside a Git diff or selected blame commit |
| `Gbranch`, `Gstash`, `Greflog`, `Gworktree`, `GworktreeSync` | Existing repository panels/actions |
| `Gcd`, `Glcd [directory]` | Change directory relative to the buffer's worktree root |
| `Gmove`, `Grename <path>`, `Gremove`, `Gdelete` | Git file moves/removals and matching buffer updates |
| `GeditHeadAtFile`, `GitCommit [revision]`, `GitPush` | File's latest commit, commit detail, existing force-with-lease push action |
| `Ggraph [native / flog]` | Open either graph; omitted backend uses the selected default |
| `GgraphBackend [native / flog]` | Change the default for graph keys; no argument opens a picker |

In the status panel, `<Tab>` opens or closes the section under the cursor; an
arrow in the gutter shows its state. Untracked, unstaged, staged, and commit sections
start open. Other sections start closed when they contain at least three items.
The choice is preserved across status refreshes. Enter keeps each section's
existing action, including commit and pull-request scope changes.

Existing leader mappings are owned by `init.lua`. `<C-Space>` in repository
panels opens the selected graph. The default is `flog`, including the existing `<C-Space>` panel keys. Use
`:GgraphBackend native` for the independent graph, or `:GgraphBackend flog` to switch back.
Set `vim.g.git_graph_backend` in your config to persist the preference.
`:Ggraph flog` / `:Ggraph native` overrides it for one open. Direct `Flog`,
`Flogsplit`, and `Floggit` commands also work without loading Fugitive.
Flog uses its documented backend hooks to obtain repository context, run Git,
complete arguments, and open commits through the independent Gsplit command. `Git diff`/`Git show` output supports file/hunk
navigation (`]]`, `[[`, `i`), folds (`o`), and Enter to inspect the file/commit.

Completion follows each command's argument type: object commands suggest refs,
then paths inside `revision:` / `:0:`; `Git` suggests subcommands only in its first
argument and uses options, refs, remotes or paths afterwards. Worktree path and
directory completions use the buffer repository, and spaces are escaped.
`Gedit feature/hoge:%` resolves `%` to the current file's repository-relative path.
If the file did not exist at that revision, it reports the object, repository and
Git's missing-path reason while preserving the current window/buffer.
`Gedit ~1` and `Gedit ^` open the current file at the relative commit; from a
commit view they open the relative commit itself. A normal worktree file uses HEAD
as the base, while a historical blob uses its pinned revision. Numeric forms
(`~2`, `^2`), explicit paths (`~1:other.txt`), and Fugitive's `>~1` spelling also
work. The same relative objects are accepted by Gsplit/Gvsplit/Gtabedit, Gread,
and Gdiff commands, with completion for common forms.

Git commands run with argv, without shell interpolation. Commands needing prompts,
network interaction or an editor use a terminal job. `git.editor` supplies Git's
editor/sequence-editor command, opens the requested file in the same Neovim, and
resumes Git after that buffer closes (`:wq`). Explicit `commit -m`, `-F`, and
`--no-edit` run synchronously so chained status actions can observe failure.

`git-object://<worktree>//<revision>/<path>` buffers preserve repository/path
metadata; index buffers use `//0/<path>` (conflict stages use 1–3). Like Fugitive,
path separators remain literal, with only percent, `#`, `?` and control characters
escaped. Tab/status/inactive-window labels show `file.lua [abcdef0]` or
`file.lua [0]`, while the URI keeps full repository/revision identity. Old fully
escaped URIs still reload from sessions, quickfix and jump lists. Revision blobs are
read-only and pin symbolic revisions to a commit. Stage 0 supports `:write` to
update only the index, rejecting writes if its blob changed since loading.
When Gitsigns is installed, a file opened from another revision or branch
compares against the current repository's HEAD file. `Gedit HEAD:<path>` shows
the changes made by HEAD against its first parent (or the empty tree for a root
commit). Index blobs compare against HEAD. This uses the committed HEAD version,
so uncommitted worktree edits are not part of the comparison. Tree objects have
no file-level signs.
`:Gwrite` additionally writes the worktree and stages it. Binary object editing
is rejected. Buffer repository context takes priority over cwd, including linked
worktrees. URI buffers can reload from quickfix and jump lists.

The supported surface is deliberately bounded: shell pipelines, Fugitive's full
object shorthand language, line-range `Gclog -L` syntax and every deprecated alias
are not reproduced. Pass ordinary Git arguments to `Git` for other operations.
Existing highlight/filetype names, `FugitiveChanged`, and Note metadata stay
compatible with the surrounding dotfiles; they do not require Fugitive code.

## Commit details

`git.features.commit` owns the custom commit view. Status and log selections, commit
previews, `:GitCommit [revision]`, and `:Gedit <revision>` open it.
`git.objects` owns independent file/index/blob buffers.

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

Clean commit buffers use a `bufhidden=delete` lifecycle: they disappear
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
and the URI ends with the full hash. Preview blob URIs use
`git-commit-blob://<worktree>//<revision>/<path>` without an open counter. They
remain separate from Gedit buffers because previews wipe on hide and can use a
selected merge parent for their signs. Graph ownership follows commit navigation;
closing the commit view with q also closes the graph.

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
| `C` / `<C-Space>` / `O` | Commit information / graph / pull request |
| `gq` / `<C-y>` | File quickfix / copy short hash |
| `<Leader>wd` | Cycle word-diff style |
| `R` / `q` / `g?` | Collapse and reload / close / help |

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
(`commit_blob_return` uses installed Gitsigns). No check loads Fugitive.
`commands` checks actual Git mutations and object lifetimes; `lazy_loading` checks
Lazy command registration and the active imports. `editor` uses a local Unix socket
to exercise Git’s real editor process and requires socket permission.

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
combining cursorbind with CursorMoved updates. The annotation panel has a centered
`Blame panel` winbar so its lines align with the code. When a long commit block's
header scrolls out of view, the winbar carries its hash, date and, if it fits,
author until the next block. The code winbar shows its path, revision and
commit subject (HEAD subject for the working tree). They load the Git plugin directly. `git.features.blame` owns the view and paired history;
`blame_model` parses line-porcelain metadata and maps new lines back to old lines.
The leftmost range markers and hashes share deterministic commit colors. Hash,
date, and author appear only on the first row of each contiguous commit group;
continuations contain only the marker, without trailing spaces. The panel disables
list characters and fits its content width plus one right-padding column while
reserving room for code. The
commit under the cursor uses `#002b36` for all its rows; all other
commits use `#073642`. `gD` in either pane pins that commit's highlight and dims other
lines in the paired code buffer until toggled, `:DiffDim clear`, or closing blame.
Bare `:DiffDim` also selects the cursor-line commit while blame is open. Pinning
automatically shows that commit's shared `C` metadata in a float. `gC` hides or
restores the float without clearing the dim; unpinning restores the viewed
revision's info when browsing history. There is no special cursor-row color,
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
| `gD` | Pin/unpin the cursor-line commit and dim other code lines |
| `gC` | Hide/show the pinned commit info while dimming |
| `c` | Switch absolute/relative date coloring |
| `[[` / `]]` | Previous/next contiguous commit block in either pane; count supported |
| `(` / `)` | Previous/next contiguous commit block |
| `y` | Copy the full commit hash |
| `.` | Insert the commit hash on the command line |
| `A` / `C` / `D` | Fit full content/show hash/show date columns |
| `R` | Refresh working-tree blame |
| `g?` / `<F1>` | Show available actions |
| `q` / `gq` | Close blame and restore the original code buffer/view |

When viewing a historical revision, a separate top-right Commit Info float shows
the viewed revision’s hash, tree, parents, author/committer dates and message;
while dimming, it shows the pinned commit instead. It
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

`:Git blame` opens the paired view. With additional flags it runs the Git CLI
and displays its output. Reverse/range blame's original interactive extensions
are outside this plugin's supported commands.

Validation: `tests/blame_layout.lua` checks deep-file cursor/scroll stability and
no loading split; `tests/blame_model.lua`, `tests/blame_view.lua`, and
`tests/blame_history.lua` cover quoted/Unicode paths, renames, insertion/deletion
line mapping, merge parents, root boundaries, real Ctrl-o/Ctrl-i mappings,
following floats, date modes, live edits, source blobs, commit/diff entry points,
heatmaps, cleanup and pending-result rejection.
