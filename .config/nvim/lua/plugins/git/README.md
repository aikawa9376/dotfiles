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


Standalone Neovim Git UI, loaded by `plugins.git`. It owns its status, log,
object, blame, and commit buffers directly. Flog is available lazily through
the native Git backend.

## Panel keys

Normal panel keys use the selected row, file, hunk, or Visual selection as their
context. Magit's `<Space><Space>` panels retain their existing keys and layout.

Status, Commit, Log, Branch, Stash, Reflog, PR and Issue use
`utilities.smart_close()` for `q`: ordinary splits stay in place and show the
source or another available buffer. Status stays cached while hidden. A
dedicated tab with one regular window still closes its tab. Floating menus and
paired inspection views keep their own close behavior; `<C-c>` in Status
explicitly closes its window.

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

Status, Commit and PR status `R` collapse all expanded file diffs and reload.
Status and PR status retain section fold state and the selected file, including
Status Index flags. Automatic refreshes retain expansion and fold state;
`<` collapses only its selected scope.
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
| `GitInit [directory]` | Open repository setup, including outside Git repositories |
| `Gedit[!]`, `Gsplit`, `Gvsplit`, `Gtabedit`, `Gpedit`, `Gdrop [object]` | Open a worktree file, commit, tree, or blob; defaults to index from a worktree file and worktree from an object buffer; supports modifiers, split sizes, `+cmd`, and `++opt` |
| `Gedit HEAD:%`, `Gedit :0:%` | Current file at HEAD or in the index; `:1:`, `:2:`, `:3:` select conflict stages |
| `Gwrite[!] [path]`, `Gwq[!] [path]` | Write and stage content; writing another source over uncommitted destination changes requires `!`; `%` names the current path; `:0:path` writes only the index; `!` also force-adds ignored files |
| `Gread[!] [object]` | Undoable buffer replacement, including unsaved changes; defaults to index from a worktree file and worktree from an object buffer; one address inserts after that line; two addresses replace that range; no disk/index write |
| `Gdiff`, `Gdiffsplit`, `Gvdiffsplit`, `Ghdiffsplit [revision]` | Diff worktree files against index (base during conflicts), or object files against worktree; `!` retains focus and compares conflict sides, index against HEAD, or a historical file against all parents; explicit revisions take precedence |
| `Gclog[!]`, `Gllog[!] [args]` | Repository history in quickfix/location list; `0Gclog` / `0Gllog` follows the current file through renames; positive ranges show line history; jump to the first result unless `!` |
| `Glog`, `GitLog [args]` | Custom log panel; a line range follows the selected file lines with `git log -L` |
| `Gblame`, `GitBlame`, `GitHeatmap` | Custom paired blame and heatmap |
| `DiffDim [revision / latest / older / newer / clear]` | Dim lines outside a Git diff or selected blame commit |
| `Gbranch`, `Gstash`, `Greflog`, `Gworktree`, `GworktreeSync` | Existing repository panels/actions |
| `Gcd`, `Glcd [directory]` | Change directory relative to the buffer's worktree root, or use an absolute / explicit `./` / `../` path |
| `GMove`, `GRename <path>` | Move a worktree/index file; rename is relative to its parent directory; historical/conflict sources are rejected; lowercase aliases remain available |
| `GRemove`, `GUnlink`, `GDelete` | Remove a file (only from index in an index buffer); Remove/Unlink retain an empty buffer, Delete closes it; lowercase aliases remain available |
| `GeditHeadAtFile`, `GitCommit [revision]`, `GitPush` | File's latest commit, commit detail, existing force-with-lease push action |
| `Ggraph [native / flog]` | Open either graph; omitted backend uses the selected default |
| `GgraphBackend [native / flog]` | Change the default for graph keys; no argument opens a picker |
| `GbranchSpinoff [commit]`, `GbranchSpinout [commit]` | Move outgoing commits, optionally starting at a selected commit, to a new tracking branch |
| `GitWipEnable`, `GitWipDisable`, `GitWipSave`, `GitWipLog`, `GitWipRestore [number]` | Save, inspect, and restore tracked work-in-progress snapshots |

`Gedit %` refers to the current file/object, `Gedit :` opens Status, and plain
file paths open worktree files. `HEAD:%` explicitly selects the committed file.
`%`, `#`, numbered alternate buffers and owner revisions such as `!~1:%` are
expanded using repository context. `Gw` and `Gr` alias Gwrite and Gread.
Gdiffsplit respects `vertical` / `horizontal` modifiers and `diffopt`; its
automatic fit can be disabled with `vim.g.git_diffsplit_directional_fit = false`
(the old Fugitive setting is also accepted).
Multi-parent/conflict comparisons provide `d2o` / `d3o` to select a side.
These convenience commands follow Fugitive file semantics; custom panels and
`G` / `Git` execution and output retain their existing independent behavior.

Successful `:Git` mutations refresh repository panels without opening a result
window. Read-only commands such as `:Git log` still open their output. From a
Git panel, commands that normally use a terminal run in the background, while
the commit/rebase editor still opens when needed. Elsewhere, their terminal
closes after completion. Failures are reported by notification, including the
last Git output lines. Use `:Git!` to keep a terminal open explicitly, or to
show output from a synchronous mutation as a notification. Interactive patch
mode still opens a terminal for its prompts.

In a file buffer, select lines and press `g<Space>l` to open their history in
the custom log panel. `:10,20Glog` and `:10,20GitLog` do the same; without
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
While Git panels are open, Lualine shows an animated operation indicator for
fetch, pull, push, and fetch/rebase activity, including in inactive Git windows.
The header shows `Head`, the configured `Upstream` (the usual Pull source), a
separate `Remote` row for a distinct Push destination branch when applicable,
and the nearest current/next tags with their commit distances. `Tag` is omitted
in repositories without tags.

In status, `gx` opens a PR row, a pushed commit row, or a pushed `Head` /
`Upstream` / `Remote` branch on GitHub. It also works on branch-list branches, log
commits, and commit detail views. Branch and commit links require a matching
local remote-tracking ref with a GitHub remote; unpushed items show a notice.
`gi` manages index flags from the status panel.

## Status shelves

Status can embed independently loaded modules between its normal sections.
The dotfiles configuration enables **Related notes** after the commit list.
It shows up to eight Obsidian notes related to the captured repository/branch,
using the same workspace, note index and ranking as `:ObsidianRelated`. Notes
remain in the vault; no Git-specific copy or note database is created. Notes
without a positive relevance score are omitted. An empty result hides the shelf.
Names align at the left edge, with the note file's modification date
(`YYYY-MM-DD`) in muted text on the right. The current branch's canonical
branch note receives an additional 150 relevance points in the shared ranking,
outweighing the combined outgoing-link/backlink bonus of 125. With matching
project/branch metadata it scores 350, ahead of indirectly linked notes at 325.
Candidates sort by relevance, then by modification time newest first, before
the eight-item limit is applied. Title/path order only breaks remaining ties.
Project and branch come from the Status buffer's Git snapshot, including when
the current directory points at another repository.
Enter opens the selected note in a tab. Enter on the heading or Tab anywhere
in the shelf toggles its fold. Folding retains each window's view rather than
reapplying `scrolloff`; folding from an item makes the ordinary move to its heading.
Note writes refresh the shelf; `R` and repository
reloads also reload its data. Unsaved note text is not indexed.

Status loading is reported once through `git.features.loading`, including the
initial snapshot, repository details, shelves and PR list. The dotfiles Lualine
configuration displays it in active and inactive status lines. For another
configuration, pass `require('git.features.loading').statusline` as a Lualine
component; `status(bufnr)` reads an explicit view and `busy(bufnr)` reports
unfinished work. The component does not take over window options or add rows.
Shelf replies are projected in configuration order at their configured anchors;
their loading tokens finish only after that projection is committed to the
buffer, including empty results and errors. Pending empty shelves stay hidden,
and a refresh retains existing items until their replacement arrives.
The single indicator stays visible while any source remains pending. It waits
120 ms before appearing, remains visible for at least 300 ms, and hides after
150 ms without pending work to avoid flashes between successive stages.
Inline diff syntax/word-comparison indicators keep their existing behavior.

Configure shelves once through `require('git').setup({ status_modules = ... })`
(the dotfiles Lazy spec supplies these options in `init.lua`). The same module
definition owns its identity, position, title, loader and open action:

```lua
status_modules = {
  require('git.integrations.obsidian').module({ before = 'unstaged', limit = 8 }),
  {
    id = 'tasks', title = 'Project tasks', after = 'commits', folded = false,
    load = function(context, done)
      -- Read the existing task source; use async IO for expensive work.
      done({ { id = 'task-42', text = 'Check the release checklist', url = 'https://example.com/tasks/42' } })
      -- An asynchronous loader may return a cancellation function.
    end,
    open = function(context, item) vim.ui.open(item.url) end,
  },
}
```

Use either `before` or `after` with a native section ID: `header`, `conflicted`,
`untracked`, `unstaged`, `staged`, `stashes`, `commits`, `unpulled`,
`pull_requests`, `submodules`, `worktrees`, or `index_flags`. `top` and `bottom`
are also available. Default placement is the bottom; a missing section also
falls back to the bottom. Modules at the same position retain configuration
order. These identities are shared with the native section/fold definitions.
For example, the existing Obsidian shelf can move by changing only its
`before`/`after` option.

`load(context, done)` receives `bufnr`, repository `root`, `branch`, HEAD `oid`
and changed `paths` from Status's existing Git snapshot. It must call
`done(items)` or `done(nil, error)` once. Items need a unique stable string `id`
and a one-line `text`; optional `detail` adds muted text after the name, and
extra fields pass to `open(context, item)`. Text is
display-only and never interpreted as a file path, commit or item identity.
The loader starts on a scheduled callback; it must not block Neovim. Errors
stay in that shelf, and results from superseded loads or closed views are
discarded. Each status buffer owns its own results and cancellation handles.

`hide_empty = false` keeps an empty shelf visible. Optional `highlight` sets
the heading color; items may supply their own `highlight`. `events` can declare
refresh triggers, for example `{ { event = 'User', pattern = 'ProjectTasksChanged' } }`.
An integration can also call `require('git.features.status_modules').refresh(bufnr)`.
Configure modules before opening Status; omitting `status_modules` from a
standalone `git.setup()` enables none. Shelf folds, selection and native
file/hunk identities survive asynchronous result updates and inline diff changes.

`status_sections` owns native section IDs and heading/default-fold metadata;
`status_modules` owns provider snapshots and their projection into Status.
The renderer retains Git entry ownership and maps its rows through that
projection. `git.integrations.obsidian` adapts the public
`obsidian_extension.features.related.query()` service, whose index and ranking
are also used by the existing picker. The API accepts a captured `git_context`,
an optional workspace `root`, `query`, `min_score` and `limit`, and returns a
cancellation function. Workspace indexes are isolated and shared by consumers.

Checks: `loading` and `status_loading` cover concurrent/superseded sources,
completion after projection, stable ordering, Lualine, errors and view cleanup.
`status_modules` exercises real Git staging alongside shelves, placement,
folds, semantic selection, provider errors, refresh events and stale callbacks;
`status_obsidian` covers the adapter, and `status_obsidian_cold` uses the shipped
Lazy specs with a real Obsidian client and temporary vault. The Obsidian extension's
`tests/related_query_spec.lua` covers shared ranking, simultaneous vaults,
cancellation, deleted notes and index errors.

## Repository initialization

`<Space><Space> I` opens **Repository setup** in Git panels. Outside a Git
repository, use `:GitInit` (or `:GitInit /path/to/project`) to open the same menu.
This follows Magit's root `I` / `magit-init` entry, extended with starter files
and GitHub creation.

| Setup key | Action |
| --- | --- |
| `i` | Initialize only if the directory is not already a repository |
| `d` | Init if needed, and create missing `README.md` and `.gitignore` |
| `g` | Default files, GitHub/origin setup, `main`, empty initial commit, and initial push; fill only missing pieces |
| `p` | Ensure `main` and an empty initial commit if needed, then initial push to existing `origin` |

The directory prompt defaults to the captured worktree in a Git panel, or cwd
for `:GitInit`. Relative paths resolve against that directory even if cwd changes
while a menu or input UI is open. Missing directories are created. Existing
repositories skip init. Creating a nested repository still requires Continue.
Plain/default-file init honors Git's `init.defaultBranch` and templates.

Default files are written only if missing, including protection against replacing
symlinks. README contains `# <directory-name>`, or the selected repository name
when creating a new GitHub repository. The general `.gitignore` excludes
editor swap/backup files, OS metadata, and local `.env` files while allowing
`.env.example` and `.env.sample`. Customize either template with lists of lines:

```lua
require('git').setup({ repository_init = { files = {
  ['README.md'] = { '# My project', '', 'Project description' },
  ['.gitignore'] = { '.env', 'node_modules/', 'dist/' },
} } })
```

GitHub setup (`g`) works for new and existing repositories. If `origin` already
exists, it keeps that connection and skips GitHub creation and its prompts. It
can therefore also fill missing setup for a repository hosted elsewhere.
Otherwise it asks for a repository name (`name` or `OWNER/name`, defaulting to
the project folder name) and visibility (private first, or public), uses the
active `gh` authentication and configured Git protocol, and connects `origin`.

Both `g` and `p` keep an existing local `main`. If it is missing, they rename the
current branch to `main` without force; from detached HEAD they create `main`
without switching the current checkout. When that branch has no commits, they
create `Initial commit` with `git commit --allow-empty --only`: the commit is
empty even when changes are already staged. README/gitignore remain untracked
unless you staged them beforehand, and existing staged/worktree changes are kept.
Existing history gets no additional initial commit.

Initial push checks the push destination for `refs/heads/main`. Only if missing
does it run `git push -u origin main`. When the remote branch already exists,
it skips pushing (including newer local commits), and fetches/configures
`origin/main` as upstream only when that setting is missing. An upstream already
pointing elsewhere is retained; an initial push then omits `-u`. No force push is
used. This is repository setup; use the regular Push menu for later commits.
`p` needs an existing repository and `origin`, and creates no default files.

All setup actions open Status afterward. On a failure after init, local files,
history and any connected remote are retained. Retry the same action after
correcting the error; after a push failure `p` can finish without another commit
or remote creation. A remote created before a later connection failure may need
to be connected through the Remote (`M`) menu before retrying.

`git.features.repository_init` owns target resolution, templates, preflight and
creation. `tests/repository_init.lua` covers real Git initialization, empty commits,
index/worktree preservation and pushes to temporary local bare repositories.
GitHub calls are mocked; validation does not create or push to GitHub repositories.

## GitHub and PR status

`N` in ordinary Git panels, or `<Space><Space> N`, opens the repository GitHub
menu. `:GitHub` also opens it from a repository file. Status PR rows now show CI, review and
mergeability summaries; Enter opens the native PR status panel. Octo remains
available through the GitHub menu as an alternative discussion/review UI.

| Repository GitHub menu key | Action |
|---|---|
| `p` / `l` | Open current/selected PR status / choose an open PR |
| `C` | Create default PR: edit only the prefilled title |
| `c` | Create a PR using Octo's editor |
| `e` / `r` | Open in Octo / start or resume an Octo review |
| `w` | Create and open a separate PR worktree |
| `k` / `a` | CI checks / GitHub Actions runs |
| `d` / `m` | Toggle draft/ready / choose a merge method |
| `x` / `M` | Close/reopen the PR / change labels, assignees and review requests |
| `i` / `I` | Native Issue list / creation |
| `o` / `n` | Octo issues / notifications |

### Native Issues

`:GitIssue [number|URL|list flags...]` opens an Issue in the native `gitissue` panel.
With no selector it opens the Issue list; `:GitIssueList` and
`:GitIssueCreate` also work before the plugin is loaded. The repository GitHub
menu exposes the list on `i`, creation on `I`, and the alternative Octo list on
`o`. Listing defaults to **open Issues, at most 50**. It requests only number,
title and URL with bounded `gh issue list` pagination; repository size does not
cause all Issue bodies or all pages to load. Pull requests are excluded.
Both `GitIssueList` and `GitIssue` without a selector accept these flags:

```vim
:GitIssueList --state open --limit 50
:GitIssue --state closed --limit 20
:GitIssueList --state all --label "help wanted" --assignee @me --limit 100
```

`--state` accepts `open`, `closed` or `all`; `--limit` is a positive integer.
`--label` can be repeated (all labels must match); `--assignee` accepts a login
or `@me`. Short forms are `-s`, `-L`, `-l` and `-a`. Both `--state closed` and
`--state=closed` work. Quotes and escaped spaces keep label names together.
List flags cannot be combined with an Issue number/URL. Tab completes flag
names, state values, common limits and `@me` locally, including on cold plugin
loading; completion makes no GitHub requests. The picker can switch state and
choose repository label/assignee filters while retaining the requested limit.
The picker title displays the active state, cap and returned count.


Numbers use the captured repository; URLs retain their host/repository. A PR
number or URL is rejected rather than treated as an Issue. Opening does not
require a branch PR, fetch revisions, compute diffs, or read PR/review/CI APIs.

| Issue panel key | Action |
|---|---|
| `cw` / `A` outside the draft | Edit the title and Markdown body |
| `<C-s>` / `:w` | Save the changed title/body fields |
| `o` / `=` / `Tab` / `>` / `<` outside the draft | Toggle / expand / collapse header or Conversation |
| `gc` / `gC` / `gcn` / `gcp` | Write a comment with immutable conversation history |
| `gA` on a comment | Reactions; edit/delete your own published comment |
| `gE` | Choose labels/assignees on their header row, or open the metadata panel |
| `gco` / `gh` | Reveal Conversation / go to the header |
| `gx` / `gy` | Open the Issue or selected comment in the browser / copy the Issue URL |
| `N` / `<Space><Space>` / `:GitHub` | Issue actions, including metadata and close/reopen |
| `R` outside the draft | Refresh while retaining local title/body edits |
| `?` / `q` | Key guide / close (asks before discarding edited title/body) |

Native editing keys continue to edit the title/body. The header and Conversation
are protected; semantic row associations retain the selected comment even when
its Markdown resembles a panel header or an edited body grows. The description
and each comment use the PR Markdown renderer as independent regions, including
fenced code blocks. Missing renderer/parser dependencies leave plain Markdown.
Conversation contains ordinary comments plus close/reopen, label and assignee
activity in API order. Unknown events remain read-only, duplicate comments are
removed, and unavailable activity/comments show a source-specific warning while
other available content stays readable. There are no PR diff, commit, review,
merge, CI or worktree sections.

Writes recheck resource identity and the relevant latest values. Title/body
updates check `viewerCanUpdate` and compare only edited fields; labels and
assignees check their specific permissions and change one membership at a time.
Concurrent changes to an unedited body/title are adopted after a successful
save. Later edits made while sending remain in the buffer. Automatic refresh
retains the draft's original comparison baseline, so it cannot silently accept
an overwritten remote field. Conflicts or failed requests retain the draft.
These preflights do not provide a server-side atomic compare-and-swap guarantee.
Comment edit/delete rechecks ownership and freshness; reaction removal targets
only the current viewer's reaction. Issue comment history does not write PR read
receipts. Successful Issue writes emit `GitHubChanged` with `resource_kind =
'issue'` and do not trigger local Git status/revision refreshes.

Close offers **completed** or **not planned**, verifies the displayed state/reason
and current close permission, and writes only state/reason. Reopen verifies
reopen permission and writes only state, leaving the reason to GitHub. Creation
uses the shared composer: first line title, blank line, then Markdown body;
`<C-s>`/`:w` submits, failure keeps input, and success opens the created Issue
when its composer is still focused. `Tab` switches to/from context/history;
`gA` in history uses the same comment actions. Duplicate sends are suppressed.

Body reactions, milestones, Issue types, Projects, sub-issues and dependencies
remain outside this surface. `tests/issue_model.lua`, `issue_view.lua`,
`issue_actions.lua`, `issue_list.lua` and `issue_markdown.lua` cover bounded
filtered listing, command/value completion, Issue-only IO, partial reads,
permissions/conflicts, retained drafts, menus/composers, state reasons, filters,
creation, callback ownership and actual Markdown rendering. GitHub writes are
fixture-tested; real write validation requires a designated test Issue.
API contracts: [Issues REST API](https://docs.github.com/en/rest/issues/issues),
[Issue GraphQL schema](https://docs.github.com/en/graphql/reference/issues).

### Pull requests

In PR status, `<Space><Space>`, `N` and `:GitHub` open a **PR actions** menu.
It is the common entry point for the current PR, including the existing comment
and review submenus. Opening it from a diff retains the source file/line when
entering a submenu. It omits PR creation, the redundant current-PR opener, PR
listing, Issues and notifications; those remain in the ordinary repository menu.

| PR actions menu key | Action |
|---|---|
| `c` | New comment destination menu (same as `gC`) |
| `r` | Native review / Resolve menu (same as `gr`; `R` inside resolves/reopens a thread) |
| `t` / `v` | Read/reply to threads / preview conversation at the source row |
| `p` | Reveal and read the PR-wide Conversation section |
| `f` / `D` / `s` | Compare selected file / entire PR in Diffview / diff display settings |
| `E` | Edit title / description |
| `M` | Change labels, assignees and review requests |
| `o` / `>` / `<` | Toggle / expand / collapse the source section or file diff |
| `R` / `?` | Refresh PR status / key guide |
| `k` / `a` | CI checks / GitHub Actions runs |
| `d` / `m` / `w` | Draft/ready / merge / separate PR worktree |
| `x` | Close / reopen PR (unavailable for merged PRs) |
| `b` | Open this PR in the browser |
| `e` / `O` | Edit/discuss in Octo / resume an Octo review |

`c` and `r` in this PR menu mean native comments/review. In the repository menu
they retain their existing PR-creation / Octo-review meanings.

`:GitPr [number|URL]` opens PR status. An omitted argument uses the current
branch's PR; a worktree created by this plugin remembers its PR URL, including
the Enterprise host. Current-branch lookup uses gh's local branch/tracking
association; explicit numbers and saved URLs select their repository directly.
The panel displays state, draft status, review decision,
mergeability, CI checks, title and description above the changed files.
Between the description and Changes, `Commits (N)` lists the PR's
merge-base-to-head history, newest first, and starts collapsed. Its gutter arrow
uses the same open/close keys as the header. Rows use GitLog's short hash, date,
subject and author columns/colors; Enter opens commit details and `gx` opens
that commit on GitHub. The list and its open/closed state survive refreshes;
unchanged comparisons reuse the already loaded history.

| PR status key | Action |
|---|---|
| `cw` / `A` | Move to the editable title and description |
| `:w` | Save title and description to GitHub |
| `<C-s>` | Save title and description to GitHub |
| `o` / `=` / `<Tab>` | Toggle header details, CI results, Conversation, Commits, Changes, or the selected file's unified diff |
| `>` / `<` | Expand/collapse the selected section or file; Visual selection supports multiple files |
| `gu` | Go to the changed-files section |
| `gp` | Go to the commits section |
| `gh` | Go to the Repo header |
| `gU` | Go to the CI section (UnitTest); `gc` keeps its comment action |
| `gco` | Go to Conversation |
| `]m` / `[m` | Next/previous file |
| `]]` / `[[` | Close departing file diffs and expand the next/previous file; counts supported |
| `J` / `K`, `]c` / `[c` | Next/previous diff hunk |
| `]t` / `[t` (also `]C` / `[C`) | Next/previous comment position and preview; counts supported |
| `gF` | Toggle the selected file's Viewed state on GitHub |
| `]u` / `[u` | Next/previous unviewed file; counts supported |
| `d` / `dv`, `dh` | Vertical / horizontal two-revision file diff |
| `D` | Entire PR in Diffview |
| `<CR>` | Toggle the CI/Commits/Changes heading; open CI details, commit details, a marked thread, or the PR head file |
| `gk` | Preview conversation near cursor; repeat to focus the popup |
| `gc` | Read/reply to threads on the selected file or marked diff line |
| `gc` / Enter inside Conversation | Read PR-wide history and write a PR comment; Enter on its heading toggles the section |
| `gC` | New PR conversation comment, immediate diff comment, or pending review comment |
| `gcn` / `gcr` / `gcp` | Open a contextual comment / review draft / PR conversation input directly |
| Visual `gC` | Comment on a continuous range of diff lines on one side |
| `gr` | Native review menu: start/resume, migrate, draft comments/summary, resolve, submit or discard |
| `gr R` / `gR` | Resolve / reopen the selected thread (also `gR` in the focused preview) |
| `gA` | Selected comment: reactions, edit/delete, or apply a suggested change |
| `gE` | Change the header field under the cursor; elsewhere open the metadata panel |
| `gra` / `grm` / `grr` | Open approval / comment review / change request input directly |
| `O` | Start or resume a review in Octo |
| `gf` / `gq` | Worktree file / changed files in quickfix |
| `gD` | Shared word-diff display settings |
| `gx` / `gy` | Browser at cursor / copy PR URL |
| `R` | Collapse all file diffs and refresh PR status |
| `?` / `q` | Key guide / close |

Native two-pane diffs opened by PR status's `d` / `dv` / `dh` / `ds` retain
that PR's exact repository, host and merge-base/head comparison. Both code panes
show `💬` thread counts, `📝 [pending]` draft counts and `✅` resolved counts at
their LEFT/RIGHT anchors. Range threads show their badge at the last line and
can be read anywhere in the range. This uses the captured PR association;
ordinary `Gdiff`, Status and Commit splits do not discover PRs.

| PR split key | Action |
|---|---|
| `gk` / `gc` | Preview conversation (repeat to focus) / read, reply or edit a pending draft |
| `gA` / `gR` | Comment reactions, edit/delete and suggestions / resolve or reopen |
| `]t` / `[t` (also `]C` / `[C`) | Next/previous comment across LEFT then RIGHT; counts, no wrapping |
| `gct` | All PR threads, including file-level, outdated and other-file threads |
| `gC` / `gcn` / `gcr` | Comment destination / immediate diff comment / pending review draft |
| Visual `gC` / `gcn` / `gcr` | Comment on a continuous code-line range within one PR diff hunk |
| `gcp` / `gr` | PR conversation input / existing native review menu |
| `gx` / `gp` | Browser for the selected thread or PR / return to PR status |
| `R` / `q` / `?` | Refresh comments/review state / close owned diff panes / key guide |

These actions use the same native composers and GitHub write guards as PR
status. Opening a preview creates no input or remote write. New inline comments
require lines in the captured PR patch; unrelated full-file lines are rejected.
Public badges require current-head GraphQL anchors; unavailable anchors keep
threads readable through `gct`. Current-head private drafts retain the existing
legacy-coordinate fallback. Added/deleted sides never receive invented anchors.
Refreshing rereads GitHub state asynchronously; successful comment/review writes
refresh the split too. A changed PR head or base removes badges and disables
coordinate-based actions until the diff is reopened from refreshed PR status.
The `gct` list remains available. Source title/description drafts are preserved.
Decorations belong only to the captured windows. Closing/replacing a pane,
editing its immutable content or `diffoff` cancels its PR attachment and restores
temporary keys/winbars. `q` preserves foreign windows added to the diff tab and
returns to the captured source window. Native diff navigation and word colors
keep their existing behavior. `tests/pr_split.lua` covers real Git snapshots
and mocked GitHub writes; `tests/pr_split_ui.py` checks actual displayed badges
and their isolation from ordinary windows.

The `?` guide groups editing, navigation, comparisons, review and panel actions.
Each action has its own row with aligned key aliases; Visual keys have a separate
section, using the same colored, wrapping help popup as the other panels.

Section jumps focus the first item of an expanded section or its heading when
collapsed/empty, preserving folds and unsaved text. `gU` reveals a hidden Repo
header while retaining CI's own fold state. These keys also navigate from the
editable draft; they do not fetch patches or refresh GitHub.

On read-only rows, `R` closes all file diffs before reloading, including files
hidden by a folded Changes section and expansions still loading their patches.
Section folds remain as selected. A selected diff row returns to its file
heading. Automatic refreshes preserve expanded diffs. Unsaved title/description
edits retain the existing discard-or-keep prompt; Keep cancels both collapse and
reload. In the editable title/description, `R` retains native Replace mode.

The editable PR title uses `GitPrTitle` (light cyan `#8fdbed` and bold in the
dotfiles theme), distinct from the title/description instruction heading.
Only its text uses this style. The title highlight follows edits and header
folding without inserting display labels
into the saved metadata or rerendering the panel on every keystroke.

`Conversation (n)` follows the editable description and defaults closed. Open
it with Enter / `o` / `=` / Tab, or `p` in the PR action menu. It combines
paginated PR-wide issue comments, public review summaries/results and GitHub
timeline activity in
chronological order, showing author, date and review state. Pending/private
summaries and empty COMMENTED wrappers around file comments are excluded;
approval/change-request/dismissal results remain visible even without a body.
File/diff comments stay in their existing Review threads routes and are not
copied into Conversation. Each item/body row carries its own browser target for
`gx`, independently of text that resembles a file or section heading.

With configured `render-markdown.nvim` and the `markdown` / `markdown_inline`
parsers available, the editable description and expanded Conversation bodies
render Markdown headings, links, tables and code blocks. Each body is parsed
independently, so an unfinished code fence cannot consume the next comment or
other sections. The title, instructions, author/date rows and diffs retain
their own presentation. Description edits and folds update the rendering
without changing stored text, undo or GitHub save content. The usual
`:RenderMarkdown toggle` applies; without the plugin/parsers, text stays plain.
The dotfiles renderer configuration adds `gitpr` support and suppresses its
extra signs to preserve the PR fold gutter.

`gc` or Enter on a Conversation item opens the normal PR comment composer with
immutable history; `gcp` also includes this history. The text input posts only
its draft through the existing PR-comment route. Read-only Conversation text
never enters the saved title/description, and its independent fold survives
refresh and other section toggles. `gk` there reveals the inline conversation;
`gR` does not resolve unrelated file threads. Read failures show an incomplete
section with available entries and source-specific errors, keeping diffs and
unsaved metadata usable. The timeline includes commits, force-pushes, merges,
close/reopen, draft/ready transitions and head-branch deletion/restoration.
Events occupy one compact read-only row; Enter or `gx` opens their browser
target. `gA` applies only to comments/review summaries, and `gR` does not resolve
events. The same activity rows appear in PR-comment composer history.

Conversation follows all paginated GitHub `timelineItems`, without an event-type
allowlist. File/review/commit-comment threads stay outside Conversation,
preserving the existing review separation; internal revision markers are omitted. It does not
sort activity by Git author/committer timestamps: a commit authored before a
review can have been pushed after it. Commit rows explicitly label their
displayed timestamp as `commit date`, not push time. The independent Commits
section still shows the current merge-base-to-head Git history. Timeline
node IDs distinguish activity items; comment/review references join the
existing REST records by node ID or public permalink, preserving their bodies,
reactions and action identities without duplicate entries. Newly observed
REST-only comments remain visible after the known timeline. A failed timeline
read shows `PR timeline unavailable` and keeps available comments/reviews and
diffs. Activity includes bot/Actions label changes, assignees, review requests
and removals/dismissals, title/base-branch edits, auto-merge/merge queues,
deployments/statuses, projects/milestones, related issues/PRs/commits,
locks, pins and other server-advertised events. Linked targets open with
Enter / `gx`. Workflow job logs and the latest check results retain the CI
section and native CI detail routes; they are not invented as timeline events.

Colors stay concentrated on event icons and target names. Labels use Type,
review requests blue, branches Special, projects Identifier, and references
link colors. Deployments use blue, with successful/pending/failed statuses in
green/yellow/red. Prose keeps Normal and dates stay subdued. The
`GitPrTimelineLabel`, `GitPrTimelineReview`, `GitPrTimelineBranch`,
`GitPrTimelineProject`, `GitPrTimelineDeployment` and `GitPrTimelineReference`
groups can be overridden by the theme.

The first timeline read per host discovers its supported event fields, so older
servers do not receive queries for absent types. If introspection is disabled,
the established event query is retained and additional event identities remain
readable through generic labels. Missing/deleted targets show placeholders;
partial GraphQL errors mark Conversation incomplete while keeping readable
items. API head and pagination checks still protect the displayed snapshot.

Keep a blank line between the title and description. Other normal editing keys retain
their meaning inside that region. The other metadata and diffs are read-only
when saving: protected edits must be undone. Failed saves preserve the draft;
saving checks that the remote title/description still matches the loaded version.
Refresh keeps edits made while the request was running; if the remote metadata
also changed, saving requires resolving that conflict by preserving the draft and
reloading. `R` outside the editable region offers to discard a dirty draft before
reloading; hidden PR buffers preserve drafts until explicitly closed.

Outside the title/description, `i` follows Status: expand the current file if
closed, then jump to the next file header or diff hunk and scroll it to the top.
Counts such as `2i` repeat that movement. Inside the editable region, `i` retains
normal insertion behavior.

The PR header uses Octo-style labeled rows for the repository, author, dates,
assignees, milestone, labels, reviewers, branches and change totals. Empty
metadata is omitted rather than showing `No …` placeholders. The Commits row
includes the snapshot's commit count, changed files, additions/deletions and a
five-cell green/red diffstat. Requested reviewers and people who submitted an
approval, change request or dismissed review carry
compact name/icon pairs on one `Reviewers:` row: green `✓` for approval, red `✗`
for changes requested, yellow `◷` for review required, and gray `⊘` for
dismissed. Comment-only participation does not add a reviewer or
overwrite a previous approval/change request. Explicit requests take precedence
and show the waiting icon. Private pending reviews do not add reviewers.
Checks are grouped by outcome with status symbols and exact browser targets.
`gE` on Labels, Assignees or Reviewers opens a searchable `vim.ui.select`
picker with current selections marked. Choose an item to add/remove just that
membership; the picker reopens for additional changes. Select Done or cancel
to finish. Empty fields can be changed through `gE` elsewhere or `M` in the PR
actions/repository GitHub menu. Review requests support users and `team:slug`;
completed review decisions remain visible independently of outstanding requests.
The detailed PR header uses `CI: … · Review: … · mergeable`.
For merged PRs it shows green `merged`, regardless of the mergeability value.
`checking` indicates an unknown mergeability decision, not merge execution progress.

Status commit rows show `hash date subject author`, with author names in `Type`
(the same yellow accent as Log). Status PR rows show title, branch, then `@author`.
Branches use the blue `GitBranch` accent, including PR From/Into refs and
Status header/worktree refs. PR numbers use green `GitPrPositive`; PR authors
use the same `Type` accent. Status PR rows insert a blue creation age (`1d`, `3h`,
`5m`, etc.) immediately after the PR number; missing creation dates omit the age.
Metadata fields use single-space separators, including Status headers/worktrees,
Branch columns and PR header details; spacing within subjects/paths is preserved.
The Status PR suffix retains labeled text with
tighter punctuation: `[CI:— Review:— conflicts]` or
`[CI:✓ 2 Review:approved mergeable]`. Status values retain their semantic colors.
The first line is `Repo: owner/name [ PR #N ] [STATE]`, followed immediately by
the available metadata. Header items align with the other blocks at column zero;
labels use `GitPrHeaderLabel` (DiagnosticInfo by default, `#7bb8c1` in dotfiles)
and the CI/review summary colors only the labels and present status values.
`CI` / `Review` stay blue; colons, separators and absent `—` values use Normal.
CI uses `✓ N` for all successful/neutral/skipped checks, `◷ N/T` for pending
checks and `✗ N/T` for failed checks (failures take precedence). Status values
are green/yellow/red respectively. Review shows `approved`, `review required`,
or `changes requested` in green/yellow/red; `—` means no aggregate GitHub review
decision, even if a comment-only review has been submitted. Normal `Merge: CLEAN`
state is omitted to keep the summary compact; BLOCKED/DIRTY and other additional
states remain. MERGEABLE concerns merge conflicts, while CLEAN also includes
passing commit status, so the two fields are not semantically identical.

Headers start expanded. On a read-only header row, `o`, `=`, or `<Tab>` toggles
the details; `>` / `<` expands/collapses them. The fold marker `▾` / `▸` lives in
a fixed sign gutter rather than the buffer text, keeping the first line aligned
with the other blocks. PR windows restore their original gutter options when
switching to another buffer. The collapsed header retains the repository and
PR number/state, with the editable title/description and
file diffs still visible. Header folding preserves unsaved metadata and file
expansion state and performs no Git/GitHub requests. `gx` on the first line's
repository name opens the repository; elsewhere on that line it opens the PR.
The CI/review summary and its check list finish the expanded Repo details,
after your pending/last review rows. CI results start collapsed and have their own
gutter marker. On the CI summary or a result row, `o` / `=` / `<Tab>` toggles
the results and `>` / `<` expands/collapses them; Enter on the summary also
toggles them. Results align at column zero without nesting indentation.
Collapsing Repo hides this CI block too, retaining its expansion state.
CI folding preserves drafts/file diffs, performs no requests, and survives refreshes.

Changes starts expanded and folds independently of Repo, Commits and each
file's diff. Its heading uses the same gutter marker and `o` / `=` / `<Tab>` /
`<CR>` controls; `>` / `<` opens/closes that section. Section folding retains
individual file choices, draft edits and the review-thread footer, and performs
no Git/GitHub requests. Refresh preserves the section state. `i`, file/hunk
navigation and `]t` / `[t` reveal a closed Changes section before moving.
Opening Changes does not expand every file; select file rows with Visual `>`
to expand multiple diffs together.

Unified diffs use the existing syntax/word-diff renderer. They compare the PR's
merge base with its head, independently of the checked-out branch or index.
PR refs are fetched under `refs/nvim-pr/<host>/<owner>/<repo>/<number>/`; fetched
SHAs must match the metadata before publishing a snapshot. Git diffs, review
state and comment/thread reads run concurrently, then publish one complete
layout. Matching private base/head refs skip the next network fetch after fresh
PR metadata confirms both SHAs. Refreshes reuse immutable diff/patch data when
the comparison is unchanged; expanded patches for changed revisions load in
the background before rendering. API state is always reread. Added, deleted,
renamed and binary files use the shared commit change model. Binary comparisons
open Diffview. Published threads use blue `💬` markers; private review drafts use
amber `📝 [pending]` markers. File headers always show `💬 current/total`:
`💬 2/5` means two published comments on non-outdated threads out of five
published comments in that file. Counts include replies, your own comments and
resolved threads, and stay the same when opening/closing diffs or reading comments.
If outdated status is unavailable, only the confirmed total is shown.
LEFT/RIGHT diff lines show the total published comment count at that position.
Both headers and diff lines add `🆕` for unread comments, independently of the
number. `📝` continues to count threads with private drafts. The thread summary keeps total thread counts and an
unread indicator. File/outdated threads remain available through the file header.
Opening a conversation or its preview marks its displayed comments read. Only other people's
published comments count as unread; own comments and private drafts do not.
Receipts persist locally per GitHub host/repository/PR/viewer across reopening
and restarting Neovim. New replies or changes to previously read comments become
unread on refresh. This state is independent of GitHub notifications and Octo.
The Conversation heading also shows `🆕` for unread comments, reviews or timeline
activity from other people. Revealing Conversation or opening its comment
composer marks the displayed history read; collapsing it retains receipts.
Comment, review and inline-comment IDs have separate receipt identities.
Receipt fingerprints use a fixed, versioned field order so closing/reopening
panels, changing worktrees or restarting Neovim preserves unchanged reads.
Older receipt hashes remain recognized across their original JSON key orders.

File review progress uses GitHub's Viewed state. Only a viewed file's path is
dimmed with `GitPrViewedFile`; change letters, file icons, diff syntax and
comment/draft/resolution colors remain visible. The Changes heading shows
`Viewed n/total`. `gF` on a file header or any of its diff lines toggles that
file on GitHub. Opening/expanding a diff never marks it viewed. `]u` / `[u`
skip viewed files, include files changed since their last review, support
counts, and stop at the first/last remaining file without wrapping or fetching
patches. They reveal a collapsed Changes section as needed.

Viewed status is paginated and reread with PR refresh, so browser/Octo updates
and GitHub's `DISMISSED` state restore the ordinary filename color. The toggle
rechecks the PR revision, viewer and file state, then displays only confirmed
API results. Repeated keys during an update do not duplicate it. Failures leave
diffs and unsaved metadata usable; unavailable reads show `Viewed unavailable`
and disable Viewed operations until a successful refresh. No per-file badge or
local Viewed cache is added. `gV` retains the configured pasted-range selection;
`]c` / `[c` retain hunk navigation. Comment navigation also works with `]t` /
`[t` inside the focused conversation preview; `]C` / `[C` remain aliases.

`]t` / `[t` (also `]C` / `[C`) lazily expand files and jump to comment anchors. A range thread is
one target; threads sharing a line share one preview. File/outdated comments use
their file header, and missing-file comments remain accessible at the summary.
Movement stops at the first/last target without wrapping. Navigation opens a
read-only cursor popup at the bottom of the conversation without creating an
input buffer or taking focus. `gk` opens the same popup and repeats to focus it
for scrolling; `gc` from the popup opens the reply editor. Moving away or leaving
the panel closes the preview.
Conversation history inserts blank separators only between comments and omits
trailing blank display lines, so the latest comment ends at the popup's bottom.
File-thread previews and reply histories sort comments by creation time and
place each comment's file/location and current resolved/unresolved state directly
above that comment, including outdated threads and interleaved replies. The
PR-wide Conversation retains GitHub's timeline order.

Inline blocks retain their `suggestion` language (including `suggestion:-N+M`)
and show a colored `-` / `+` diff, including removed code for deletion-only
suggestions. The shared Git syntax/word-diff highlighter uses the selected
display style and the source file's language within these owned ranges.
Original code comes
from the comment's historical `diff_hunk` and original side/line range, so moved
or outdated anchors never compare against today's file. If that patch does not
contain the complete selection, the original suggestion remains readable with
an explicit source-unavailable label. Display conversion preserves the stored
comment body and its edit/reply/apply targets. `gA` then `s` still opens the
existing application preview; local and GitHub application parse the original
suggestion, independently of the decorated history.

The thread editor puts its context and conversation in a separate
read-only Markdown panel above a body-only textarea. All composers use the same
immutable context panel, including new comments and review submissions. Locations
use `file:L20-L25 (RIGHT)` or `(LEFT)` for ranges and `file:L20` for a single line.
A blank line separates the location from the following context/history; previews
still end on the last comment without a trailing blank. Target
labels use `GitPrCommentContext`; shortcuts and summary requirements are displayed
only in window titles, using `GitPrCommentInstruction`. The `gk` cursor preview
also keeps its reply/focus/navigation/close shortcuts in its title. Input windows
are at most 80 columns wide and five lines
high, with wrapped text and scrolling for longer drafts.
Own messages and their author labels use `GitPrCommentSelf` (DiagnosticInfo by
default; dotfiles uses its existing light blue `#81a1c1`), others use
`GitPrCommentOther` (normal text with a contrasting author label). `Tab` switches
between history and input. `<C-s>` or `:w` sends the reply, and a failed send retains
the draft and history; sending or closing the input also closes the history.
A pending thread opens
its draft comment for editing instead of posting a public reply.
Review-specific REST listings may omit line numbers and diff sides. The existing
GraphQL thread read supplies current line/range/side anchors for both public and
pending badges, only when its head matches the displayed head. File-level and
outdated threads stay on file headers/the summary. Without GraphQL coordinates,
pending comments can use original coordinates only for the displayed revision. Private
replies remain accessible even when their public parent is absent; a failed
public-comment read does not hide successfully fetched private drafts.

`gA` on a Conversation comment, or a selected comment inside the focused preview
or composer history, opens the same comment action panel. On file/diff rows it
first lets you choose among the comments there. Reactions use all eight GitHub
types; choosing your existing reaction removes it, and choosing an absent one
adds it. Counts appear below each comment. Own published issue/inline comments
can be edited or deleted; deletion asks for confirmation. Own submitted review
summaries can be edited but not deleted. Writes reread the author/body before
mutation; a stale edit keeps its draft instead of overwriting newer text.

For an inline comment containing a fenced `suggestion`, `gA` then `s` opens a
diff preview. `l` applies it locally without staging, committing or pushing;
the worktree must be at the current PR head and the target file must have no
staged, saved or unsaved changes. Other local edits are preserved. `g` opens a
commit-message composer; `<C-s>` / `:w` creates a commit directly on GitHub's PR
head branch, including forks when you have permission. The server checks the
expected head SHA atomically. This remote route leaves the local checkout alone.
Current RIGHT-side line/range suggestions, including `suggestion:-N+M` ranges,
are supported; outdated, LEFT-side, binary and symlink targets are rejected.
Applying a suggestion does not automatically resolve its conversation.

`gC` opens a destination menu: `p` writes a PR conversation comment, `c` posts a
diff comment immediately, and `r` saves a private comment to a pending review.
`gcn`, `gcr` and `gcp` open these inputs directly, including Visual ranges.
`gcn` uses the diff line/file under the cursor, or the PR conversation outside
the file section. `gcr` requires a file/diff target; `gcp` always uses the PR
conversation. These shortcuts open drafts; `<C-s>` / `:w` still performs the write.
File headers target the whole file; diff lines target RIGHT for additions/context
or LEFT for deletions. Visual `gC` supports contiguous lines from one side of one
file. Markdown composers show the captured target and revision above the draft;
`<C-s>` or `:w` sends/saves it. New immediate diff comments are blocked while you have a pending
review so they cannot accidentally publish that review. PR conversation comments
can be posted independently.
Immediate diff posting creates an isolated pending review, adds the LINE/FILE
thread through GraphQL, then submits that single comment as COMMENT. It never
uses the standalone REST endpoint that rejects line/file payloads on some hosts.
If any step fails, local text and any saved pending draft remain available; inspect
the PR and `gr c` / `gr m` before retrying. A retry cannot adopt an existing pending
review. Submission verifies that the isolated review still contains only the
newly returned comment ID and its original body/path, then checks the full snapshot
again so drafts added or edited in another client are not published inadvertently.

In `gr`, `s` starts or resumes your GitHub pending review, `c` reads/edits draft
comments (`gX` deletes the selected draft after confirmation), and `b` saves a
review summary without submitting. `a`, `r` and `m` open
composers for approval, change requests and comment-only reviews; `<C-s>` or `:w` submits the
summary and pending comments together. With saved draft comments, `gr m` followed
by `<C-s>` submits them without an additional summary; the composer explicitly labels
the summary optional. Approvals can have an empty summary and no inline comments;
change requests need one. A comment-only review needs a summary or pending
comments. `x` discards the pending review and its comments after confirmation;
`o` continues in Octo. Both `O` and the GitHub menu's Octo review action resume an
existing review rather than unconditionally creating one.

All PR inputs accept `<C-s>` in Normal and Insert modes to send/save, including
unchanged empty review summaries; `:w` remains available. `<Leader>w` keeps its
configured `:update` behavior, which skips unchanged buffers.
While a comment/review request runs, an animated indicator appears at the right
edge of its input title; the title and shortcuts remain in place. Repeated saves
from either panel keep the one in-flight request, without posting again or showing
a submission error. Failure stops the indicator and restores the editable draft
and its title for an explicit retry; actual API errors are still reported.

`gra`, `grm` and `grr` open those submission composers directly after rereading
your review state, with the same identity, SHA and pending-draft guards.

`Your review` is hidden when the authenticated viewer has no pending review.
It displays a pending review even with zero comments, or a read/recovery error
that needs attention. Diff markers add `[pending]` for unpublished comments.
Submitted reviews appear in Conversation and as reviewer icons; there is no
separate `Your last review` row. The `Review: …` summary retains GitHub's
aggregate PR decision, independently of the viewer's own review.
GitHub owns saved drafts, so
reopening the panel recovers a review created here or in Octo. Each write rechecks
the viewer/review identity; comment edits and summary saves reject concurrent
body changes. Submission/discard also checks the full pending comment snapshot
so an unseen Octo edit is not silently submitted or removed.

The review-thread footer displays the number of published, unresolved GitHub
conversations, including outdated threads. Replies do not increase that count;
private draft threads are excluded. Resolution comes from paginated GraphQL
`isResolved` state and is independent of the local unread count. Reading a thread
does not resolve it. `gr R` or `gR` on a diff line or file header resolves the selected
published thread, or reopens it if already resolved; multiple threads open a picker.
The focused `gk` preview also accepts `gR`. Each operation rechecks the thread's
identity, current state and GitHub permission before writing, then refreshes the PR.
GitHub-change refreshes preserve an unsaved title/description and detect remote
metadata conflicts; explicit `R` retains its discard/reload confirmation.
Resolved threads add a green `✅` count beside the comment markers. Preview and
reply context show `✅ resolved` / `💬 unresolved` for each thread; the picker also
shows its state. This is separate from unread counts and pending review drafts.
Resolution read failures show `unresolved: unavailable` while retaining readable
comments and diffs.

Only the title / description accepts native text editing. Outside it, `a`, `I`
and other native editing keys do nothing; `i` keeps its next-diff navigation.
Edits spanning into protected metadata or diffs are restored with the last valid
draft, including paste, range operators and Insert-mode boundary crossings.

`GitPrPositive` highlights approval, successful CI/checks/Actions runs, mergeable
states, merged PRs and zero unresolved threads. It defaults to
`DiagnosticOk`; the dotfiles color scheme uses its existing green `#98be65`.

Saved pending reviews are shared GitHub state. Normal start/resume, draft additions
and submission keep your existing review ID, even when its commit is older than
the current PR head. A `review commit` hint identifies that earlier revision without
blocking the review. GitHub's individual outdated threads are a separate concept.
SHA migration is an optional custom action, never a prerequisite for continuation.

Diff comments and submissions verify the displayed PR head and base immediately
before writing, so a push after opening a composer requires refreshing the panel.
The existing review's creation SHA need not equal that displayed head.
GitHub does not allow approving your own PR; use `gr m` to submit comments instead.
Approval of another author's PR can have an empty summary. API requests explicitly
select the JSON/comfort-fade media types (as Octo does for line/range comments)
and REST version `2022-11-28`. Failed API responses show their validation reasons
alongside the CLI error, while keeping the composer editable.

Use `gr u` when you want to move saved drafts to the current head: preview with
`p`, then apply with `a`. Unchanged lines/ranges with unique surviving context
follow line shifts and
identified renames; file comments follow their file. Changed/deleted code,
ambiguous positions, targets outside the new PR diff and reply drafts require
explicit reattachment. Refreshing the panel only reads state.

When a draft needs a migration target, select a current diff line, Visual range
or file header and use
`gC m`, then choose the preserved draft. Moving a reply into a new thread needs
confirmation. The old review stays intact until every draft has a target.
Its comments and summary remain readable/editable while planning; remote edits
invalidate the plan rather than overwriting unseen changes.
Previewing or reattaching only prepares a local plan and does not block normal
review operations. Submitting the existing review clears its unused plan.

GitHub cannot retarget an existing review's SHA, so migration rebuilds your pending
review. Before deleting it, all bodies/anchors are saved to a private `0600` JSON
file under `stdpath('state')/git-pr-review-migrations/`. Its journal survives
Neovim restarts and is removed only after the replacement's complete comments and
summary are verified. Failed or uncertain deletion/creation/thread/summary writes
can be resumed with `gr u`; reconciliation avoids copying a draft twice. Another
push during recovery re-plans all preserved drafts, including ones not yet copied.
Unrelated reviews and externally changed/submitted reviews are not adopted.
Once an explicit migration starts deleting/rebuilding the review, ordinary
resume/add/submit actions require recovery via `gr u` before continuing, so an
incompletely copied review cannot be submitted. Recovery is never started automatically.

Failed requests retain editable local
drafts, and hidden composers keep them within the current Neovim session. Writes
are never automatically retried. If a network failure leaves posting uncertain,
check GitHub before retrying an immediate comment. Suggestions can be written as
Markdown; Octo remains available for its dedicated suggestion/review tools.

In PR status, `gx` on a CI check opens its actual job/check URL (including external
CI providers), and on the CI summary opens PR checks. CI represents all PR
checks, including external providers. GitHub Actions runs remain available
through `a` in the PR actions menu (`N` / `<Space><Space>`).
On a marked diff line `gx` opens the comment; elsewhere it
opens the PR. The `k` and `a` list panels also support `gx`/Enter for the selected
check or workflow run.

CI result rows open native details with Enter. The CI summary keeps Enter as its
fold toggle and `gx` as its PR-checks browser target. There is no new check popup;
`gk` keeps its conversation-preview behavior. `k` in the native PR action menu
reveals this same result list, preserving edited title/description text.

| CI screen | Key | Action |
|---|---|---|
| PR result / repository checks list | Enter | Open the selected check in a normal detail tab |
| Detail tab | Enter / `s` | Open the selected step log in a vertical / horizontal split |
| Detail tab | `R` | Refresh that check and discard cached logs; existing logs show an outdated notice |
| Detail tab | `a` | Rerun / cancel the containing workflow |
| Detail tab | `o` / `gx` | Open its validated web URL |
| Detail tab | `q` | Close owned CI windows and return to the captured source tab/cursor |
| Log split | `gf` | Open the source location in this diagnostic block |
| Log split | `R` | Retry with fresh download credentials |
| Log split | `q` | Close only that log window |

Details focus the first failed step. `v` keeps normal Visual selection. Titles
and section headings are bold; metadata labels, state badges, step names,
timings, links and annotation locations have separate highlights. Failed step
names use bold red text. Key hints follow configured action keys. Same-check tabs and same-step log windows
are reused. Different steps can be opened side by side; normal `/`, yank and
window commands work in the read-only `log` buffers. Foreign windows added to
a CI tab survive `q`. Requests are asynchronous and cancelled when their view
closes; there is no polling or disk log cache.

`a` in the CI detail view opens workflow actions: `r` reruns the whole workflow,
`f` reruns failed jobs, and `x` cancels the workflow after confirmation. These
actions support GitHub Actions and CircleCI and apply to the containing workflow,
not just the displayed job or step. A fresh check/job/run or pipeline identity
check precedes each write. Reruns require a finished workflow; cancellation
requires an active one. API permissions and `CIRCLE_TOKEN` apply as usual.
Successful requests refresh the details and invalidate old log caches.

Log `gf` recognizes `path:line:column` and `path:line` against the captured
repository root, independently of the current directory. Compiler/LuaLS
`warning`/`error` blocks with an `-->` location also work from their message,
blank separator and numbered code excerpt rows, including timestamped Actions
logs. Other paragraphs work when they contain one unambiguous location.
The source uses one reusable source tab per worktree root across CI checks and
different files, while an already displayed target is focused directly. Source
tabs use ordinary editor defaults (numbers, wrapping, status/sign columns and
folding), preserving the log. File switches retain unsaved buffers, even with
`nohidden`. A closed or user-repurposed source window is preserved/replaced as
appropriate; failed loads restore the previous buffer or remove the newly
created tab. Existing worktree files are editable when a configured
remote matches the CI repository. Foreign repositories and missing files open
a read-only Git object at the captured CI commit; a same-named file in an
unrelated worktree is not used. Missing objects, ambiguous blocks and paths outside the
repository do not open empty buffers. Runner-specific absolute path remapping
and Quickfix population are not implemented.

| Provider | Native details/logs | Fallback |
|---|---|---|
| GitHub Actions | Check output/annotations, verified workflow job, steps and zero-based step logs | A step-endpoint 404 returns **Job log · all steps**; unavailable/ambiguous jobs retain description and web link |
| CircleCI Cloud / configured Server | Verify numbered job, workflow/pipeline and repository/SHA; prefer v3 job steps with per-execution stdout/stderr | OAuth `gh/owner/repo` jobs use v1.1 actions and fresh signed output URLs when v3 is unavailable; unsupported App/server responses retain metadata and web link |
| Other Check Run / Commit Status | Status, description, available check output and annotations | Web link; native logs are unavailable |

GitHub uses existing `gh` authentication (`gh auth status`). Private Actions logs
require repository read access and Actions read permission. CircleCI uses the
`CIRCLE_TOKEN` environment variable and `curl`; no prompt asks for a token.
Without it, check rows and web navigation still work. V2/v1.1 requests use
Circle-Token, v3 uses Bearer authorization; signed output downloads receive no
API token. A job is never selected by name alone: duplicate names, reruns and
parallel executions retain separate identifiers. Status histories reduce to the
latest entry for each context during API enrichment. Opening details keeps the
source PR's captured head SHA; refresh the PR first to inspect a newly pushed head.

Optional configuration (set before opening a PR/detail buffer):

```lua
vim.g.git_ci = {
  circleci_host = 'circleci.com', -- bare HTTPS Server hostname when applicable
  timeout_ms = 30000,
  max_log_bytes = 2 * 1024 * 1024,
  -- log_hosts = { 'logs.example.com' }, -- extra trusted signed-output hosts
  -- github_api_version = '2022-11-28', -- override server-specific negotiation
  keys = {
    details = '<CR>', -- PR result entry; false restores browser Enter
    horizontal = 's', vertical = '<CR>', source = 'gf', refresh = 'R', actions = 'a', browser = 'o', close = 'q',
  },
}
```

Detail/log action keys can be disabled with `false` or remapped here. GitHub
Cloud defaults to API version 2026-03-10; Enterprise defaults to 2022-11-28.
HTTPS URLs are validated, web URLs omit query credentials, and CircleCI download
hosts are limited to the configured host, CircleCI/AWS storage or explicit
`log_hosts`. Redirects on CircleCI downloads are rejected. Auth failures,
permissions, missing/expired output, rate limits, malformed JSON and timeouts
have retry/fallback messages without raw headers or signed URLs. ANSI/control
sequences and configured environment-token values are removed from displayed
output, including a stream-leading UTF-8 BOM. A whole-job fallback uses
**Job log · all steps** and names the requested step as **Selected step**.
Step and whole-job logs open at the start of the body, including after loading,
retry and cached reopen; completion never takes focus from another window.
GitHub log buffers truncate at the byte limit; CircleCI downloads over
that limit stop with a size-limit message.

Provider and lifecycle checks:
`python3 tests/run.py ci_model ci_providers ci_circleci ci_transport ci_view -j 4`.
Fixtures cover nonmatching check/job IDs, rerun attempts, pagination, mixed
outcomes, latest statuses, CircleCI OAuth/App wire formats and parallel indexes,
expired signatures, tab/split ownership, drafts, cache invalidation and late
results. CircleCI API response shapes are checked against the
[official v3 reference](https://circleci.com/docs/api/v3) and
[circleci-cli v1.5.0 job client](https://github.com/CircleCI-Public/circleci-cli/blob/v1.5.0/internal/apiclient/job.go).
A live public GitHub Actions job also verified job/check association and the
clearly labeled whole-job fallback when the step endpoint returns 404, including
current gh CLI ANSI-output opt-in and display sanitization.
CircleCI authenticated production jobs and older/private Enterprise servers
still need environment-specific validation; unsupported identity/response shapes
fail to metadata and web navigation instead of substituting another job.

`:GitPrCreate` is the same **Create default PR** route as `N C`: prefill the
title with the latest commit subject and let you edit only that field, publish the current branch with
a regular, non-force push to its configured push remote, then run
`gh pr create --head ... --fill --title ...`. The body comes from commits;
base branch and remaining options use GitHub CLI defaults. It creates a ready
PR, uses the fork owner in `--head` when needed, and opens the resulting PR status.
Detached HEAD, push failures and unavailable GitHub defaults fail with a notice.

`:GitPrWorktree [number|URL]` asks only for a directory, fetches the current PR
head, creates `pr-<number>`, and opens Status in a new tab with a tab-local cwd.
The source branch, editing buffers and uncommitted changes remain available.
Existing branches/directories are never reset or overwritten. This is a local
review branch; it does not change the source repository's upstream/push policy.

GitHub commands require authenticated `gh`; Octo and Diffview commands use their
existing lazy-loaded plugins. API processes, PR fetches and patch reads are
asynchronous, and capture their original worktree before menus or input UIs open.
Remote writes use literal argv and JSON stdin. `tests/pr_model.lua`,
`tests/pr_view.lua`, `tests/pr_lifecycle.lua`, `tests/pr_refresh.lua`, `tests/pr_comments.lua`,
`tests/pr_reviews.lua`, `tests/pr_markers.lua`, `tests/pr_badges.lua`, `tests/pr_unread.lua`, `tests/pr_read_state.lua`,
`tests/pr_history.lua`, `tests/pr_review_migration.lua`,
`tests/pr_help.lua`, `tests/pr_commits.lua`, `tests/pr_loading.lua`, `tests/pr_timeline_events.lua` and `tests/github_actions.lua` exercise
real local Git repositories/worktrees with mocked GitHub responses and writes.
Live GitHub writes are not part of these checks.

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
`X` deletes local branches with `git branch -d` and remote-tracking branches
with `git branch -d --remote`, including mixed Visual selections. It removes
the local tracking ref; the branch on the remote server remains unchanged.
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
`Flogsplit`, and `Floggit` use its documented backend hooks to obtain repository context, run Git,
complete arguments, and open commits through the independent Gsplit command. `Git diff`/`Git show` output supports
cyclic hunk navigation (`]]`, `[[`), forward hunk movement (`i`), folds (`o`),
and Enter to inspect the file/commit.

`<Space><Space>` opens a separate Git action menu in status, log, branch,
reflog, worktree, commit-detail, and changed-files tree panels. It uses the file, commit, ref, reflog destination,
or worktree under the cursor, with no repeated
title/context header. The root offers Magit-style prefixes for cherry-pick
(`A`), apply variants (`v`), bisect (`B`), clone (`C`), commit (`c`), diff (`d`), pull (`F`), fetch
(`f`), initialization (`I`), log (`l`), remote (`M`), merge (`m`), submodule (`o`), push (`P`), rebase
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

In the Branch (`b`) menu, `u` sets upstream when unset and removes it when
configured, including when its remote-tracking ref has disappeared. `U` sets
or replaces upstream, with local/remote ref completion. Status and Log use the
checked-out branch; Branch uses the selected local branch. Remote/tag rows and
detached HEAD do not implicitly edit a local branch. `C` chooses a local branch
and opens its configuration menu without checking it out. Push (`P`), Pull
(`F`) and Fetch (`f`) also offer this `C` entry.

Branch configuration includes description (`d`), pull rebase mode (`r`), push
remote (`p`), repository pull mode (`R`), default push remote (`P`), and branch
creation defaults (`a m` / `a r`). Values are applied immediately to repository
local Git configuration and refresh matching panels; they are separate from
saved transient arguments. Choose `(unset)` or submit a blank text value to
clear a local override; canceling input leaves it unchanged. Previous-branch
checkout is now `b v`, leaving `b r` for rebase configuration. `b s` / `b S`
also expose spin-off/spin-out from Branch, operating on the checked-out branch.

The Remote (`M`) menu shows configuration for the branch's upstream remote,
falling back to `origin` or the first remote. `C` chooses a different remote.
`u` / `s` edit fetch/push URLs, `U` / `S` edit fetch/push refspecs, and `O`
sets tag fetching. For fields with multiple values, select an entry to edit
or remove it (blank), or select **Add value**; sibling values are preserved.
Remote removal uses `k`, with `x` retained as an alias. Configuration menus show
local overrides; clearing one allows inherited Git configuration to apply.

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
(`~2`, `^2`), explicit paths (`~1:other.txt`), and the `>~1` spelling also
work. The same relative objects are accepted by Gsplit/Gvsplit/Gtabedit, Gread,
and Gdiff commands, with completion for common forms.

Git commands run with argv, without shell interpolation. Commands needing prompts,
network interaction or an editor use a terminal job. `git.editor` supplies Git's
editor/sequence-editor command, opens the requested file in the same Neovim, and
resumes Git after that buffer closes (`:wq`). Explicit `commit -m`, `-F`, and
`--no-edit` run synchronously so chained status actions can observe failure.

`git-object://<worktree>//<revision>/<path>` buffers preserve repository/path
metadata; index buffers use `//0/<path>` (conflict stages use 1–3). Path
separators remain literal, with only percent, `#`, `?` and control characters
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

Git panel URIs use repository and target identity instead of an opening counter:
`git-commit://<worktree>//<hash>`,
`git-pr://<worktree>//<host>/<owner>/<repo>/pull/<number>`, and
`git-workflow://<worktree>//<operation>`. CI checks/logs, PR comment drafts,
blame/diff snapshots and rebase plans/messages follow the same rule. Non-default
merge-parent commit views add `/parent-<index>`. Percent, `#`, `?` and controls
are escaped so repository/path characters cannot become URI delimiters.
If the exact same target already owns a buffer, a separate view/draft adds
`?view=<buffer-id>`; simultaneous drafts and snapshots keep their own contents.
Closing and reopening an ordinary view does not introduce a new counter in its
URI. Older `git-commit://<worktree>/<serial>/<hash>` quickfix/jump/session entries
still reload. Git object index stages (`//0/`, `//1/` etc.) are meaningful Git
identities and retain their stage numbers.
`:Gwrite` additionally writes the worktree and stages it. Binary object editing
is rejected. Buffer repository context takes priority over cwd, including linked
worktrees. URI buffers can reload from quickfix and jump lists.

The supported surface is deliberately bounded: shell pipelines, alternate object
shorthand forms, line-range `Gclog -L` syntax and deprecated aliases are not
reproduced. Pass ordinary Git arguments to `Git` for other operations. The UI
uses `git*` filetypes and metadata, and publishes `GitChanged` after mutations.

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
`#ad5258`, respectively. These `GitExtSyntax*` groups belong only to
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
Missing or incompatible Tree-sitter highlight queries, including errors in
capture predicates, keep diff backgrounds and prefix overlays working. Failed
source coloring uses Normal foreground without blocking complete-source
comparison, later files, or loading completion. After a query or parser is
restored, refreshing the view restores available syntax colors without editing
the patch. Inside a hunk, space-prefixed status-like PHP constants or Lua table
keys remain source context rather than being mistaken for file headings.
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

Native two-pane split diffs use the same selected word-diff style. This includes
Status/Commit/Blame `d`, the `Gdiff` commands, `:Diff` (still opened by Gitsigns),
and Diffview's two-pane layouts. `gD` style changes in a Git panel update open
splits too; `require('git').setup({ word_diff_style = 'treesitter' })` can set the
initial preference. Diffview's logical `a`/`b` sides determine deletion/addition
colors even if its layout is rotated.

Native diff alignment, filler rows, folds, scrolling and `do`/`dp` remain in
place. Only the content highlights change: `treesitter` keeps source syntax
colors and paints confirmed token/word backgrounds, with a loading icon while
comparison is pending. It has no `▏` gutter because the separate panes already
identify before/after. Other styles use their ordinary line and word palettes.
Complete in-memory buffer contents are compared, preserving unsaved worktree or
index edits and PHP's enclosing context. Parsing, comparisons and paint plans
are asynchronous; the Rust worker and shared full-file comparison cache apply
here too. Style/foreground switches reuse ready trees/results. Source edits,
Diffview file switches, `diffoff` and window closure invalidate obsolete jobs.

Decorations are emitted only for drawn rows in the paired windows. Displaying
the same buffer in an ordinary window or another comparison does not share its
diff backgrounds. Native highlight mappings are restored on teardown; global
theme diff groups are unchanged. Three/four-pane conflict layouts retain their
native rendering. `tests/split_diff.lua`, `tests/split_diff_views.lua` and
`tests/split_diff_ui.py` cover selected styles, exact source coordinates,
native cancellation, real provider integration, null sides, and actual TUI
syntax/background composition and window isolation.

Outside inline panels, `]]` / `[[` cycle through next / previous hunks, wrapping
at either end; counts are supported. Native diff windows (Status/Commit/PR/Blame
splits, Gdiff, Gitsigns and Diffview, including conflict layouts) use Neovim's
own diff motions and settings. Standalone Git diff/show output and `diff`
buffers and the GitPatch collection pane cycle through unified hunk headers
across files. Opening a `diff` buffer or enabling native diff loads the Git
navigation module when needed. No hunks means no
movement. Temporary split mappings restore the buffer's ordinary keys when
entering it outside diff or after `diffoff`. Status/Commit/PR inline panels
retain their `]]` / `[[` file navigation.
`tests/diff_navigation.lua` and `tests/diff_navigation_cold.lua` verify wrapping,
counts, deletion filler, conflicts, diff options, key restoration and cold
entry points; the provider integration check verifies the actual split keys.

`tests/difftastic_word_diff.lua` compares both background levels against 170
checked-in cases captured from the installed Difftastic 0.71.0, covering calls,
wrapping, paired delimiters, added/removed syntax, strings/comments, Unicode,
JSON, Python, YAML, layout changes and a 100-line file with repeated edits.
Of these, 147 compare structural results and 23 compare text matching, including
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
`tests/syntax_highlight_portability.lua` checks PHP status-like context,
adjacent PHP/Lua files, actual query compile/predicate failures, missing/restored
parsers and `T` file headings. The syntax TUI check also verifies visible PHP
backgrounds and gutters with unavailable parsers and broken queries.
The same failure/recovery matrix covers Lua, JavaScript, TypeScript/TSX,
Python, Go, Rust, C/C++, JSON, YAML, TOML, Bash, Markdown, HTML, CSS, Ruby,
SQL and Vimscript, checking normal syntax captures, query compile/predicate
failures, missing queries/parsers, and restoration without patch edits.

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

An optional Rust worker accelerates structural search without changing the
Tree-sitter syntax colors, correspondence rules or background projection.
When `rustc` is on PATH, the first native availability check builds a missing or
outdated worker in the background. Lua handles comparisons while it builds;
later requests automatically use the completed worker. No Cargo or network
access is needed: the worker uses only Rust's standard library and does not
invoke `difft`.

Executables live in this repository's `.config/nvim/bin/<os>-<arch>/` directory:
`linux-x64/git-syntax-search`, `darwin-arm64/git-syntax-search` for Apple Silicon,
or `darwin-x64/git-syntax-search` for Intel Macs. Each machine builds for its own
OS/CPU. Changing `native/src/main.rs` triggers a rebuild when its modification
time is newer than the binary. A failed build is attempted only once per source
revision in an editor session and continues with Lua.

To build manually from this plugin directory (adjust the destination for your
machine):

```sh
mkdir -p ../../../bin/darwin-arm64
rustc --edition=2021 --crate-name git_syntax_search -C opt-level=3 -C lto=yes \
  -C codegen-units=1 -C panic=abort -C strip=symbols native/src/main.rs \
  -o ../../../bin/darwin-arm64/git-syntax-search
```

`syntax_native.config.backend` defaults to `auto`: when the release executable
exists, asynchronous comparisons send regions with at least 64 nodes to it.
Smaller regions use Lua. Missing, failed or incompatible workers use the Lua
search; both retain the 3,000,000-state limit and the same tie order.
At most two workers run at once, foreground requests take queue priority, and
closed/changed source pairs cancel queued or running requests. Waiting for a
worker suspends the comparison instead of repeatedly scheduling empty slices.
For an explicit Lua-only run, set
`require('git.features.syntax_native').config.backend = 'lua'`.
An alternative executable can be set with that module's `config.command`.
Lua-only mode and an explicit `config.command` bypass automatic building.
Automatic builds write a temporary file beside the executable and rename it
only on success; they do not create `native/target/` or install into `.cargo`.

Status and Commit also prepare up to eight file pairs after a 200 ms debounce,
including files whose diffs are still collapsed. This is enabled with an
available worker and `syntax_highlight.config.prefetch` (default `true`), and
prepares one file at a time. It uses the view's existing read session and parse
cache; resident prepared trees/results survive shared-LRU eviction. Opening a
prepared file needs only syntax queries and painting. Opening a file while its
comparison is pending joins that graph and promotes its queued worker request.
Blob identities and worktree fingerprints reject obsolete prepared sources;
refreshing the file list, changing style or unloading the view releases them.
Preparing a collapsed file does not add a spinner or highlights to its header.
`tests/syntax_native.lua` compares exact Lua/Rust ranges across all recorded
cases and covers missing/crashing/invalid workers and cancellation.
`tests/syntax_native_build.lua` checks Linux/Mac binary paths, asynchronous
rustc-only compilation, rebuilding, atomic publication and build-failure fallback.
`tests/syntax_prefetch.lua` checks the eight-pair bound, no repeat IO/parsing/search
on opening, shared pending work, stale-file rejection and unload cancellation.

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
start collapsed; patches are loaded only when expanded. The header shows the
tree, parent, author, committer, optional encoding fields, and commit hash using
the native Git syntax colors. Header metadata comes from
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

Convenience-command semantics are shared by `lua/git/objects.lua` (context,
paths and reloadable objects), `file_commands.lua` (writes, moves and removals),
`diff_commands.lua` (comparison targets and windows), and `history_commands.lua`
(quickfix/location history). `tests/fugitive_commands.lua` covers destination
protection, index-only removal, moved index metadata, contextual defaults,
range replacement, preview/split routing, conflict/merge comparisons, and
history scope/focus/rename following against behaviors verified with Fugitive.

- `git/fs.lua`: shared file fingerprints for status watchers and source/statistics caches.
- `git/queue.lua`: FIFO scheduling without moving the remaining entries on each dequeue.
- `status_reconcile.lua`: status row reconciliation using Neovim's native minimal
  diff over interned semantic keys. Unchanged blocks skip key/diff computation;
  changed headings keep their row anchors through in-line text updates. Section
  context is collected in one forward pass instead of rescanning preceding rows.
  The renderer caches entry-to-row lookup within each model and invalidates it
  when a warning or inline diff shifts entries.
- `index_flags.lua`: reads flags and stage-zero metadata in one binary-safe
  `ls-files -v --stage -z` pass, parsing metadata only for flagged records.
- `status_statistics.lua`: tracked diff statistics and per-view untracked line-count caches.
  Empty staged/unstaged sections skip their diff queries. Untracked counts are reused
  while file type, device/inode, mode, size, mtime and ctime match. Failed or racing
  reads are retried; leaving the untracked set or closing the view releases the cache.
- `commit.lua`: view, editable-message validation, navigation, actions, routing.
- `commit_model.lua`: immutable metadata, file inventory, statistics, lazy patches.
- `commit_rewrite.lua`: target amend, descendant replay, and Hard/Mixed removal.
- `history_rewrite.lua`: validation, rebase todo edits, stash ownership and rollback.
- `history_edits.lua`: log/status move, drop, parent fixup and index fixup.
- `commit_patch.lua`: pure file/hunk/line patch selection.
- `commit_actions.lua`: message editing, view restoration and discard confirmation.
- `commit_notes.lua`: optional Notes identity and row mapping.
- `change_display.lua`: file rows and statistics shared with status.
- `ci/model.lua`: normalized check identities/outcomes and URL validation.
- `ci/transport.lua`: bounded, redacted read-only gh/curl requests and pagination.
- `ci/service.lua`: exact check resolution, annotations and provider dispatch.
- `ci/github_actions.lua`, `ci/circleci.lua`: verified jobs, steps and logs.
- `ci/view.lua`: detail tabs, log splits, per-view session cache and cancellation.
- `panel_keys.lua`: normal key migration, contextual identifiers/help, and ordinary action choosers.

Run all standalone Lua and TUI checks from this directory with
`python3 tests/run.py -j 3`, or select checks by stem, for example
`python3 tests/run.py status_statistics_cache highlight_lifecycle`.
The runner isolates each check's state/cache directories, retains installed
plugins/parsers, handles the layout check's normal-startup requirement, and
returns a failure status for test errors/timeouts. Editor bridge checks need
local Unix sockets and TUI checks need a PTY.

Run an individual Lua check with
`nvim --headless --clean -u NONE -l tests/<name>.lua`.
`status_reconcile` owns row-edit boundary cases, duplicate/arbitrary semantic
keys, surviving anchors and unchanged-buffer short circuits. `status_partial`
checks row lookup after bulk diff changes and warning insertion;
`index_flags_view` also checks single-pass index inspection and unusual path bytes.
`status_statistics_cache` checks reuse, replacement/racing-read invalidation,
failed-read retries and view/repository ownership. `highlight_lifecycle` checks
FIFO/reentrant scheduling, coalesced read batches, and permanent cancellation
even when a view's validity predicate becomes true again. Source-read sessions
schedule one pending pump each; canceled reads cannot start their next side or
reenter the queue after reopening.

The structural checks intentionally share fixtures across distinct boundaries:
`difftastic_word_diff` checks algorithm output, `syntax_full_file_context` checks
complete-source projection and cache reuse in the view, and `syntax_native`
checks Lua/Rust equivalence. Their test-only byte-span normalization lives in
`tests/helpers/spans.lua`. Repeated-refresh stress belongs to
`syntax_word_diff_perf`; complete-file fixture checks perform one warm refresh.
`syntax_source_context` covers actual Git source acquisition, while canceled-read
reopening belongs to `highlight_lifecycle`. Generic Undo/Redo and stale-plan
guards belong to `history_undo`; `history_workflows` retains split/Undo integration
and patch collection. Keep these ownership boundaries when adding regressions.

Regenerate one structural oracle case with
`python3 tests/generate_difftastic_fixtures.py --case <filename>`; omit `--case`
to regenerate all cases using the generator's pinned Difftastic version.
The commit checks are `commit_view`, `commit_rewrite`, `commit_discard`, `commit_patch`,
`commit_notes`, `commit_lifecycle`, `commit_entrypoints`, and `commit_blob_return`
(`commit_blob_return` uses installed Gitsigns). Checks exercise the standalone
provider and its Gitsigns integration.
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
outside this plugin's scope. Issues and PR metadata/comments/review have the
native UI described above; Octo remains available as an alternative. WIP timing and
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
and highlighting remain independent. `GitReflogCheckpoint` defaults to
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
