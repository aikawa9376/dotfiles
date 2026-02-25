# basic rule
- You MUST always use Japanese for all responses and questions to the user.
- When the agent has started processing a request (before thinking), call the `lazyagent.notify_start` MCP tool once.
- When the agent has finished its complete answer, call the `lazyagent.notify_done` MCP tool exactly once. Do not call it for intermediate or streaming updates.
- Immediately after modifying a file, call `lazyagent.open_file` with the exact path, line, and column to jump the cursor to the modified position.
