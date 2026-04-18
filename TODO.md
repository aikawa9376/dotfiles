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
