# Git

Panels open to the right when the selected window is at least the configured
minimum width; otherwise they open below. Regular panels default to 200 columns.
Status uses its own 240-column minimum, so a narrower source window opens status
below.

```lua
vim.g.git_panel_min_width = 200
vim.g.git_status_min_columns = 240
```

This applies to status, log (`L`), branch (`B`), stash, worktree, reflog, WIP,
Git command output, and commit preview panels. Existing visible panels are reused
where supported. Tab opens, explicit object/diff split commands, the paired blame
view, and `magit-hint`/transient menus retain their own layouts.


Standalone Neovim Git UI, loaded by `plugins.git`. It does not load vim-fugitive.
Flog is available lazily through a native Git backend. The retired
`fugitive-extension` source and its old plugin specification can be restored by
reverting the commit that removed them.

## Panel keys

Normal panel keys use the selected row, file, hunk, or Visual selection as their
context. Magit's `<Space><Space>` panels retain their existing keys and layout.

| Keys | Intent and context |
| --- | --- |
| `<CR>` / `q` / `?` / `R` | Open / close / contextual key guide / refresh; Stash and WIP also support help and refresh |
| `d` / `D` | Compare selected item / whole-commit Diffview where supported |
| `C` | Commit/ref information; Blame also uses this for metadata |
| `gy` | Copy identifier: commit hash, ref, reflog/stash selector, file/worktree path, or PR URL; Visual log selections copy hashes |
| `cw` | Reword commit, rename stash, or rename selected local branch |
| `A` (Status) | Amend HEAD with the current stage; no staged difference does nothing, on any row |
| `a` | Apply selected patch/stash or restore selected WIP snapshot; Status patch apply requires a commit or staged change |
| `X` | Contextual discard/remove; Reflog offers Mixed / Hard / Cancel before resetting to the selected entry |
| `L` / `B` | Existing Log / Branch entries; Branch also has `B` to open its list |
| `gH` / `gD` / `gO` | History editing / display settings / repository actions, on panels with those actions |

`gH`, `gD`, and `gO` are ordinary action choosers, separate from Magit. They retain
exact operations such as parent fixup, commit reordering, clipboard cherry-pick,
current-branch force-with-lease push, and composite pull actions. Status `?` opens
a compact, colored action menu for the current file, hunk, commit, stash, section,
or active operation, plus panel/view entries. It omits unrelated operations and
uses the migrated keys. Other shared guides combine aliases for the same action.
The Git action menu has a separate highlighted heading and visible
`<Space><Space>` shortcut; literal space keys never appear as blank columns.
Key columns use display width so long key names stay aligned; titles, groups and
keys retain semantic colors. Unsupported targets report a notice rather than
selecting an unrelated commit. Normal editing keys keep their meaning inside the
Commit message and Blame code pane.

Branch actions use `coo` checkout, `cod` duplicate, `cos` spin-off, `coS` spin-out,
`cou` set upstream, and `coU` unset upstream. Rename uses `cw`; removal uses `X`.
Worktree actions use `cZa` add, `cZt` create from a Branch row, and `cZs` sync
(current worktree in Status, selected worktree in the Worktree list). Conflicts
use `mo` ours, `mt` theirs, and `mr` stage the current worktree content. These maps
are installed throughout Status's lifetime and guard the selected Unmerged item
when executed.

Stash `a` applies without restoring the index. `cza` / `czp` apply / pop with
index restoration, and `czA` / `czP` apply / pop without it. In Status these keys
use an explicit count first, then the stash row, otherwise a stash picker. A
changed stash selector during the picker is rejected. `cw` renames the selected
stash. WIP `a` retains its clean tracked-worktree requirement and restores the
snapshot's staged/unstaged split without moving HEAD.

Status and Commit `R` collapse all expanded diffs and reload. Status retains
section fold state and the selected entry, including in Index flags. Automatic
refreshes retain expansion and fold state; `<` collapses only its selected scope.
`d` waits for its `dd` / `dv` / `dh` / `ds` suffixes. Status also uses `dR` for
outgoing-stack range-diff. The Commit message float saves through `:w`,
`<C-s>`, or `ZZ`.

Unchanged commit messages do not start stash/commit/rebase, including `cw`,
the Commit message float and reword-with-index when the index is unchanged.
Terminal message separator blank lines are ignored for this comparison.
Plain `commit --amend --no-edit` (`A` / `ce`) also returns before committing
when the index matches HEAD. Explicit author/date/signing and `--allow-empty`
arguments retain Git's normal behavior. Status `?` lists `A` when staged changes
can be amended. Stash operations retain their `cz` keys and the shared lowercase
`a` apply action; uppercase `A` always refers to HEAD's staged amend.

The old `bs` / `bS`, Reflog `B` / `y`, and Worktree `gs` remain compatibility
aliases because the unchanged Magit layer calls them internally. They are omitted
from the normal key guide; this also means `b` remains a mapping prefix on panels
with those spin aliases. Global leader mappings in `init.lua` remain separate.

## Harpoon pins

The existing Harpoon `multiple` list accepts ordinary file positions and Git
views together. Press `ma` to pin/unpin the target under the cursor, and `mm` to
select a pin. The existing `mx` fuzzy picker also opens, previews and removes
these pins; its quickfix action remains for ordinary files. Harpoon keeps its
existing cwd-based list storage, and saved Git entries carry their own worktree
root, so selecting from another repository uses the saved repository. Lists are
shared across branches within the same cwd; switching branches does not create
a separate list. Hook icons mark ordinary file pins only, including in the
quick menu; Git pins still participate in its nearest-target cursor selection.

| View | Saved target and reopening behavior |
| --- | --- |
| Status | Refresh the repository, then locate the file/section/commit/stash; expanded file diffs retain their selected context |
| Branch / Worktree | Refresh the list and locate the selected ref/worktree; branch filters are preserved |
| Log | Restore arguments or line-history scope and locate the selected commit; line history retains its starting revision |
| Reflog / Stash / WIP | Locate the saved commit/snapshot; stash selectors are resolved again after numbering changes |
| Commit | Pin the full hash, comparison parent, expanded files and selected file/diff position |
| Git object / commit preview file | Reopen the immutable revision/path or live index stage and line; preview comparison bases are retained |
| Blame | Restore the currently viewed revision/path/line as a code/annotation pair; an existing matching pair is reused |
| Native / Flog graph | Restore the backend, scope and selected commit; Flog options are preserved |
| Git command output | Reopen the saved output text; the command is not run again |

Git pins use serializable target metadata rather than buffer/window IDs or URI
counters. File pins keep their existing path/line behavior. List pins identify
items semantically instead of trusting their old row numbers; a missing item
does not trigger an action on another item. Missing repositories or immutable
objects are reported without substituting the current repository or HEAD.
Transient menus, terminals and temporary conflict/blame diff panes are not
persistent pin targets.

The quick menu remains editable for ordering/deleting pins and adding ordinary
file rows. Git labels are display text: remove and pin again to change a Git
target. New panel pins preview a copy of the rendered buffer at pin time,
including expanded diffs, colors and the saved cursor position. This display
survives closing the source panel; selecting the pin still refreshes live lists
and restores their semantic target. Previews have their own scratch buffers and
do not attach panel actions. Existing pins without display data, and commit
message drafts, retain the read-only Git-data fallback; re-pin to capture a
rendered preview. Object/index and paired-blame code previews read file/Git data.
Previewing does not open panels or run Git mutations.
`plugins.harpoon_git` owns capture/reopen/preview, while
`plugins.harpoon_items` supplies shared structured item access for the menu,
icons, previews and fuzzy picker. `tests/harpoon_git.lua` uses installed Harpoon,
Flog and fzf-lua with isolated Harpoon storage and temporary Git repositories.

## Commands

| Command | Behavior |
| --- | --- |
| `G`, `Git`, `Git status`, `GitStatus` | Open the custom status panel in a split |
| `G!`, `G! status`, `<Leader>gS` | Open the custom status panel in a tab; reuse its existing status tab |
| `Git <args>` | Run Git in the current buffer's repository; quoted arguments and `%` paths are supported |
| `Gedit`, `Gsplit`, `Gvsplit`, `Gtabedit [object]` | Open a commit, tree, or file blob; no argument opens the current file's index |
| `Gedit HEAD:%`, `Gedit :0:%` | Current file at HEAD or in the index; `:1:`, `:2:`, `:3:` select conflict stages |
| `Gwrite[!] [path]`, `Gwq[!] [path]` | Write and stage the current content, optionally to another worktree path; `:0:path` writes only the index |
| `Gread[!] [object]` | Replace buffer content from the index/object; a range inserts after its last line; unsaved replacement requires `!` |
| `Gdiff`, `Gdiffsplit`, `Gvdiffsplit`, `Ghdiffsplit [revision]` | Diff the current file against index/revision; an index buffer defaults to its working file; `!` shows available conflict sides |
| `Gclog[!]`, `Gllog[!] [args]` | File history (repository history outside a file) in quickfix/location list |
| `Glog`, `FugitiveLog [args]` | Custom log panel; a line range follows the selected file lines with `git log -L` |
| `Gblame`, `GitBlame`, `GitHeatmap` | Custom paired blame and heatmap |
| `DiffDim [revision / latest / older / newer / clear]` | Dim lines outside a Git diff or selected blame commit |
| `Gbranch`, `Gstash`, `Greflog`, `Gworktree`, `GworktreeSync` | Existing repository panels/actions |
| `Gcd`, `Glcd [directory]` | Change directory relative to the buffer's worktree root |
| `Gmove`, `Grename <path>`, `Gremove`, `Gdelete` | Git file moves/removals and matching buffer updates |
| `GeditHeadAtFile`, `GitCommit [revision]`, `GitPush` | File's latest commit, commit detail, existing force-with-lease push action |
| `Ggraph [native / flog]` | Open either graph; omitted backend uses the selected default |
| `GgraphBackend [native / flog]` | Change the default for graph keys; no argument opens a picker |
| `GbranchSpinoff [commit]`, `GbranchSpinout [commit]` | Move outgoing commits, optionally starting at a selected commit, to a new tracking branch |
| `GitWipEnable`, `GitWipDisable`, `GitWipSave`, `GitWipLog`, `GitWipRestore [number]` | Save, inspect, and restore tracked work-in-progress snapshots |

Successful `:Git` mutations refresh repository panels without opening a result
window. Read-only commands such as `:Git log` still open their output. From a
Git panel, commands that normally use a terminal run in the background, while
the commit/rebase editor still opens when needed. Elsewhere, their terminal
closes after completion. Failures are reported by notification, including the
last Git output lines. Use `:Git!` to keep a terminal open explicitly, or to
show output from a synchronous mutation as a notification. Interactive patch
mode still opens a terminal for its prompts.

In a file buffer, select lines and press `g<Space>l` to open their history in
the custom log panel. `:10,20Glog` and `:10,20FugitiveLog` do the same; without
a range, `g<Space>l` and `Glog` keep their repository-wide log behavior. The
range starts from the displayed revision in a Git object buffer, or `HEAD` in a
worktree file. In a line-range log, `<C-p>` and `<CR>` open the selected commit
with the corresponding file expanded and the cursor on its relevant diff line.
In log or reflog, select commit rows and press `d` to compare the selected
history in Diffview, including the oldest selected commit. The same Visual `d`
works on status commit rows. Selections whose commits are not on one ancestry
chain are rejected.
In status, normal `d` on a commit row opens that commit in Diffview. On a
stash row it compares the stash with its base commit; Visual `d` across stash
rows compares the oldest selected stash snapshot with the newest. Enter keeps
its existing commit and stash inspection actions.

In the status panel, `<Tab>` opens or closes the section under the cursor; an
arrow in the gutter shows its state. Unmerged, untracked, unstaged, staged, and
commit sections start open. Other sections start closed at three or more items.
The `Head` header also starts open; fold it to show only the `Head` row.
The choice is preserved across status refreshes. Enter keeps each section's
existing action, including commit and pull-request scope changes.
`gm` jumps to Unmerged paths. `gp` jumps to whichever commit section is shown:
`Unpushed [only]` or `Commits [latest 15+]`.
Opening Status starts a background `git fetch` for the configured default remote;
it never integrates fetched commits into the current branch. It runs at most once
per repository per 180 seconds by default. Set `vim.g.git_status_auto_fetch = false`
to disable it, or `vim.g.git_status_auto_fetch_interval` to change the interval
in seconds.
The header shows `Head`, the configured `Upstream` (the usual Pull source), a
separate `Remote` row for a distinct Push destination branch when applicable,
and the nearest current/next tags with their commit distances. `Tag` is omitted
in repositories without tags.

In status, `gx` opens a PR row, a pushed commit row, or a pushed `Head` /
`Upstream` / `Remote` branch on GitHub. It also works on branch-list branches, log
commits, and commit detail views. Branch and commit links require a matching
local remote-tracking ref with a GitHub remote; unpushed items show a notice.
`gi` manages index flags from the status panel.

Expand a staged or unstaged file with `o`. On a displayed hunk, `s`/`-`
stages or unstages that hunk; `u` unstages a staged hunk. Select added or
removed lines within one hunk in Visual mode and press the same key to update
only those lines. File headers and section headings retain file/section-wide
actions. The displayed staged diff is index versus `HEAD`; the unstaged diff is
worktree versus index. `I` keeps the interactive Git patch command available.
Visual `X` discards selected changed lines within one displayed hunk, or the
selected file rows. Staged selections are removed from both the index and
worktree; unstaged selections affect only the worktree. If the worktree has
overlapping edits that prevent a staged patch from applying cleanly, `X` leaves
the selection unchanged and reports the conflict.
Visual `d` on file rows in one status section opens Diffview limited to those
paths; staged rows compare `HEAD` with the index, and other rows use the
worktree view. Visual `<Space><Space>` offers actions for selected commits,
stashes, or files, including range diff, cherry-pick/revert, and file
stage/unstage/discard.
Expand an unmerged path with `o`. For `UU` and `AA` files with conflict
markers, the diff compares the live ours/theirs text only inside each marked
region; clean auto-merged edits stay out of the diff. Other conflicts compare
Git's stage 2 (ours) to stage 3 (theirs): `UD` shows removed lines and `DU`
shows added lines.
Each conflict marker block appears as one hunk, including unchanged lines
between edits inside that block.
Pressing `<CR>` on a conflict diff line opens the worktree file at that
line's actual ours/theirs marker position; unchanged context uses the ours
position.
After `mo` or `mt` chooses a present side, the still-unmerged path instead
shows the adopted worktree content against stage 1 (base), including edits made
after choosing that side. An `AA` conflict has an empty base, so the adopted
file appears as added lines. A manually resolved worktree with no conflict
markers also shows its current content against stage 1 (base). In these
base-to-worktree previews, lines corresponding to overlapping, differing edits
from the original conflict have a muted yellow background. Clean changes keep
their usual diff colors.
`s` accepts theirs by default; `X` keeps ours. With conflict markers, both
keys replace only the marked regions with the chosen side and preserve edits
outside them. After `mo` or `mt`, `s` stages the chosen worktree content instead.
After a manual resolution removes all conflict markers, `s` stages the current
worktree content as well.
On an expanded conflict hunk, these keys and `mo`/`mt` choose only that marker
block; on the file row they choose every block. The file remains unmerged until
the last block is accepted and staged. Visual selections inside a conflict diff are rejected. `mr`
stages the current worktree content regardless of markers. `mo` and
`mt` choose either side without staging it; choosing a deleted side
necessarily removes the path and resolves it. `d` opens base, ours, and theirs
for a conflicted file; for other files it keeps the usual two-way diff.
`mo` and `mt` load the real file buffer before checkout and record the change
in its undo history. Open that file and press `u` to restore its previous
contents, then write it to restore the contents on disk. The status buffer's
`u` remains the unstage action; file-buffer undo does not change the Git index.
The Unmerged paths section starts open even with three or more files. Individual
file diffs start closed and can be expanded with `o`.
An active operation uses one `<operation>: <commit> <subject>` heading.
During rebase, Git's stage 2 is the branch being rebased onto and stage 3 is
the replayed commit, so the diff direction and `s`/`X` meanings stay the same.

In `Gbranch`, `cos` spins off the current branch and checks out the new branch;
`coS` spins out and stays on the current branch when the worktree is clean. If
there are uncommitted changes, spin-out checks out the new branch so those
changes follow it. Both actions make the new branch track the original branch.
The branch panel shows local branches, remote branches, and tags. Use `ga`,
`gl`, `gr`, or `gt` to show all refs, local branches, remote branches, or tags;
the active view is labeled at the upper right. `<CR>` and `L` inspect a selected
tag as well as a branch. Branch-changing actions do not apply to tag rows.
On a local branch row, `cou` sets its upstream with completion for local and
remote branches; `coU` removes its upstream. These keys also work on a local
branch other than the currently checked-out one.
When the original branch has outgoing commits, it is moved back to the merge
base with its upstream; without an upstream or outgoing commits it stays put.
The branch name and any reset are confirmed before changing refs.
The same `cos` / `coS` keys work in status and log. On a commit row they move
that commit and everything after it; elsewhere they use the upstream merge
base. `:GbranchSpinoff <commit>` and `:GbranchSpinout <commit>` expose that
boundary directly. The commit must be on the current branch's first-parent
history and outside its upstream.

WIP snapshots are off by default. `:GitWipEnable` enables automatic saving
after file writes and Git actions for the current Neovim session; setting
`vim.g.git_wip_enabled = true` in config enables it on startup. `:GitWipSave`
saves explicitly, and `:GitWipLog` lists the current branch's snapshots (`a`
restores one). `:GitWipRestore [number]` restores the newest snapshot by
default, or an older reflog entry by number, to a clean tracked worktree.
Snapshots retain the staged/unstaged split and leave the live worktree alone.
They cover tracked changes only; untracked files need a regular stash or
commit. Repeated saves of unchanged content do not add history entries.

Existing leader mappings are owned by `init.lua`. `<C-Space>` in repository
panels opens the selected graph. The default is `flog`, including the existing `<C-Space>` panel keys. Use
`:GgraphBackend native` for the independent graph, or `:GgraphBackend flog` to switch back.
Set `vim.g.git_graph_backend` in your config to persist the preference.
`:Ggraph flog` / `:Ggraph native` overrides it for one open. Direct `Flog`,
`Flogsplit`, and `Floggit` commands also work without loading Fugitive.
Flog uses its documented backend hooks to obtain repository context, run Git,
complete arguments, and open commits through the independent Gsplit command. `Git diff`/`Git show` output supports file/hunk
navigation (`]]`, `[[`, `i`), folds (`o`), and Enter to inspect the file/commit.

`<Space><Space>` opens a separate Git action menu in status, log, branch,
reflog, worktree, commit-detail, and changed-files tree panels. It uses the file, commit, ref, reflog destination,
or worktree under the cursor, with no repeated
title/context header. The root offers Magit-style prefixes for cherry-pick
(`A`), apply variants (`v`), bisect (`B`), clone (`C`), commit (`c`), diff (`d`), pull (`F`), fetch
(`f`), log (`l`), remote (`M`), merge (`m`), submodule (`o`), push (`P`), rebase
(`r`), tag (`t`), revert (`V`), reset (`X`), references (`y`), stash (`z`),
and worktree (`Z`), plus sparse checkout (`>`), Subtree (`O`), Bundle (`U`),
plain patches (`W`), mail patches (`w`), Notes (`T`), custom commands (`!`),
and changed-files tree (`=t`, Status/tree only). Ignore (`i`) and commit copy (`Y`) appear when applicable.
History (`H`) is available throughout these panels and offers operation Undo/Redo,
fixup-target detection, and patch collection. A selected commit also exposes
`<Tab>` to open patch collection directly from the menu.
Each operation panel shows its arguments and
execution keys. Toggle an argument with its displayed key, then press an
execution key; `q` or `<Esc>` closes the menu. An active cherry-pick, revert,
merge, rebase, or bisect shows its sequence actions. The root arranges actions
in two columns when the editor is wide enough. The default layout is a bottom
split. Set `vim.g.git_action_menu_layout = 'float'` for a lower-right float.
Operation panels place whole argument/action groups side by side when they fit
and wrap them on narrower screens. Set
`vim.g.git_action_menu_group_layout = 'vertical'` to restore the previous
one-group-per-row layout; unset it or use `'horizontal'` for the new layout.
The existing panel keys and `?` help remain separate.

Push and Pull keep their existing current-HEAD actions. Their `s` action uses
the ref under the cursor: Push sends a selected branch to its push remote (or
prompts for one), and can send a selected commit to a named destination branch.
Pull fetches the selected branch's configured upstream, or a selected
remote-tracking branch, into the currently checked-out HEAD. Pull `s` is
unavailable when that source cannot be resolved.

The other operation panels also expose Magit's Git flags, including value
options for commit identity/signing, diff context and algorithms, merge/rebase
strategy, push options, clone setup, and tag signing. Toggle switches or enter
values before choosing an action. Active Git arguments are highlighted inside
parentheses; a specified value also shows a checkmark. Options apply to the
relevant Git action in that panel (for example, submodule update flags apply to
update, and the stash push arguments apply to `P`).

The log (`l`) panel groups Magit-style commit limits, history simplification,
ordering, and formatting flags. Value flags such as `-n`, `-A`, `-G`, `-S`,
`-L`, `-o`, and the file limit `--` prompt for a value; an empty answer clears
it. Active options show a checkmark and highlight their Git argument. `-f`
(`--follow`) requires a single file limit, and `-L` line evolution cannot be
combined with that file limit. The default `-n` limit is 256 commits.

In status, a selected commit, staged file, or expanded staged hunk offers
`a` in its context group; `<Space><Space>a` applies that patch directly to the
worktree. `<Space><Space>v` opens the **Apply variants** menu in supported
panels, and is the route to patch actions outside status. It offers `a` apply,
`v` reverse, `k` discard a status change, `C` cherry-pick and commit, and `V`
revert and commit when applicable.
Its `-3` flag uses a three-way fallback for apply/reverse and stages the result.
`:GitApply[!] [revision]` and `:GitReverse[!] [revision]` expose the same patch
operations as commands; `!` enables three-way fallback, which also stages the
result. In a commit view, they
use the commit, file, or expanded hunk at the cursor, and `a`/`cv` call the
commands outside the editable message. The stash list's `<CR>` opens its commit
view, where a changed file can use these patch actions. In the cherry-pick panel, `A a` applies a
commit without committing, while `A h` harvests a selected commit from another
local branch and `A d` donates one from the current branch to another local
branch. Harvest/donate require a clean worktree and a non-merge commit; when
Git stops on a conflict, resolve or abort its sequence before retrying.

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

Status and Commit default to the `treesitter` word-diff style. In `gD` (Display
settings), choose “Cycle word-diff style” to cycle through `diffs`, `delta`,
`treesitter`, and `github`. These styles compute changes inside Neovim; no `delta`
or `difft` executable is required. The former `lazygit` setting is now named
`delta`, matching the renderer configured in this repository's LazyGit settings.
The `delta` comparator follows delta 0.19.2's default word alignment: Unicode words,
grapheme-separated punctuation, forward line matching at a distance threshold of
0.6, and the same edit-group and whitespace rules. Tabs expand to eight spaces for
comparison while highlights retain original byte positions. Delta's default
32-line buffer limit also affects pairing in long replacement groups. Unpaired
rows keep ordinary line backgrounds, including addition-only/deletion-only groups.
Repeated comparisons reuse a bounded cache. This reproduces default word emphasis;
custom delta options, whitespace-error decoration and long-line truncation are
not applied. Code colors and muted line/word backgrounds remain those of this UI.

With a Tree-sitter parser, `treesitter` style converts syntax into atoms and
lists with paired opening/closing delimiters, then finds a lowest-cost matching
path using Difftastic 0.71.0's cost rules. Unchanged identifiers and delimiters
survive line splitting/joining; added arguments, statements and one-sided files
receive backgrounds on their syntax spans. Syntax foreground colors remain
those of the current theme. Formatting whitespace outside syntax is uncolored.
Changed strings/comments use a muted background for the changed atom and a
stronger background for changed words inside it when enough common words remain,
following the reference's two levels of coloring. Unrelated comment replacements
remain wholly muted. Adjacent spans bridge whitespace without crossing unchanged
code or extending to the end of the screen row.
Structural backgrounds use `#1f4534` for added spans and `#4a2a2e` for deleted
spans; changed words inside matched literals/comments use `#1f6648` and
`#ad5258`, respectively. These `FugitiveExtSyntax*` groups belong only to
`treesitter`; the other styles retain their existing palette.

Only `treesitter` uses a green/red left-aligned `▏` overlay in place of `+`/`-`, linked to
`GitSignsAdd`/`GitSignsDelete`. Other styles retain their space overlay.
Underlying patch bytes are preserved for navigation, staging and selections.
There is no whole-line addition/deletion background in this style: unchanged
code keeps the normal background, including the retained side of a deletion.
Source text has the Normal foreground below syntax captures, so incomplete
hunks with no capture for a leading key/keyword cannot inherit red/green diff
foregrounds. Theme changes update that foreground without changing backgrounds.
Status and Commit coloring asynchronously reads complete old/new files instead
of guessing missing braces or function bodies. Status records immutable HEAD
and index blob IDs from porcelain v2 and reads the worktree for unstaged changes;
Commit reads the selected parent and commit, honoring renamed paths. Queries
cover only displayed source intervals, projected through the hunk's original
old/new line numbers. Identical hunk text at different source coordinates has
independent captures: the same text can be code in one place and a string in
another. Every projected row must match the displayed patch, so stale files or
filter-transformed content cannot supply unrelated colors or comparison trees.
Comparison reuses both verified complete trees for every available language,
preserving enclosing functions, classes, delimiters and PHP/HTML context.
Conversion and search start at the parent containing the changed byte range
(such as a function or method), leaving unrelated syntax out. Strings/comments
remain whole atoms. Separate edits or moves expand to a shared enclosing region;
top-level changes retain neighboring nodes as correspondence anchors.
One comparison is shared across all hunks of the same old/new file pair; its
source-coordinate ranges are projected only onto displayed changed rows.
Missing source metadata, conflict views, read failures and oversized/binary
files keep available hunk captures, with Normal
for uncovered bytes.
Without a parser, the included Vim syntax has a Normal parent region; its
keywords/strings keep their own colors instead of being covered by that base.
If complete-file structural comparison fails or uses Text (including Markdown),
the complete pair receives a shared, cooperative Histogram Text comparison.
Without verified complete sources, hunk comparison retries individual change
blocks structurally. Lua declaration-only blocks receive a temporary
empty body for comparing parameters. Blocks that still cannot be compared, or
lack a parser, use the reference's local Histogram text matching; only changed
word ranges receive backgrounds, with whole-line text tints omitted.
Without verified complete PHP context, tagless fragments use this muted Text
comparison instead of mistaking PHP code for a single HTML text atom.
Markdown uses Text comparison, matching Difftastic; Tree-sitter still supplies
its syntax colors. This also preserves fenced-block prose, whose bytes are not
fully covered by Markdown block-node children.
Text matching and its word-limit fallback always use muted backgrounds. Strong
backgrounds are reserved for changed words inside structurally matched
strings/comments/text. Native underline marks those inner word changes; native
bold also styles ordinary keywords/types/delimiters and does not denote moves.
Text-mode novel words can include indentation; those bytes retain their muted
backgrounds instead of being blanket-trimmed.
Syntax styling stays with the current theme rather than becoming strong diff
backgrounds. Native text matching skips individual words when either side of
a changed section exceeds 1,000 split elements (words, spaces and punctuation);
that section then receives muted content spans here. Long structural literals
have no such word-count cutoff: common character prefixes/suffixes reduce exact
similarity work before Histogram word matching.
`github` retains ordinal line pairing; `diffs` retains character comparison. All styles use Tree-sitter
code colors when available, with Vim syntax as the fallback.

Diff foreground colors are optional and off by default:
`syntax_highlight.config.changed_fg = 'syntax'` keeps syntax colors within changes.
In `gD` (Display settings), “Toggle diff foreground colors” switches between
`syntax` and `difft` for `treesitter` style. With `difft`, detected spans use the
theme's terminal red/green palette, matching
Difftastic's ANSI bright red/green (9/10) on dark backgrounds and ordinary
red/green (1/2) on light backgrounds. Unchanged spans retain syntax colors.
Background strength and gutter colors remain independent. Switching reuses
parsed trees and comparisons. The same setting can be enabled directly:

```vim
:lua local s = require('git.features.syntax_highlight'); s.config.changed_fg = 'difft'; s.refresh_all()
```

Set `changed_fg` back to `syntax` in the same command to restore the default.

`tests/difftastic_word_diff.lua` compares both background levels against 153
checked-in cases captured from the installed Difftastic 0.71.0, covering calls,
wrapping, paired delimiters, added/removed syntax, strings/comments, Unicode,
JSON, Python, YAML, layout changes and a 100-line file with repeated edits.
Of these, 132 compare structural results and 21 compare text matching, including
parse-error fallback, repeated-word alignment, long literals/comments, inputs
over the former 128 KiB limit, and the exact 1,000-element boundary. Text cases
also check the deliberately muted rendering policy. Four reported examples are
also projected onto actual patches, checking both background levels and cache
reuse on refresh. `tests/generate_difftastic_fixtures.py`
regenerates token spans from JSON and changed-word emphasis from inline ANSI.
Tests normalize this UI's whitespace bridges and clip native EOF positions.
`tests/syntax_word_diff.lua` checks rendering, patch overlays, syntax projection,
style switching, text fallback and cache lifetime.
`python tests/syntax_word_diff_ui.py` checks cold/ready foreground composition
in a real TUI, including the leading JSON key, declaration-only function and
mixed-context multiline declaration, Markdown license prose and Vim fallback.
Pass `nordfox` to repeat with this repository's theme settings.
`tests/syntax_source_context.lua` exercises actual staged/unstaged/renamed Commit
sources, shared reads across disjoint hunks, warm caches and canceled-read reopen.
`tests/syntax_full_file_context.lua` checks complete-file comparison against
native ranges across the recorded structural cases, including the reported Lua
indentation case, malformed JSON and Markdown. Comparisons remain shared with
missing color queries, and unchanged views neither compare nor repaint again.
The real `syntax_highlight.lua` rewrite also checks that nested edits split into
small searches rather than one graph containing several changed functions.
The `syntax_word_diff.lua` comparison-body fixture checks that shrinking keeps
unique function anchors. Long addition/deletion fixtures assert zero graph
searches and retain native token backgrounds without tinting indentation.
`tests/syntax_parent_scope.lua` checks that a single edit in 6,400 lines / 400
functions converts only its enclosing function, preserves full-tree ranges and
source coordinates, and shares an expanded region across disjoint edits.
`tests/syntax_php_context.lua` checks native PHP ranges in real staged/unstaged
and renamed Commit views, omitted tags/classes, embedded HTML, shared file
comparison, source-context invalidation, missing queries, Text fallback and
closing one view while another still needs the shared comparison.

`tests/delta_word_diff.lua` compares exact source byte ranges with checked-in
fixtures captured from delta 0.19.2. Run it with
`nvim --headless --clean -u NONE -l tests/delta_word_diff.lua` from this plugin's
directory. `tests/generate_delta_fixtures.py` regenerates the oracle with that
version of delta installed. Unicode 16 word/grapheme tables and their pinned
source URLs are maintained by `tests/generate_delta_unicode.py`; upstream notices
are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

In `treesitter` style, coloring and comparison retain complete old/new sources
when available, sharing pending and finished comparisons across their hunks.
Hunk parsing is deferred until complete sources cannot be used. Both use the
same asynchronous parser and 16-entry cache for sources up to 1,000,000 bytes; open buffers also
retain their current source trees, comparison results and highlight plans, so
shared-cache eviction does not force open views to recompute. Unchanged buffers
skip rebuilding hunks/marks. On edits, changed hunks, coloring source identities
or coordinates, and query/style settings regenerate relevant highlights; intact marks move with their raw patch rows,
and cached plans restore them after buffer reconstruction. A buffer edit records
which cached hunks overlap the changed rows. Only those retained hunks need their
mark positions checked; expanding another file does not read existing marks.
Closed hunks/buffers release their resident results.

Complete coloring sources use `highlight_sources` sessions per attached view:
up to two asynchronous file requests run at once, identical pending requests
share listeners, and eight completed source pairs are retained. Inputs are
checked against the 1,000,000-byte parsing bound and binary content is rejected.
Immutable blob identities avoid rereading unrelated files when the index changes.
Worktree fingerprints reject changes during reads. Closing a hunk releases its
listener; a remaining listener keeps the shared read alive. Closing the view
terminates Git jobs and closes file reads. Reopening cannot join a killed job,
and late callbacks cannot publish closed-view results.

Cold hunks first display their gutters and normal source foreground with an
animated loading icon. A shared 100 ms timer updates only pending icons; it
does not refresh hunks or restart analysis, and stops when no icons remain.
While comparison or structural recovery is pending, syntax colors remain
visible and diff backgrounds wait for the hunk's final results. Provisional
Text ranges and previous source-context backgrounds are not displayed.
Neovim's asynchronous parser API splits parsing into
short steps; pending identical sources share a job. Highlight queries run in
cooperative 3 ms slices and cache their source-coordinate captures. Dense
background/syntax mark plans also paint in batches, allowing editor callbacks
between them; relative plans follow moved rows and cancel when invalidated.
Background range construction yields between groups/rows as well. Foreground
painting has an independent lifetime, so partial background results cannot
restart it. Existing marks are reused by their relative span/style; completing
a comparison updates changed backgrounds without rebuilding syntax marks.
Mark ownership is retained per hunk; position checks read only an edited hunk's
row range, avoiding namespace-wide inventories. Hunk layouts and final Text
fallback spans remain cached.
Neither parsing nor structural search starts inline on a cold attach. A common
FIFO queue starts one slice at a time across views instead of running every
hunk's time budget in one refresh. Completed results refresh only the waiting
hunks or source pairs, coalesced per buffer. Unaffected hunks do not reread source
fingerprints, serialize patch text or rebuild marks on those notifications.
Shared recovery graphs retain every waiting source pair in a buffer, so closing
one hunk cannot discard another's completion. Buffer edits and explicit refreshes
still check the whole view for changed content or settings.
Closing a queued cold hunk skips parsing entirely.
`tests/syntax_multi_open.lua` expands 16 dense file diffs past the shared cache
limits, checking that only new sources are parsed/compared/queried/painted, no
existing marks are inventoried, and shared graph recipients receive completion.

Complete files are still parsed for reliable context, but only the enclosing
changed region is converted into a comparison graph. A large changed class or
edits spread throughout a file can therefore still need substantial work.
Graph search uses the reference's 3,000,000-vertex default bound. Unchanged ends
and substantial equal subtrees split comparisons before search. Inside changed
parents, the same unique-subtree test separates mostly unchanged nested elements,
and each resulting region trims its unchanged ends again. This keeps adjacent
insertions from pulling a whole nested function into the same search. Shrinking
can expose new sibling lists; unique unchanged named functions in
those lists remain anchors. Repeated statements in different branches stay in
the graph to avoid choosing a different duplicate correspondence.
Once an anchored region has nodes on only one side, its tokens are marked
directly without graph search, similarity scoring or word comparison. A Git
`+`/`-` block alone is insufficient: wrapping or moved syntax can have matches
elsewhere, so this shortcut follows structural preprocessing.
Immutable delimiter stacks/chains are interned and reused, with exact numeric
identities for search variants. Chains retain actual node identities because
node numbers restart on each side. State costs sit in their node-pair bucket;
the delimiter phase uses its numeric key instead of additional nested tables.
The frontier uses integer cost buckets and newest-first ties, preserving the
previous binary heap's search order while avoiding repeated heap sorting.
Literal similarity scores are reused per atom pair. These changes reduce
allocation/search overhead without lowering graph limits or changing which
syntax correspondence is accepted. A sufficiently large changed region can
still require many states, even after unchanged subtrees have been removed.
Longer work resumes cooperatively with a 5 ms target per scheduled slice; elapsed time alone
does not force text fallback. Private conversion graphs share parsed trees and
keep suspended searches from mutating each other's sibling links. Pending
comparisons keep syntax colors and the loading icon; completion refreshes only waiting
views, coalesced per buffer. Jobs cancel when their source pair closes/changes or
the style switches. Block-recovery results belong to the cached source pair;
fragment/declaration recovery also parses asynchronously and shares source
trees. Its listeners belong to the source pair, so closing the initiating view
preserves work still needed by another view; canceled parses can be retried.
Parser/capture/search/painting steps cooperate on the main thread rather
than running in a separate process. Individual native calls can exceed the
slice target. `tests/syntax_word_diff_perf.lua` checks many open hunks/views,
cold display without parsing, single-hunk edits, shifted/rebuilt rows, dense
painting between editor callbacks, shared recovery after closing its first
view, cooperative completion and cancellation.
This is a local adaptation verified against the recorded cases, not a guarantee
of identical results for every Difftastic language/input. Verified complete
sources allow correspondence across separate hunks. Missing or mismatched
sources still use hunk comparison, where omitted enclosing syntax can cause
Text fallback. Parser versions, language rules, limits and preprocessing/slider
heuristics can produce different correspondences from the reference.
Comparison reuses the file reads and trees already needed for coloring;
no external diff command is executed.

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
Help is available through `?`.

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
| `gH` | History editing, including the message-edit float |
| `X` (normal/visual) | Remove file, hunk, or selected lines; choose Hard or Mixed |
| `a` / `cv` | Apply / reverse the selected file or hunk in the worktree |
| `~` / `p` / `gp` | Parent / previous commit affecting the file / merge parent |
| `C` / `<C-Space>` / `O` | Commit information / graph / pull request |
| `gx` | Open pushed commit on GitHub |
| `gq` / `gy` | File quickfix / copy selected path or commit hash |
| `gD` | Display settings, including word-diff style |
| `R` / `q` / `?` | Collapse all file diffs and reload / close / help |

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

Log/Status reword, adjacent commit moves, drop, parent fixup, and index fixup
share this saved-worktree and rollback mechanism. History actions resolve full
hashes and validate Git's rebase todo before changing it. Moves, drop and fixup
select commits on the current first-parent history; merge targets are rejected
for these actions. Dropping every commit is also rejected. A contiguous drop
through HEAD can use reset internally. Index fixup commits the staged changes
and restores only the remaining unstaged/untracked work; on failure it restores
the original index as well. Root commits support reword and index fixup.

File, hunk and selected-line removal use forward patches, reversed against the
target commit. Selected-line patches retain quoted paths and EOF markers, count
one hunk, and leave unselected edits intact. A line selection on a rename keeps
its current name. Mixed restores the removed patch as unstaged changes after
the user's saved changes return. If either restoration conflicts, recovery
information retains the stash and/or removed patch. These actions run
synchronously, so replaying a long history can block Neovim.

LazyAgent Notes retain immutable file/line identity and follow a file header when
its diff is collapsed, returning to their selection on expansion. Their source
identity is preserved by the existing Notes session persistence.

## Implementation and checks

- `commit.lua`: view, editable-message validation, navigation, actions, routing.
- `commit_model.lua`: immutable metadata, file inventory, statistics, lazy patches.
- `commit_rewrite.lua`: target amend, descendant replay, and Hard/Mixed removal.
- `history_rewrite.lua`: validation, rebase todo edits, stash ownership and rollback.
- `history_edits.lua`: log/status move, drop, parent fixup and index fixup.
- `commit_patch.lua`: pure file/hunk/line patch selection.
- `commit_actions.lua`: message editing, view restoration and discard confirmation.
- `commit_notes.lua`: optional Notes identity and row mapping.
- `change_display.lua`: file rows and statistics shared with status.
- `panel_keys.lua`: normal key migration, contextual identifiers/help, and ordinary action choosers.

Run checks from this directory with
`nvim --headless --clean -u NONE -l tests/<name>.lua`.
The commit checks are `commit_view`, `commit_rewrite`, `commit_discard`, `commit_patch`,
`commit_notes`, `commit_lifecycle`, `commit_entrypoints`, and `commit_blob_return`
(`commit_blob_return` uses installed Gitsigns). No check loads Fugitive.
`history_edits` checks real move/drop/fixup operations, index contributions,
dirty-state preservation, conflicts and rollback. `commit_patch` checks special
paths, EOF, file creation/deletion, renames, historical Mixed removal and recovery.
`history_noop` checks actual Status A/ce and unchanged message saves, including
the absence of mutation commands and stable hashes, reflog and stash identity.
`commands` checks actual Git mutations and object lifetimes; `lazy_loading` checks
Lazy command registration and the active imports. `panel_help` checks long/wide-key alignment, colors, and action execution.
`panel_keymaps` covers reset
modes/cancel, selected stash/WIP identity, copy/edit/apply, and prefix input.
`editor` and `operation_output` use local Unix sockets and require socket permission.
`panel_layout` needs normal startup to apply editor-grid resize events:
`nvim --headless --clean -u NONE '+lua dofile("tests/panel_layout.lua")' +qa!`.

## Fixup target, argument presets, patch collection, and Undo/Redo

`GitFixupBase`, History `H f`, or Commit `c F` finds the commit behind the
current staged logical change. If the index is empty it examines tracked changes
against HEAD. Detection leaves the index unchanged. Deleted/replaced lines use
range blame; addition-only changes use their neighbouring lines. When deletion
hunks exist, pure additions are assumed related and the picker says so.
Configured `vim.g.git_main_branches` (default `{ 'main', 'master' }`) are excluded.
Multiple targets require staging a smaller logical change. The picker offers
inspection, fixup creation, or amending the target from staged changes; HEAD and
staged content are checked again before mutation. New files without existing
neighbours cannot be attributed automatically.

Operation menus support argument presets with the following keys:

| Key | Behavior |
| --- | --- |
| `<C-w>` | Save this operation's arguments for the session and worktree |
| `<C-s>` | Save default arguments for all worktrees |
| `<C-r>` | Save default arguments for this worktree |
| `<C-h>` | Recall recent executed argument sets for this operation/worktree |
| `<C-d>` | Clear this operation's global and current-worktree saves; restore built-in defaults |

Session saves take precedence over worktree saves, which take precedence over
shared saves. Unsaved toggles remain local to the open menu. Execution history
keeps at most 20 distinct sets per operation/worktree. Persistent defaults and
history use `stdpath('state')/git-ui/transient-presets.json`; the menu still shows
which arguments are active. Selection targets are not saved as arguments.

`GitPatch [commit]` opens a dedicated tab with the existing commit view on the
left and an editable new-commit message plus accumulated patch preview on the
right. `<Tab>` from Log/Reflog/Commit detail, or a commit row in Status, opens
this tab. Status section rows retain their fold toggle.

| Where / key | Behavior |
| --- | --- |
| Left `<CR>`, `o`, `=` | Toggle the selected file diff |
| Left `>` / `<` | Expand / collapse the selected file diff |
| Left `<Space>` | Toggle the whole file or current hunk in the collection |
| Left Visual `<Space>` | Toggle changed lines within one hunk |
| Either `<Tab>` | Move between source and collected patch |
| Right `c` | Confirm splitting the selected changes into a new commit after the source |
| Right `r` / `R` | Clear the selection / restore the generated preview |
| Either `q` | Close the tab and release its selection and owned buffers |

The collection belongs to one immutable source commit and can span files and
noncontiguous changed lines. It does not follow a different commit implicitly.
Titles, hashes, hunk headers and selection indicators are colored consistently
with Status/Log, alongside the preview's diff/code highlighting.
Visual entry keys keep their existing mappings (`v`, `vv`, `V`, and `<C-v>`);
commit patch reverse is `cv`. The collected preview uses the same diff backgrounds, word changes, and
code syntax highlighting as the source; the editable message is excluded.
Edit only the message above the separator; edited preview text is rejected at
split time. Splitting rejects merge commits, validates HEAD, preserves WIP via
the shared rewrite transaction, recomputes the removed diff, creates the new
commit, and replays descendants. Failures roll back history; a failed WIP
restore retains a recovery stash and reports its identity. The final view opens
the newly created commit. Closing the tab during a rewrite lets the transaction
finish, while read-only collection jobs are cancelled or their results ignored.

History `H u` / `H r`, `GitUndo`, and `GitRedo` interpret HEAD reflog
operation boundaries. Commit/reset/pull-style Undo uses soft reset; completed
rebase Undo treats the whole rebase as one operation and uses hard reset.
Dropping a suffix through this UI records `[nvim git drop]` so Undo restores
both history and file contents with hard reset, including the optimized path
that skips rebase. Older unmarked resets retain soft-reset semantics.
Checkout Undo restores the original branch/ref. Redo uses hard reset or checkout.
`[nvim git undo]` / `[nvim git redo]` reflog marks reconstruct the position after
restart, scoped naturally to this worktree's HEAD reflog. The confirmation shows
the operation and reset mode. HEAD, branch and reflog are checked again after
confirmation. Active Git operations, incomplete boundaries, and unsupported
reflog entries are rejected rather than guessed. Worktree edits, stash actions,
branch creation/deletion and remote pushes are not independently undoable.

Redo after several soft Undos keeps later undone changes staged until those
commits are redone. Independently staged changes are preserved; incompatible
staging is rejected before changing history. The saved index is checked again
before mutation. Unstaged and untracked changes use the shared stash transaction;
if restoration conflicts, the original recovery stash is retained and reported.

New workflows run Git sequentially through asynchronous subprocess callbacks;
heavy rebase/apply sequences do not wait in the editor event loop. A worktree
admits only one new history workflow at a time; the generic Git command also
refuses conflicting mutations. External Git processes can still modify a repo,
so the same HEAD/staleness guards remain necessary. Exit stops outstanding jobs
without waiting for editor callbacks; interrupted Git state and any saved stash
must be recovered using Git's continue/abort/reflog tools.

Checks: `tests/history_undo.lua` covers repeated Undo/Redo, checkout/drop across
branches, actual Neovim process restarts, external rebase, detached HEAD, linked
worktrees, staged/unstaged/untracked changes, recovery stashes, cancellation and
stale-state rejection. Its baseline sequences follow lazygit's
[commit](https://github.com/jesseduffield/lazygit/blob/master/pkg/integration/tests/undo/undo_commit.go)
and [checkout/drop](https://github.com/jesseduffield/lazygit/blob/master/pkg/integration/tests/undo/undo_checkout_and_drop.go)
integration tests; this is coverage of those scenarios, not full UI parity.
Related checks: `tests/history_workflows.lua`, `tests/transient_presets.lua`, and
`tests/async_lifecycle.lua`.

## Rebase plans

`GitRebasePlan [old-base [new-base]]` opens an editable plan, oldest commit
first. `<Space><Space> H p` opens the same panel from Git views. A selected
commit and its descendants are included unless a base has been marked.
Otherwise the default is the upstream merge base, falling back to the latest
20 commits when no useful upstream base is available.

The old base is **excluded** from the replay range. Mark it from a commit list
with `<Space><Space> H b` or `GitRebaseBase [commit]`; its row shows a `B` sign
and `[rebase base]`. Repeating either action on the same commit clears the mark;
choosing another commit moves it. Marks belong to the current worktree and
Neovim session; `GitRebaseBase!` clears one. An explicit old base overrides the mark.
`GitRebasePlan --root` includes the root commit.

| Key | Plan editing |
| --- | --- |
| `dd` then `p` / `P` | Cut and move commit rows using native Neovim operations, including counts and registers |
| `i` / `A` | Edit the subject inline; a changed message automatically becomes reword |
| `gk` | Edit the full message and body in a float; `:w`, Ctrl-s or ZZ saves it to the plan |
| `u` / Ctrl-r | Undo / redo draft edits, including saved body drafts and base changes |
| `ca` | Choose pick, reword, edit, squash, fixup or drop |
| `cp` / `cr` / `ce` / `cs` / `cf` / `cd` | Set those actions directly |
| Ctrl-a / Ctrl-x | Cycle those six actions forward / backward with dial.nvim; counts and Visual selection work |
| `cb` / `cx` | Insert break / a prompted exec shell command after the cursor row |
| Ctrl-x Ctrl-u | Complete the action at the start of a row |
| `mb` | Mark this original commit as old base and keep only its descendants in the plan |
| `mo` | Choose the new base by branch or revision |
| Enter | Inspect the original commit in a separate tab |
| `:w` / Ctrl-s | Validate, confirm and execute the entire plan; continue a paused plan |
| `cC` / `cS` / `cA` / `cT` | Continue / skip / abort / edit the live todo of a paused plan |
| `g?` / `q` | Help / close the draft, prompting before discarding edits |

For a stacked branch, mark the last commit of its old parent stack, open the
plan, and use `mo` to select the new parent tip. Only the displayed descendants
are replayed onto that tip, following Git's
[`rebase --onto` semantics](https://git-scm.com/docs/git-rebase#_transplanting_a_topic_branch_with_onto).
Other branch refs retain their original targets.

Plans support linear ranges; merge topology uses the ordinary Interactive
rebase action. `edit` pauses for manual amendment; use reword for a message
prepared in the plan. The plan rejects duplicate/out-of-range
hashes and invalid fixup/squash order. Deleted rows are drops, counted in the
execution confirmation; an empty plan is rejected. Subjects on fixup/squash
rows retain their original text; edit the retained commit with reword instead.
Plan edits leave Git untouched until execution. HEAD/branch changes invalidate
the plan, and changes while confirmation is open require another review.
Execution preserves staged/unstaged/untracked changes. Ordinary plans roll
back failed replays. Plans containing edit/break/exec retain an active rebase
on a stop or conflict, letting you amend/resolve and continue. A failed exec
is consumed rather than automatically rerun; use edit-todo to retry it.
The paused plan is read-only; its banner lists continuation keys. Saved WIP
stays in stash until completion/abort, while editor scripts and messages persist
in the worktree's Git directory across Neovim restarts. `GitRebaseContinue`,
`GitRebaseSkip` and `GitRebaseAbort` work without reopening the panel, and the
existing `Git rebase --continue/--skip/--abort` actions route through the same
owner. If external Git already finished or aborted, GitRebaseContinue restores
the saved WIP on the original branch. Restore conflicts retain the original
recovery stash and report its hash. Completed plans use GitUndo/GitRedo.

Both GitRebasePlan and GitPatch use theme-linked accents consistent with the
Status/Log panels: titles, action names, hashes, refs, guides and hunk headers.
GitPatch shows green selection signs and collected/partly-collected file labels;
its generated diff retains addition/deletion backgrounds and code highlighting.
The dial action cycle also works in the live gitrebase todo. It only changes a
commit row's leading action, leaving hashes, subjects and exec commands intact;
other filetypes keep the existing numeric/date/boolean dial rules.

The ordinary Git sequence-editor buffer also gets `ca`, `cp/cr/ce/cs/cf/cd`,
`cb`/`cx` insertion, action completion, dial action cycling, `gk` message preview
and `g?` help. In that live Git todo,
subject text is descriptive; `cr` marks reword and Git subsequently opens its
message editor. Its normal write/close workflow remains available.

Checks: `tests/rebase_plan.lua` covers real replay, partial onto, root messages,
squash/fixup/drop, WIP restoration, conflict rollback, native editing/completion,
body/base undo, marks, commands, menu dispatch and stale drafts, plus break/edit,
exec failure, continuation/abort/skip, restart with pending reword, worktree
isolation and recovery-stash retention. `tests/editor.lua` exercises reword
and exec insertion in Git's actual sequence-editor RPC workflow.
`tests/dial_rebase.lua` runs the installed dial plugin through Lazy and actual
normal/Visual key input, including counts, reverse cycling and hash protection.

## Additional Git workflows

Open `<Space><Space>` first. Existing Magit prefixes and suffixes are retained
where those operations exist; Bundle `U`, tree `=t`, custom command keys and
extra Notes sync/review actions are local choices. Log reword in this menu is
`cw`, leaving `w` for mail patches. Native `v` still enters Visual selection.

| Prefix | Actions after the prefix |
| --- | --- |
| `>` sparse checkout | `e` enable/restore, `s` replace directories/patterns, `a` add, `r` reapply, `d` disable, `l` list |
| `O` Subtree | `i a` import repository/ref, `i c` add existing commit, `i m` merge, `i f` pull; `e s` split and `e p` push |
| `U` Bundle | `c` create, `v` verify prerequisites, `l` list refs, `u` import objects without moving refs, `f` fetch an explicit refspec |
| `W` plain patches | `c` format-patch from selected commits/range, `s` save selected/current diff, `a` plain apply submenu |
| `w` mail patches | `w` patch files/mbox, `m` Maildir, `a` plain apply; during `am`: `w` continue, `s` skip, `a` abort, `p` inspect current mail |
| `T` Notes | `T` edit, `s` show, `r` remove, `p` prune, `m` merge; `f` fetch into incoming notes ref, `P` push explicit notes ref; during merge: `c` commit, `a` abort |
| `P v` | Review range-diff against the push ref, falling back to upstream; push remains a separate action |
| `!` | Run configured custom Git commands |
| `=t` | Open changed files as a directory tree; also `:GitStatusTree` |

Sparse mode arguments apply to enable/set/reapply; add preserves the existing
mode. Sparse index requires cone mode. Directory/pattern lists and patch file
lists accept quoted paths containing spaces. Subtree import offers prefix,
squash and message arguments; export offers split branch, annotate, onto,
rejoin and ignore-joins. Bundle creation accepts all refs or explicit revision
arguments, including incremental bundles whose prerequisites must exist at the
receiver. Existing bundle/patch exports are refused. Numbered patch output must
use an empty directory.

Visual Log `<Space><Space> W c` writes only the selected commits, oldest first.
`W s` exports the selected commit or Status files, including binary changes;
without a commit/file selection it exports the current tracked diff, using the
index in the staged section. The plain apply submenu offers check, reverse,
index-only/index-and-worktree, three-way, reject and whitespace flags. Three-way
conflicts remain available for resolution. Mail patches preserve author and
message through Git `am`; Status recognizes `am` separately from rebase and its
`rr`/`rs`/`ra` controls dispatch to the matching operation. Skip/abort require a
confirmation. These operations use Git's normal dirty-worktree checks.

Range-diff compares two commit series by matching their patches, showing edits,
added/dropped commits and correspondence after rebasing. The Commit panel shows
one commit's changes. `P v` opens Git's range-diff output in a read-only tab;
file/hunk expansion belongs to the Commit panel. It uses the local push-tracking
ref, falling back to upstream, against HEAD. It does not fetch or push, so fetch
first when the comparison should reflect current remote history.

Notes synchronize independently of branch push. Fetch puts the chosen
`refs/notes/<name>` into `refs/notes/incoming/<name>`; merge it into the active
notes ref with `T m`. Push sends one explicit notes ref. Neither automatically
replaces local notes or force-pushes divergent history. Edit/show/merge use Git's
configured default notes ref unless `-r` overrides it. Resolve merge conflicts
in Git's `NOTES_MERGE_WORKTREE`, then use `T c` or `T a`.

The tree uses Status's porcelain-v2 parser and separate staged, unstaged,
untracked and conflicted sections. `o`/Tab folds a directory, Enter opens a file,
`s` stages or unstages all displayed changed descendants of the selected node,
`u` unstages, `d` compares, `R` refreshes, and `q` closes. Directory mutations
pass only the captured leaf paths with literal pathspecs, including rename
origins. Staging a conflicted file stages the current worktree content. Native
Visual editing keys remain free. Return to Status for hunk selection/discard.

Declare custom commands through `require('git').setup({ custom_commands = ... })`
or set `vim.g.git_custom_commands` before the plugin loads:

```lua
vim.g.git_custom_commands = {
  {
    key = 'l', label = 'History of selected paths',
    panels = { 'status', 'tree' },
    args = { 'log', '--oneline', '--', '{paths}' },
    mutation = false,
  },
  {
    key = 't', label = 'Create annotated tag',
    panels = { 'log', 'commit', 'reflog' },
    args = { 'tag', '-a', '{tag_name}', '-m', '{message}', '{commit}' },
    inputs = {
      { name = 'tag_name', prompt = 'Tag name' },
      { name = 'message', prompt = 'Tag message', default = 'Release' },
    },
    confirm = true, output = false,
  },
}
```

Templates accept `{commit}`, `{branch}`, `{ref}`, `{path}`, `{worktree}` and
named inputs. `{paths}` and `{commits}` expand the captured selection to multiple
argv entries only as whole tokens.
Commit/ref/path come from the captured selection; `{branch}` falls back to the
current branch when none is selected. Missing values refuse execution. Inputs
may declare `choices`; cancellation runs nothing. Values stay literal Git argv,
including spaces, quotes and shell metacharacters. Definitions come only from
Neovim configuration. Commands default to mutation ownership; use
`mutation = false` for reads. Editor-capable Git commands get the Neovim editor
bridge automatically; `editor = true/false` overrides this. `confirm = true`
shows the concrete argv, `output = false` uses a completion notice, and `panels`
limits availability. Visual Status/Log action menus expose `!` with their
captured paths/commits. Definitions require unique keys and input names.

These workflows run asynchronously against the worktree captured when the
menu opens, emit refresh events after mutations (including conflict failures),
and reuse transient argument presets. Repository lists/recent switching are
outside this plugin's scope; Issue/PR authoring belongs to Octo. WIP timing and
untracked snapshot policy remain unchanged. `tests/magit_workflows.lua` covers
real sparse, subtree, full/incremental bundle, plain/binary/selected-commit and
mail/Maildir operations, conflict continuation/skip/abort, Notes sync/merge,
literal custom inputs, root-menu dispatch and tree staging isolation.

## Reflog recovery markers

`Greflog` colors a `HEAD@{n}` selector green when it identifies the state before
an amend, a reset or UI suffix drop that changed HEAD, or the start of an entire
rebase. Internal amend/reset records do not create additional markers. Ordinary commits,
checkouts, and no-op resets are not marked. The marker identifies a history
recovery candidate; it does not execute a reset or restore worktree contents.

Detection follows Git's reflog operation labels in chronological order. If a
rebase start is outside the 1000-entry window, no pre-rebase destination is
invented. Only the exact destination selector is green; duplicate-hash navigation
and highlighting remain independent. `FugitiveReflogCheckpoint` defaults to
`GitSignsAdd`. See `tests/reflog_checkpoints.lua` for real Git and truncated/
ongoing/aborted rebase cases.

## Blame

`<Leader>gb` toggles the current tab's independent, Git-backed blame panel;
`:GitBlame` opens or focuses it. Panel names use the stable repository/revision/path identity
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
commit under the cursor uses `#002b36` for all its rows by default; `gf` (or `gD` → `f`)
switches to a uniform view where every row uses that background, each hash keeps
its full commit color, all dates retain the recency heatmap, and bold is removed.
DiffDim pinning is unchanged. All other
commits use `#073642`; their hashes are muted and date/author text uses the
theme's subdued `#586e75` foreground. `gd` in either pane pins that commit and dims other
lines in the paired code buffer until toggled, `:DiffDim clear`, or closing blame.
Bare `:DiffDim` also selects the cursor-line commit while blame is open. Pinning
automatically shows that commit's metadata in the same session-owned info float
used by `C`. `C` in either pane toggles this float without clearing the dim:
while dimmed it targets the pinned commit; otherwise reopening targets the
cursor-line commit. Unpinning restores the viewed revision's info when browsing
history, or closes it in the working tree. The former `gC` mapping is removed.
Selected-commit rows are bold; other rows
use muted hash and date/author foregrounds.
Uncommitted groups show only a right-aligned virtual `Not committed` label, with
no date or zero hash; tab settings do not affect its alignment. Dates on the
selected commit retain the 13-color recency palette. Other commits use the same
subdued `#586e75` foreground for dates and author names. `gD` → `c` sets the shared
absolute or relative recency mode used by `GitHeatmap`; its 13-color
file-background heatmap and Snacks toggle are unchanged.

| Keys in blame | Action |
| --- | --- |
| `-` / `s` / `u` | Reblame at the commit that introduced this line |
| `~` / `<BS>` | Reblame before the change; counts follow first parents |
| `{count}P` | Reblame at the numbered parent of a merge |
| `Ctrl-o` / `Ctrl-i` | Back/forward through paired blame and code views |
| `gk` | Toggle full commit message near the code cursor; follows the cursor |
| `Ctrl-p` | Toggle a following commit diff preview |
| `<CR>` / `i` / double click | Open the commit at its file/diff line in another tab; `q` or jumping back to blame with `Ctrl-o` returns to the preserved blame/code pair |
| `o` / `O` | Open the commit in a split/tab, keeping blame |
| `d` | Open an immutable before/after diff in a new tab |
| `gD` | Display chooser: width, recency mode, and uniform background/heatmap |
| `gf` | Toggle uniform background/heatmap directly (both panes) |
| `gd` | Pin/unpin the cursor-line commit and dim other code lines |
| `[[` / `]]` | Previous/next block; while dimmed, jump between blocks with the pinned hash while keeping that target; count supported |
| `(` / `)` | Previous/next contiguous commit block by moving the cursor |
| `gy` | Copy the full commit hash |
| `gY` | Insert the commit hash on the command line |
| `C` | Toggle info: pinned commit while dimmed, cursor commit otherwise (both panes) |
| `R` | Refresh working-tree blame |
| `?` | Show available actions |
| `q` | Close blame and restore the original code buffer/view |

When viewing a historical revision, the session-owned top-right info float initially shows
the viewed revision’s hash, tree, parents, author/committer dates and message;
while dimming, it shows the pinned commit instead. It
uses the shared `commit_info` metadata also used by C floats: an exact HEAD~N
label on the first-parent chain, explicit merged/diverged/ahead relationships
otherwise, relative author/committer dates, and directly attached branch/tag refs.
The displayed target stays fixed as the cursor moves; `C` hides it and reopens
at the current cursor commit when undimmed. History navigation restores each
frame's display state. The float closes on return to an unpinned working-tree
frame without explicit info, and on session exit. The `gk`
float removes Git’s trailing separator blank lines while preserving message
paragraphs. It is independent and anchors to the selected code row, choosing above/below
to fit the window. Both floats adjust to resizing/scrolling.

`C`, `gf`, `gk`, `Ctrl-p`, and paired history keys also work in the code pane. Existing
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
