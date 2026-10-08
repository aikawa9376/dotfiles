-- Run: nvim --headless --clean -u NONE '+lua local ok, err = pcall(dofile, "tests/panel_layout.lua"); if not ok then print(err); vim.cmd("cquit") end' +qa!
-- Use normal startup: -l script mode does not apply editor grid resizes.
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
vim.o.swapfile = false
local utils = require('git.utils')
vim.o.lines = 60
vim.o.columns = 800
vim.o.splitright, vim.o.splitbelow = false, false
local function check(width, minimum, expected, target)
  vim.cmd('silent! only!')
  vim.api.nvim_win_set_width(0, 800)
  vim.cmd('vsplit')
  local origin = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(origin, width)
  local sibling = vim.fn.win_getid(vim.fn.winnr('#'))
  local sibling_width = vim.api.nvim_win_get_width(sibling)
  local origin_pos = vim.api.nvim_win_get_position(origin)
  local panel = utils.open_panel_split(target, minimum and { min_width = minimum } or nil)
  local pos = vim.api.nvim_win_get_position(panel)
  if expected == 'right' then
    assert(pos[1] == origin_pos[1] and pos[2] > origin_pos[2], 'expected right split')
  else
    assert(pos[1] > origin_pos[1] and pos[2] == origin_pos[2], 'expected lower split')
  end
  assert(vim.api.nvim_win_get_width(sibling) == sibling_width, 'unrelated window resized')
  assert(vim.w[origin].git_preserve_split_view == nil)
  if target then assert(vim.api.nvim_buf_get_name(0) == target) end
  vim.api.nvim_win_close(panel, true)
  vim.wait(10)
  assert(vim.api.nvim_win_is_valid(origin))
end
vim.g.git_panel_min_width = 200
check(200, nil, 'right')
check(199, nil, 'below')
check(240, 240, 'right', 'git-panel-test://with space')
check(239, 240, 'below')
print('PASS: panel minimum widths, status override, placement and sibling preservation')
