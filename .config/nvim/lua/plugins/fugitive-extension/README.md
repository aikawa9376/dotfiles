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
commit hash, using the native Git syntax colors. Help is available through g?.

Clean commit buffers use Fugitive's `bufhidden=delete` lifecycle: they disappear
from bufferline when no window displays them. Merely focusing another window does
not delete a still-visible commit. Unwritten message edits are kept when hidden.
Deleted commit URIs reload on reentry. Bufferline displays the short commit hash,
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
`commit_notes`, `commit_lifecycle`, and `commit_entrypoints` (the last uses installed vim-fugitive).
