# Diagnostics

Retrieve LSP feedback from Neovim.

## Usage Scenarios
- **"エラーがないか確認して"**: Check for LSP diagnostics (errors/warnings) in the project.
- **"診断結果を取得して"**: Get the current LSP state for a specific file or the entire session.

## Commands

### diagnostics [path]
Get LSP diagnostics. If a path is specified, it returns diagnostics for that file/directory. If omitted, returns all diagnostics for the current session.
```bash
# Get all diagnostics
nvim-cli-bridge diagnostics

# Get diagnostics for a specific file
nvim-cli-bridge diagnostics src/main.rs
```
