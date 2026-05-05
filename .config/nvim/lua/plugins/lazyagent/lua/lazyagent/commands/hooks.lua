local M = {}

local command = require("lazyagent.commands.util")
local state = require("lazyagent.logic.state")

function M.register(create)
  create("LazyAgentHooks", function(cmdargs)
    local flag = command.arg(cmdargs)
    local hook_opts = state.opts and state.opts.hooks

    if not hook_opts then
      vim.notify("LazyAgentHooks: hooks not configured", vim.log.levels.WARN)
      return
    end

    if flag then
      if hook_opts[flag] == nil then
        vim.notify("LazyAgentHooks: unknown flag '" .. flag .. "'", vim.log.levels.WARN)
        return
      end

      if type(hook_opts[flag]) ~= "boolean" then
        vim.notify("LazyAgentHooks: '" .. flag .. "' is not a boolean toggle", vim.log.levels.WARN)
        return
      end

      hook_opts[flag] = not hook_opts[flag]
      vim.notify("LazyAgentHooks: " .. flag .. " = " .. tostring(hook_opts[flag]), vim.log.levels.INFO)
      return
    end

    local lines = {}
    for key, value in pairs(hook_opts) do
      table.insert(lines, string.format("  %-30s %s", key, tostring(value)))
    end
    table.sort(lines)
    vim.notify("LazyAgentHooks:\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
  end, {
    nargs = "?",
    desc = "Toggle or show lazyagent hook flags",
    complete = function()
      local hook_opts = state.opts and state.opts.hooks or {}
      local keys = {}
      for key in pairs(hook_opts) do
        table.insert(keys, key)
      end
      return keys
    end,
  })
end

return M
