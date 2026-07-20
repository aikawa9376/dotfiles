local M = {}

local command = require("lazyagent.commands.util")

local groups = {
  "lazyagent.commands.session",
  "lazyagent.commands.acp",
  "lazyagent.commands.history",
  "lazyagent.commands.edit",
  "lazyagent.commands.notes",
  "lazyagent.commands.review",
  "lazyagent.commands.hooks",
  "lazyagent.commands.mcp",
  "lazyagent.commands.image",
}

function M.setup_commands()
  for _, modname in ipairs(groups) do
    require(modname).register(command.create, command.delete)
  end
end

return M
