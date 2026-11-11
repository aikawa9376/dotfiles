# Neovim virtual-line / conceal crash

`neovim-virtual-lines-conceal.patch` fixes `decor_virt_lines()` in Neovim
0.13-dev. Apply it to a Neovim source checkout, not a plugin checkout:

```sh
git -C /path/to/neovim apply /home/aikawa/dotfiles/.config/nvim/patches/neovim-virtual-lines-conceal.patch
```

The function traversed the marktree while calling conceal providers and fold
expressions. Tree-sitter's conceal provider can clear and recreate persistent
extmarks during that callback, merging or splitting nodes under the live iterator.
The patch snapshots mark identities before callbacks and looks up the current
decoration afterward. It preserves virtual lines and native conceal behavior.

The standalone regression needs no plugins or parsers. Run it in a separate
process with core dumps disabled: the unpatched binary can crash.

```sh
ulimit -c 0
/path/to/patched/nvim --headless --clean -u NONE -l /home/aikawa/dotfiles/.config/nvim/tests/marktree_virtual_lines.lua
```

The regression covers persistent conceal replacement across 600 rows and virtual
marks deleted/replaced by a provider. It fails with SIGSEGV on installed
`v0.13.0-dev-2079+gff3b698e30` and passes with the patch. The matching Neovim
decoration suite passed 201 tests (one skipped), and the dotfiles Inkstone TUI
integration passed. The separately captured November 11 core contains an
assertion in `marktree_itr_next_skip` about a child's parent pointer. Its original
executable was replaced, so that historical crash's complete stack cannot be
reliably symbolized; the saved transcript has not been replayed as an exact
reproduction.

This directory archives the patch and regression test. They are not applied
automatically, and the installed Neovim executable has not been changed.
