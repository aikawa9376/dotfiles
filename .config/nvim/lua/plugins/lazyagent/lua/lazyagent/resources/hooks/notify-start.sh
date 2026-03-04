#!/bin/bash
MCP_URL=$(cat "$(dirname "$0")/../mcp.url" 2>/dev/null)
[ -z "$MCP_URL" ] && printf '{}' && exit 0
curl -sf -X POST "$MCP_URL" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"notify_start","arguments":{}}}' \
  > /dev/null 2>&1 || true
printf '{}'
