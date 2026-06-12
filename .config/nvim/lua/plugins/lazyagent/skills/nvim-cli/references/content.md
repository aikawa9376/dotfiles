# Content Operations

Tools for reading and modifying files or directories, and managing Neovim buffers.

## Usage Scenarios
- **"ファイルを開いて"**: Open one or more files in Neovim buffers.
- **"コードを読んで"**: Read content from a file or directory recursively.
- **"ファイルを閉じて"**: Close buffers for specific files.

## Commands

### read <path>
Read a file or directory. If a directory is specified, it returns contents of all files recursively.
```bash
# Read a single file
$LAZYAGENTBIN/nvim-cli-bridge read src/main.rs

# Read a directory recursively
$LAZYAGENTBIN/nvim-cli-bridge read src/
```

### write <path> [--start <line>] [--end <line>] <lines...>
Write or replace lines in a file. If `--start` and `--end` are provided, it replaces the specified range (0-indexed).
```bash
# Replace whole file
$LAZYAGENTBIN/nvim-cli-bridge write README.md "Line 1" "Line 2"

# Replace lines 10 to 20
$LAZYAGENTBIN/nvim-cli-bridge write src/main.rs --start 10 --end 20 "New line 10" "New line 11"
```

### open <files...>
Open files in Neovim.
```bash
$LAZYAGENTBIN/nvim-cli-bridge open src/main.rs src/tools.rs
```

### close <files...>
Close specific files in Neovim (deletes their buffers).
```bash
$LAZYAGENTBIN/nvim-cli-bridge close src/main.rs
```
