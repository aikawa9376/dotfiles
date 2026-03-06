#!/bin/bash
MCP_URL=${LAZYAGENT_MCP_URL:-$(cat "$(dirname "$0")/../mcp.url" 2>/dev/null)}
[ -z "$MCP_URL" ] && printf '{}' && exit 0
input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.toolName // .tool_name // .hook_event_name // empty' 2>/dev/null)
case "$tool" in edit|create|write_file|replace|afterFileEdit) ;;
  *) printf '{}'; exit 0 ;;
esac
curl -sf -X POST "$MCP_URL" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"open_last_changed","arguments":{}}}' \
  > /dev/null 2>&1 || true
printf '{}'
