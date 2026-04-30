# lazyagent TODO

## High priority

- Isolate instance-scoped resources more thoroughly.
  - Extend PID/session namespacing beyond ACP transcripts and tmux pool names.
  - Audit hook temp files, cache keys, and other shared runtime state for multi-instance collisions.

- Reduce reliance on global config rewrites.
  - Avoid mutating global Cursor/Copilot MCP or hooks config when a per-session or per-project path is possible.
  - Revisit how lazyagent injects MCP config so multiple Neovim instances can coexist safely.

- Add multi-instance lifecycle regression coverage.
  - Same repo + same branch + same agent across two Neovim instances.
  - Close one instance/session and verify the other remains connected and visually correct.

## Medium priority

- Review removal candidates before the next cleanup pass.
  - Legacy `prompts`: non-interactive callback agents are still exposed, but current usage appears centered on interactive/ACP agents. Remove if no personal workflow depends on custom Lua prompt handlers.
  - `builtin` backend: useful as a tmux-free fallback, but it is much less capable than `tmux`/ACP and increases backend surface area. Remove if tmux/ACP are mandatory for this plugin.
  - MCP web UI / `:LazyAgentQR`: convenient for mobile/LAN control, but it pulls in web UI, QR, and host exposure concerns. Remove if this is not actively used.
  - `auto_follow`: watches filesystem changes and opens edited files automatically. It adds platform-specific dependencies (`fswatch`/`inotifywait`) and polling fallback complexity. Remove if ACP edit hooks and quickfix are enough.
  - Global Cursor/Copilot config rewrites: currently convenient but risky with multiple Neovim instances and shared global config. Replace with per-session/per-project config first; remove direct global mutation if the CLIs support scoped config.
  - Hardcoded scratch keymap fallbacks (`<C-j>`, `<C-k>`, number keys): useful for this dotfiles workflow, but plugin defaults should stay configurable. Remove hardcoded extras once all desired keys are supplied through `scratch_keymaps` / lazy.nvim `keys`.

- Unify ACP command source handling.
  - Keep one shared API for visible slash commands across completion, palette, footer, and reports.
  - Apply the same model to `@` completions if possible.

- Add a `:LazyAgentDoctor` diagnostic command.
  - Show PID, backend, ACP session ID, transcript path, tmux pool/session names, MCP URL, and command source breakdown.

- Improve footer observability.
  - Surface more debug-friendly metadata such as transcript path/session identity when useful.
  - Keep the compact default view, but consider a richer debug mode.

## Nice to have

- Add an explicit debug mode for session/resource tracing.
  - Log resource allocation and teardown for ACP, tmux panes, transcripts, and MCP wiring.

- Document multi-instance behavior and limitations.
  - Clarify what is isolated per instance, per repo, and globally.
