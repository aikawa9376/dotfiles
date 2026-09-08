local M = {}

function M.setup()
  if not vim.env.TMUX then
    return
  end

  local out = vim.fn.system({ "tmux", "display-message", "-p", "#{extended-keys}\t#{client_termname}" })
  if vim.v.shell_error ~= 0 then
    return
  end
  local mode, name = vim.trim(out):match("^(%S+)\t(.+)$")
  if mode ~= "always" then
    return
  end

  -- Extend Snacks' on-only XTVERSION workaround to always (snacks.nvim#2332).
  local terminal = require("snacks.image.terminal")
  if terminal._terminal then
    return
  end
  terminal._terminal = { terminal = name:gsub("^xterm%-", ""), version = "unknown" }
  terminal.transform = terminal.env().transform
end

return M
