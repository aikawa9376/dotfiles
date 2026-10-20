local M = {}
function M.new() return setmetatable({}, { __index = M }) end
function M:enabled()
  return vim.bo.filetype == "blade" or vim.api.nvim_buf_get_name(0):match("%.blade%.php$") ~= nil
end
function M:get_trigger_characters() return { " ", ":", '"', "'", "." } end
function M:get_completions(ctx, callback)
  local buf = ctx.bufnr or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = table.concat(lines, "\n")
  local offset = require("laravel_extension.syntax").offset(text, ctx.cursor[1], ctx.cursor[2])
  callback({ is_incomplete_forward = true, is_incomplete_backward = true,
    items = require("laravel_extension.features.members").completions(buf, text, offset) })
end
return M
