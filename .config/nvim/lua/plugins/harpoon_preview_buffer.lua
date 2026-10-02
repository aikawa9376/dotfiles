-- Copy display data into owned scratch buffers, never attach a Git panel's handlers.
local M = {}
local api = vim.api
local ns = api.nvim_create_namespace('HarpoonPreviewDisplay')
local display_fields = { 'end_row', 'end_col', 'hl_group', 'hl_eol', 'priority',
  'line_hl_group', 'conceal', 'virt_text', 'virt_text_pos', 'virt_text_win_col',
  'virt_text_hide', 'hl_mode', 'sign_text', 'sign_hl_group' }

function M.capture(buf, pos)
  local marks = {}
  for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true, hl_name = true })) do
    local opts = {}
    for _, field in ipairs(display_fields) do opts[field] = mark[4][field] end
    if opts.hl_group or opts.line_hl_group or opts.virt_text or opts.sign_text or opts.conceal then
      marks[#marks + 1] = { mark[2], mark[3], opts }
    end
  end
  return { lines = api.nvim_buf_get_lines(buf, 0, -1, false), row = pos[1], col = pos[2],
    syntax = vim.bo[buf].syntax, marks = marks }
end

function M.fill(buf, lines, filetype, display)
  pcall(vim.treesitter.stop, buf)
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  -- Setting filetype would run the original panel's mappings and lifecycle hooks.
  vim.bo[buf].syntax = display and display.syntax or filetype or 'text'
  if not display then pcall(vim.treesitter.start, buf, filetype) end
  for _, mark in ipairs(display and display.marks or {}) do
    api.nvim_buf_set_extmark(buf, ns, mark[1], mark[2], mark[3])
  end
end

return M
