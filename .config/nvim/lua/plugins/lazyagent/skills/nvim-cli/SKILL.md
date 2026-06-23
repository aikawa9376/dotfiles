---
name: nvim-cli
description: Tools for Neovim and filesystem interaction. Supports opening/closing files, managing the quickfix list, reading cursor context, and retrieving LSP diagnostics.
---

# nvim-cli

Interact with Neovim buffers and the filesystem. This tool handles both open buffers (with unsaved changes) and files on disk transparently.

## Global Options

- When launched from lazyagent, use `$LAZYAGENTBIN/nvim-cli-bridge` without `--server`. It is a shell wrapper around Neovim Lua and uses the `LAZYAGENT_NVIM_BRIDGE_*` environment to talk to the Neovim instance that started the agent, which works from sandboxed tool commands.
- `$LAZYAGENTBIN/nvim-cli` is the raw socket client. Use it only when you intentionally want socket mode; sandboxed tool commands often cannot connect to sockets.
- First try `nvim-cli-bridge` directly. If it is not on `PATH`, use `$LAZYAGENTBIN/nvim-cli-bridge`.

## Instructions

Use this skill when you need to:
- **"Quickfixに入れて" (Add to quickfix)**: Use `qf-add` to collect files for review.
- **"カーソルを合わせて開いて" (Open and focus cursor)**: Use `open` and `cursor` to understand the current editor state.
- **"コードを読んで" (Read code)**: Use `read` to get file content, prioritizing unsaved buffer content.
- **"診断結果を確認して" (Check diagnostics)**: Use `diagnostics` to see LSP errors/warnings.

### Available Commands

- **[content](references/content.md)**: Open/close files, read/write content.
- **[diagnostics](references/diagnostics.md)**: Get LSP feedback for files or projects.
- **[quickfix](references/quickfix.md)**: Manage the Neovim quickfix list (e.g., "Add these files to qf").
- **[system](references/system.md)**: Shell commands, git operations, and raw Ex commands.
- **[cursor](references/cursor.md)**: Get context around the current Neovim cursor ("Where am I?").
- **[connector](references/connector.md)**: Run connector.nvim context and SQL commands through the active Neovim instance.
- **[terminal](references/terminal.md)**: List and capture Neovim builtin terminal buffers.

## Guidelines

- **Recursive Reading**: When exploring a new project, use `read` on a directory to get a full view of the code.
- **Transparent Buffers**: The tool automatically handles unsaved changes in Neovim buffers.
- **Verification**: Use `diagnostics` after edits to check for errors reported by the editor's LSP.
