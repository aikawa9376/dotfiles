# Quickfix Operations

Manage the Neovim quickfix list.

## Usage Scenarios
- **"Quickfixに入れて"**: Add files to the QF list for batch processing or review.
- **"一覧に追加して"**: Add multiple files at once.

## Commands

### qf-add <files...>
Add one or more files to the Neovim quickfix list. Each file is added with a default line number of 1.
```bash
nvim-cli qf-add src/main.rs src/tools.rs
```

### qf-remove <files...>
Remove specified files from the Neovim quickfix list.
```bash
nvim-cli qf-remove src/main.rs
```
