local M = {}

function M.check()
  vim.health.start('overseer-http.nvim')
  local ok = pcall(require, 'overseer')
  if ok then
    vim.health.ok('overseer.nvim is available')
  else
    vim.health.error('overseer.nvim is required')
  end
  local executable = require('overseer_http').config.curl.executable
  if vim.fn.executable(executable) == 1 then
    vim.health.ok(executable .. ' is available')
  else
    vim.health.error(executable .. ' is required')
  end
end

return M
