---
name: nvim-cli
description: Interact with the active Neovim instance for editor-specific context and actions, including unsaved buffers, cursor or window state, quickfix, terminals, and LSP diagnostics. Use when direct Neovim manipulation is requested or when required context is unavailable from files alone. Do not use for ordinary repository file reading or routine validation.
---

# nvim-cli

Interact with the active Neovim instance. The tool can access editor state such as unsaved buffers, windows, cursor position, quickfix entries, terminals, and LSP diagnostics.

## Global Options

- When launched from lazyagent, use `$LAZYAGENTBIN/nvim-cli-bridge` without `--server`. It is a shell wrapper around Neovim Lua and uses the `LAZYAGENT_NVIM_BRIDGE_*` environment to talk to the Neovim instance that started the agent, which works from sandboxed tool commands.
- `$LAZYAGENTBIN/nvim-cli` is the raw socket client. Use it only when you intentionally want socket mode; sandboxed tool commands often cannot connect to sockets.
- First try `nvim-cli-bridge` directly. If it is not on `PATH`, use `$LAZYAGENTBIN/nvim-cli-bridge`.

## Instructions

Use this skill when the task depends on the state of the active Neovim instance or requires changing that state. Typical cases include:

- **"Quickfixに入れて" (Add to quickfix)**: Use `qf-add` to collect files for review.
- **"カーソルを合わせて開いて" (Open and focus cursor)**: Use `open` and `cursor` to understand the current editor state.
- **Unsaved buffer context**: Use `read` when the on-disk file may differ from the active buffer.
- **"診断結果を確認して" (Check diagnostics)**: Use `diagnostics` to see LSP errors/warnings.

Do not use it merely to read files available on disk or to run routine post-edit checks.

### Available Commands

- **[content](references/content.md)**: Open/close files, read/write content.
- **[diagnostics](references/diagnostics.md)**: Get LSP feedback for files or projects.
- **[quickfix](references/quickfix.md)**: Manage the Neovim quickfix list (e.g., "Add these files to qf").
- **[system](references/system.md)**: Shell commands, git operations, and raw Ex commands.
- **[cursor](references/cursor.md)**: Get context around the current Neovim cursor ("Where am I?").
- **[connector](references/connector.md)**: Run connector.nvim context and SQL commands through the active Neovim instance.
- **[terminal](references/terminal.md)**: List and capture Neovim builtin terminal buffers.

## Guidelines

- **Transparent Buffers**: The tool automatically handles unsaved changes in Neovim buffers.
- **Verification**: Use `diagnostics` when the user requests editor diagnostics or LSP state materially affects the task.
