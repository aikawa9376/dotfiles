# Communication

Use LazyAgent's parent-Neovim bridge so cross-agent communication works even when the current ACP session does not expose LazyAgent as a native MCP server.

## Workflow

1. Discover current targets before sending:

   ```sh
   "$LAZYAGENTBIN/nvim-cli-bridge" lazyagent-agent list
   ```

2. Match the requested target against `live_agents[].ref`, title, provider, workspace, and team metadata. Prefer an exact `agent:<thread-id>` supplied by the user. Do not guess when multiple live agents match.
3. Send only when the user requested communication or when it is an authorized coordination step in the current task:

   ```sh
   "$LAZYAGENTBIN/nvim-cli-bridge" lazyagent-agent send 'agent:<thread-id>' 'Message text'
   ```

4. Treat a JSON result with `success: true` and `accepted: true` as delivery acceptance. Report errors without silently switching identities or targets.

The helper calls the same `get_agent_status` and `send_to_agent` handlers published by LazyAgent's MCP server. New LazyAgent sessions also identify the sender through `LAZYAGENT_SESSION_KEY`, allowing the recipient to reply by stable agent ref.

## Boundaries

- Do not replace an `agent:<thread-id>` with a tmux pane ID. Pane delivery loses stable identity and reply routing.
- Do not use this helper for `team_delegate`, `team_report`, or Team hierarchy changes; use the Team MCP workflow.
- If the bridge environment is unavailable, state that the current process was not launched by LazyAgent. Do not search arbitrary Neovim sockets or panes as an implicit fallback.
