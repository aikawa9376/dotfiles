---
name: nvim-cli
description: Interact with the active Neovim instance for editor-specific context and actions, including unsaved buffers, cursor or window state, quickfix, terminals, and LSP diagnostics. Use when direct Neovim manipulation is requested or when required context is unavailable from files alone. Do not use for ordinary repository file reading or routine validation.
---

# nvim-cli

Interact with the active Neovim instance. The tool can access editor state such as unsaved buffers, windows, cursor position, quickfix entries, terminals, and LSP diagnostics.

## Connection and target selection

- Use `$LAZYAGENTBIN/nvim-cli`, or `nvim-cli` on PATH. The native binary selects the parent's file bridge from injected `NVIM_CLI_BRIDGE_*` (legacy `LAZYAGENT_NVIM_BRIDGE_*` also works). No extra Neovim process is started.
- With no target option, operate on the parent that launched the agent. Do not pass `--server` just to repeat inherited context: it forces RPC in auto mode.
- `instances` returns JSON with instance ID, PID, cwd, current path, transport, parent marker and reachability. Linux also discovers same-user Neovim processes and owned listening sockets. `instances --no-probe` only reads metadata.
- To operate on a different editor, use `--instance <exact-id> <command>` on each call. Choose the intended editor from the returned metadata. Never guess a target or silently fall back when it is unavailable.
- `--server <socket>` explicitly selects RPC; socket syscalls may be restricted by the sandbox. Discovery does not grant permission to connect. `--transport rpc|bridge` forces a transport.
- `--timeout-ms` defaults to 15000. A timed-out mutation may already have executed; inspect state before retrying.

Start with `context` for cursor surroundings, buffers (including modified state), windows, diagnostics and LSP clients in a single request. Use `buffers` for just buffer metadata.

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
