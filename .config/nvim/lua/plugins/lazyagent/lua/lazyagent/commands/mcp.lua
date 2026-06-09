local M = {}

local state = require("lazyagent.logic.state")
local qr = require("lazyagent.web.qr")

local ANDROID_MIC_HINTS = {
  "To enable mic on Android Chrome:",
  "chrome://flags/#unsafely-treat-insecure-origin-as-secure",
  "Add the URL above, then Relaunch",
}

function M.register(create)
  create("LazyAgentQR", function()
    local mcp_url = state.opts and state.opts._mcp_url or ""
    local port = mcp_url:match(":(%d+)/")
    if not port then
      vim.notify("LazyAgentQR: MCP server not ready yet", vim.log.levels.WARN)
      return
    end

    local url = "http://" .. qr.local_ip() .. ":" .. port .. "/"
    qr.show(url, {
      title = " LazyAgent Web UI ",
      hints = ANDROID_MIC_HINTS,
    })
  end, { nargs = 0, desc = "Show web UI QR code in a float window" })
end

return M
