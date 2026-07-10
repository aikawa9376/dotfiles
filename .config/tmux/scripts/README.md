# tmux scripts

## agentmux

`agentmux` is a small tmux popup dashboard for agent-oriented panes. It keeps
tmux as the multiplexer and adds a Herdr-like pane picker for Codex, Claude,
opencode, and other command-line agents.

Open it from tmux:

```tmux
M-a
prefix a
```

Actions inside the dashboard:

| key | action |
| --- | --- |
| `enter` | focus the selected pane |
| `ctrl-g` | refresh the list immediately |
| `alt-c` | split a new `codex` pane |
| `alt-l` | split a new `claude` pane |
| `alt-o` | split a new `opencode` pane |
| `alt-n` | prompt for a custom command and split it |
| `ctrl-s` | send one prompt line to the selected pane |
| `ctrl-r` | respawn the selected pane |
| `ctrl-k` | kill the selected pane |
| `ctrl-m` | mark the selected pane as an agent |
| `ctrl-u` | clear agent metadata from the selected pane |

Pane ordering is agent panes first, then ordinary panes. Within each group the
order is `session`, `window`, and `pane` ascending.

The list shows the status source before the last visible line. `native:*` is an
explicit status published by an integration; `ui:*` comes from the currently
visible TUI; `process:*` is a process fallback. This makes incorrect guesses
easier to diagnose.

Agent detection uses the foreground command, full TTY process arguments, tmux
pane options, and the currently visible TUI. Command names are matched on word
boundaries, so unrelated processes such as `polybar example` are not mistaken
for the `amp` agent. Manual marks are stored as tmux pane options:

```sh
@agent_kind
@agent_name
@agent_command
```

Use `prefix A` to mark the current pane directly.

Status detection is best effort:

- `working` means the visible agent UI has an active indicator such as
  `esc to interrupt`, or a native integration published a running state.
- `blocked` means the visible UI requests approval/input, or a native
  integration published a waiting state.
- `idle` means the agent is alive but its input prompt is ready (or no active
  indicator is present).
- `done`, `dead`, and `unknown` cover explicitly completed, exited, and
  unobservable agents.

LazyAgent ACP publishes its internal `thinking`, `waiting`, and `idle` states to
the enclosing tmux pane, so it does not rely on transcript words such as
`blocked`. The published options include:

```sh
@agent_status
@agent_status_at
@agent_status_message
@agent_status_pid
@agent_status_owner
```

Other tools can publish native status through the CLI. A positive TTL makes a
temporary status automatically fall back to UI detection:

```sh
agentmux status %25 working "prompt sent" 15
agentmux status %25 blocked "approval required"
agentmux clear-status %25
```

The popup needs `fzf`; live refresh additionally uses `curl` and util-linux
`script`, and falls back to `ctrl-g` when either is unavailable. While the popup
is open, a private tmux control-mode client receives pane output and topology
events. Pane output refreshes only the selected preview (coalesced to at most 20
updates/second), and rate-limits the heavier status/list reload to at most four
updates/second.
Session/window/pane changes reload the list immediately. There is no refresh
polling: when tmux is quiet, agentmux does no refresh work.

`fzf` only renders the dashboard and accepts those event-driven refresh
actions. A list reload takes one process snapshot and captures visible text only
for recognized agent/editor panes, rather than capturing every tmux pane.
