---
name: lazyagent
description: Operate LazyAgent-specific workflows, including communication with live agents by stable UUID and designing task-specific LazyAgent Teams. Use when the user references LazyAgent agents, agent refs, inter-agent handoffs, or `.lazyagent/teams.json`. Do not use for ordinary tmux pane control.
---

# LazyAgent

Route the request to only the relevant workflow:

- For live-agent discovery, `agent:UUID` resolution, or sending a request to another LazyAgent, read [communication](references/communication.md).
- For creating or refining `.lazyagent/teams.json`, choosing roles, or preparing a Team launch, read [teams](references/teams.md).

If a request needs both, read communication first for existing-agent state, then teams for catalog changes. Team runtime delegation and reporting use their native MCP tools; do not substitute generic agent messaging for Team hierarchy operations.
