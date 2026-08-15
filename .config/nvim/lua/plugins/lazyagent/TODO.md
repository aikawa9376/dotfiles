# lazyagent TODO

> ACPの機能拡張、Zed相当化、thread/review/worktreeの実装計画は
> [ACP_ROADMAP.md](ACP_ROADMAP.md) で管理します。
>
> ACP安定化とrelease gateはObsidian `notes/LazyAgent ACP安定化/docs/acp-stabilization/README.md`を正とします。以下は安定化仕様に吸収されていない一般保守だけを未完として扱います。

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

- Harden ACP memory/resource teardown around close and conversation flows.
  - Investigation notes:
    - `LazyAgentClose` and `LazyAgentConversation` can release the visible pane/buffer while still retaining Lua-side memory through `state.session_views` snapshots.
    - ACP runtime/session capture previously copied heavy state such as `conversation_timeline`, `tool_timeline`, and related ACP metadata into saved snapshots.
    - Transcript clearing reduced file contents but did not always clear all in-memory state symmetrically (`pending_switch_history`, runtime copies, append timers, view state).
    - `close_all_sessions()` already cleaned `session_views`, but single-session close paths were weaker and could leave retained snapshot/state references behind.
  - Current mitigation:
    - Compact ACP snapshots before storing them in runtime session views.
    - Purge agent-specific saved snapshots on single-session close/force-close.
    - Clear ACP timeline state and release append timers/view state when clearing transcripts or killing panes.
  - Follow-up tasks:
    - [x] Add repeatable lifecycle regression coverage, including 50-cycle open/close loops (LA-STAB-08/09).
    - [x] Audit teardown symmetry across ACP close, activation failure, process exit, provider switch, resession, hydration, permission, and view paths (LA-STAB-09 resource ownership report).
    - [x] Add owner-attributed debug visibility for clients, callbacks, timers, permissions, hydration, sessions, transcripts, terminals, child processes, buffers, and views (LA-STAB-09).
    - [x] Keep runtime/debug snapshots compact by default and expose full timelines only through explicit options (LA-STAB-09).

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

- Expand doctor diagnostics beyond ACP.
  - `:LazyAgentACPDoctor` covers the active ACP session state.
  - Add a global `:LazyAgentDoctor` for PID, backend, tmux pool/session names, MCP URL, non-ACP sessions, and command source breakdown.

- Improve footer observability.
  - Surface more debug-friendly metadata such as transcript path/session identity when useful.
  - Keep the compact default view, but consider a richer debug mode.

## Nice to have

- Add an explicit debug mode for session/resource tracing.
  - Log resource allocation and teardown for ACP, tmux panes, transcripts, and MCP wiring.

- Document multi-instance behavior and limitations.
  - Clarify what is isolated per instance, per repo, and globally.
