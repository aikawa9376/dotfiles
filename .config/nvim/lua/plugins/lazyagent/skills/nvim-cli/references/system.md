# System Operations

Tools for shell and git interaction.

## Commands

### shell "<cmd>"
Execute a shell command and get stdout/stderr.
```bash
nvim-cli shell "ls -la"
```

### diff
Get the current git diff of the project.
```bash
nvim-cli diff
```

### exec "<cmd>"
Execute an Ex command directly in Neovim.
```bash
nvim-cli exec "colorscheme desert"
```

## Usage Note

Use `shell` for tasks like running tests or building the project. For code verification, prefer using `diagnostics` first as it is generally faster and integrated with the editor's LSP.
