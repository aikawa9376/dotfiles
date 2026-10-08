-- Run from the plugin root: nvim --headless --clean -u NONE -l tests/panel_help.lua
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local menu = require('git.features.action_menu')
local source = vim.api.nvim_get_current_buf()
local called = false
local buf, win = menu.show('Actions', { { title = 'Current item', actions = {
  { key = 'd', label = 'Compare', callback = function() called = true end },
  { key = '<2-LeftMouse>', label = 'Open' },
  { key = 'x', display_key = '表示', label = 'Display', enabled = false },
} } })
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
local column
for _, label in ipairs({ 'Compare', 'Open', 'Display' }) do
  for _, line in ipairs(lines) do
    local start = line:find(label, 1, true)
    if start then
      local width = vim.fn.strdisplaywidth(line:sub(1, start - 1))
      assert(not column or column == width, 'action key columns are misaligned')
      column = width
    end
  end
end
local highlights = {}
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace('git_action_menu'), 0, -1, { details = true })) do
  highlights[mark[4].hl_group] = true
end
assert(highlights.Title and highlights.Type and highlights.Special and highlights.Comment, 'menu lost semantic colors')
vim.fn.maparg('d', 'n', false, true).callback()
assert(called and not vim.api.nvim_win_is_valid(win) and vim.api.nvim_get_current_buf() == source,
  'menu action should execute in the source window')

vim.bo[source].filetype = 'gitstash'
vim.keymap.set('n', 'd', function() end, { buffer = source, desc = 'Compare' })
vim.keymap.set('n', 'dd', function() end, { buffer = source, desc = 'Compare' })
vim.keymap.set('n', '<F12>', function() end, { buffer = source, desc = 'Open' })
vim.keymap.set({ 'n', 'x' }, '<Space><Space>', function() end, { buffer = source, desc = 'Git action menu' })
local keys = require('git.features.panel_keys')
keys.configure(source)
local help_buf, help_win = keys.help(source)
lines = vim.api.nvim_buf_get_lines(help_buf, 0, -1, false)
column = nil
for _, line in ipairs(lines) do
  local start = line:find('  Compare$') or line:find('  Open$')
  if start then
    local width = vim.fn.strdisplaywidth(line:sub(1, start + 1))
    assert(not column or column == width, 'text guide key columns are misaligned')
    column = width
  end
end
assert(column, 'text guide did not show mapped actions')
local alias_colored = false
local menu_colored, menu_key_colored, menu_count = false, false, 0
for _, line in ipairs(lines) do
  if line:find('Git action menu', 1, true) then
    menu_count = menu_count + 1
    assert(line == 'Git action menu', 'menu heading must be flush left')
  end
end
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(help_buf, vim.api.nvim_create_namespace('git_help'), 0, -1, { details = true })) do
  if mark[4].hl_group == 'Special' and lines[mark[2] + 1]:find('d / dd', 1, true) then
    alias_colored = mark[4].end_col >= #'d / dd'
  end
  if lines[mark[2] + 1] == 'Git action menu' and mark[4].hl_group == 'Type' then menu_colored = true end
  if lines[mark[2] + 1]:find('<Space><Space>', 1, true) and mark[4].hl_group == 'Special' then menu_key_colored = true end
end
assert(alias_colored, 'combined key aliases should retain key color')
assert(menu_count == 1 and menu_colored and menu_key_colored, 'menu heading/key must be distinct, colored and shown once')
vim.api.nvim_win_close(help_win, true)
print('PASS: long/wide key alignment, menu colors, source action execution and text guide alignment')
