local M = {}

local edit_blocks = require("lazyagent.logic.edit_blocks")

function M.register(create)
  create("LazyAgentEdit", function(cmdargs)
    edit_blocks.edit_selection({
      request = vim.trim(cmdargs.args or ""),
      line1 = cmdargs.line1,
      line2 = cmdargs.line2,
    })
  end, {
    nargs = "*",
    range = true,
    desc = "Edit the selected line range with a one-shot AI agent",
  })
end

return M
