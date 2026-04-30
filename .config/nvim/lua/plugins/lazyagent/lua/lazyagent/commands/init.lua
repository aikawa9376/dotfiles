local M = {}

local command = require("lazyagent.commands.util")

local groups = {
  "lazyagent.commands.session",
  "lazyagent.commands.acp",
  "lazyagent.commands.history",
  "lazyagent.commands.edit",
  "lazyagent.commands.hooks",
  "lazyagent.commands.mcp",
}

function M.setup_commands()
  for _, modname in ipairs(groups) do
    require(modname).register(command.create)
  end
end

return M
