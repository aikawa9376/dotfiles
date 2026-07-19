local M = {}

function M.run()
  local integration = require("lazyagent.integrations.mcp")
  local opts = { mcp_mode = true }
  integration.setup(opts)
  assert(opts._mcp_url == nil, "plugin setup must not start MCP server")
  assert(integration.ensure_started({ mcp_mode = false }) == false, "disabled MCP mode stays stopped")
end

return M
