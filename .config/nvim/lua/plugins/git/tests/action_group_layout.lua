-- Run from plugin root: nvim --headless --clean -u NONE -l tests/action_group_layout.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path

local menu = require('git.features.transient_menu')
local original_columns = vim.o.columns
local original_layout = vim.g.git_action_menu_group_layout
local original_window_layout = vim.g.git_action_menu_layout
local original_list = vim.o.list
local original_listchars = vim.o.listchars
local chosen
local spec = { kind = 'layout-test', groups = {
  { title = 'Arguments', actions = {
    { key = '-a', label = 'First flag', run = function() chosen = 'first' end },
  } },
  { title = 'Actions', actions = {
    { key = 'x', label = 'Second action', run = function() chosen = 'second' end },
  } },
} }
local function lines(ui)
  return vim.api.nvim_buf_get_lines(ui.bufnr, 0, -1, false)
end

vim.o.columns = 120
vim.g.git_action_menu_group_layout = nil
local ui = menu.show(spec)
assert(lines(ui)[1]:find('Arguments', 1, true)
  and lines(ui)[1]:find('Actions', 1, true),
  'wide action menu did not place complete groups side by side')
local row = lines(ui)[2]
vim.api.nvim_win_set_cursor(ui.winid, { 2, row:find('x', 1, true) - 1 })
local enter = vim.fn.maparg('<CR>', 'n', false, true)
enter.callback()
assert(chosen == 'second', 'enter selected the wrong horizontal action column')

vim.cmd('vsplit')
vim.api.nvim_win_set_width(0, 30)
ui = menu.show(spec)
assert(lines(ui)[1] == 'Arguments'
  and table.concat(lines(ui), '\n'):find('\nActions\n', 1, true),
  'narrow action menu did not wrap groups')
ui.close()
vim.cmd('only')

vim.o.columns = 120
vim.g.git_action_menu_group_layout = 'vertical'
ui = menu.show(spec)
assert(lines(ui)[1] == 'Arguments'
  and table.concat(lines(ui), '\n'):find('\nActions\n', 1, true),
  'vertical layout option did not restore the previous group layout')
ui.close()
vim.g.git_action_menu_group_layout = 'horizontal'
vim.g.git_action_menu_layout = 'split'
vim.o.list = true
vim.o.listchars = 'trail:-'
local narrow_spec = { kind = 'layout-test', groups = {
  { title = 'Long arguments', actions = {
    { key = '-a', label = string.rep('A', 80), state = function() return true end,
      run = function() end },
    { key = '-b', label = 'Short flag', enabled = false, run = function() end },
  } },
  { title = 'Actions', actions = {
    { key = 'x', label = 'Short action', run = function() end },
  } },
} }
ui = menu.show(narrow_spec)
assert(lines(ui)[1]:find('Actions', 1, true), 'wide groups did not stay side by side')
assert(lines(ui)[2]:find('%-a A') and not lines(ui)[2]:find('%-a%s%s+A'),
  'key and description should be separated by one space')
assert(not lines(ui)[3]:find('%s+$'), 'shorter right group left trailing alignment spaces')
local keys = {}
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(ui.bufnr, -1, 0, -1, { details = true })) do
  if mark[4].hl_group == 'GitActionMenuKey' then
    local line = lines(ui)[mark[2] + 1]
    keys[line:sub(mark[3] + 1, mark[4].end_col)] = mark[4].priority
  end
end
assert(keys['-a'] == 4100 and keys.x == 4100 and not keys['-b'],
  'key highlight missed an active/right-column key or colored a disabled action')
ui.close()
vim.cmd('vsplit')
ui = menu.show(narrow_spec)
assert(not vim.wo[ui.winid].list, 'listchars showed alignment padding as trailing dashes')
assert(lines(ui)[1] == 'Long arguments'
  and table.concat(lines(ui), '\n'):find('\nActions\n', 1, true),
  'groups did not wrap to the actual split width')
assert(table.concat(lines(ui), '\n'):find('…', 1, true),
  'oversized action was not clipped to the split width')
for _, line in ipairs(lines(ui)) do
  assert(vim.fn.strdisplaywidth(line) <= vim.api.nvim_win_get_width(ui.winid),
    'action menu line exceeds the split width')
  assert(not line:find('%s+$'), 'action menu left visible trailing padding')
end
ui.close()
vim.cmd('only')
vim.o.list = original_list
vim.o.listchars = original_listchars
vim.g.git_action_menu_layout = 'float'
ui = menu.show(spec)
assert(vim.api.nvim_win_get_config(ui.winid).relative == 'editor'
  and lines(ui)[1]:find('Actions', 1, true),
  'horizontal groups did not work in the float layout')
ui.close()
local option_state = { command = 'echo done' }
local option = require('git.features.transient_options').value('-x', 'Command (per commit)',
  option_state, 'command', '--exec=')
ui = menu.show({ kind = 'options-test', groups = { { title = 'Arguments', actions = { option } } } })
local argument_highlighted = false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(ui.bufnr, -1, 0, -1, { details = true })) do
  if mark[4].hl_group == 'DiagnosticOk' then
    argument_highlighted = lines(ui)[mark[2] + 1]:sub(mark[3] + 1, mark[4].end_col) == '--exec=echo done'
  end
end
assert(argument_highlighted, 'argument highlight included parentheses in the description')
local original_input, pending_input = vim.ui.input
vim.ui.input = function(_, callback) pending_input = callback end
vim.fn.maparg('-x', 'n', false, true).callback()
ui.close()
assert(pcall(pending_input, 'new value'), 'late input callback tried to redraw a closed menu')
vim.ui.input = original_input
vim.o.columns = original_columns
vim.g.git_action_menu_group_layout = original_layout
vim.g.git_action_menu_layout = original_window_layout
print('PASS: action groups wrap by width and can use the previous vertical layout')
