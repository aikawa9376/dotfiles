local M = {}

function M.run()
  local McpServers = require("lazyagent.acp.mcp_servers")
  local servers, errors = McpServers.normalize({
    local_tools = { command = "env", args = { "node", "server.js" }, env = { TOKEN = "secret", MODE = "test" } },
    remote = { url = "https://example.test/mcp", headers = { Authorization = "Bearer token" } },
    disabled = { enabled = false, command = "missing" },
  })
  assert(#errors == 0 and #servers == 2, "Zed context_servers normalized")
  assert(servers[1].command == vim.fn.exepath("env"), "stdio command resolved to absolute path")
  assert(vim.deep_equal(servers[1].env, {
    { name = "MODE", value = "test" }, { name = "TOKEN", value = "secret" },
  }), "stdio env map converted to ACP list")
  assert(servers[2].type == "http" and servers[2].headers[1].name == "Authorization", "HTTP server normalized")

  local merged = McpServers.merge({ shared = { command = "env", args = { "global" } } }, {
    shared = { command = "env", args = { "agent" } },
  })
  assert(#merged == 1 and merged[1].args[1] == "agent", "agent MCP config overrides global server")
  assert(#McpServers.for_capabilities(servers, {}) == 1, "stdio is always supported")
  assert(#McpServers.for_capabilities(servers, { http = true }) == 2, "HTTP capability enables remote server")
end

return M
