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
local heading_count = 0
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(ui.bufnr, -1, 0, -1, { details = true })) do
  if mark[2] == 0 and mark[4].hl_group == 'GitActionMenuHeading' then
    heading_count = heading_count + 1
  end
end
assert(heading_count == 2, 'action group headings did not use the menu heading color')
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
-- Long groups flow down, then right, using actual label widths in either window layout.
local original_lines = vim.o.lines
vim.o.lines = 40
vim.o.columns = 120
vim.g.git_action_menu_layout = 'split'
vim.g.git_action_menu_group_layout = nil
local long_actions = {}
for index = 1, 36 do
  local action_index = index
  long_actions[index] = { key = ('k%02d'):format(index),
    label = ('操作 %02d'):format(index), run = function() chosen = action_index end }
end
local long_spec = { kind = 'root', columns = 2, groups = {
  { title = 'Ref: main', actions = { { key = 'x', label = 'Inspect' } } },
  { title = 'Operations', actions = long_actions },
} }
local function find_action(ui, key)
  for row_number, line in ipairs(lines(ui)) do
    local column = line:find(key, 1, true)
    if column then return row_number, column - 1 end
  end
  error('missing action ' .. key)
end
ui = menu.show(long_spec)
assert(#lines(ui) == 16 and lines(ui)[1] == 'Ref: main',
  'long root group did not use three columns while retaining its target heading')
local first_row = find_action(ui, 'k01')
local last_row, last_column = find_action(ui, 'k25')
assert(first_row == last_row and last_column > 0,
  'long group did not flow down before continuing in the right column')
local right_key_highlighted = false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(ui.bufnr, -1, 0, -1, { details = true })) do
  if mark[2] == last_row - 1 and mark[3] == last_column
    and mark[4].hl_group == 'GitActionMenuKey' then right_key_highlighted = true end
end
assert(right_key_highlighted, 'right-column key highlight drifted after multibyte labels')
vim.api.nvim_win_set_cursor(ui.winid, { last_row, last_column })
vim.fn.maparg('<CR>', 'n', false, true).callback()
assert(chosen == 25, 'Enter executed the wrong action in a flowed column')

vim.cmd('vsplit')
local narrow_source = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_width(narrow_source, 25)
ui = menu.show(long_spec)
assert(#lines(ui) == 40, 'long group did not fall back to one column in a narrow split')
for _, line in ipairs(lines(ui)) do
  assert(vim.fn.strdisplaywidth(line) <= vim.api.nvim_win_get_width(ui.winid),
    'flowed action overflowed the actual menu width')
end
local selected_row, selected_column = find_action(ui, 'k25')
vim.api.nvim_win_set_cursor(ui.winid, { selected_row, selected_column })
-- The source and its menu share a frame, so widening either resizes both.
vim.api.nvim_win_set_width(ui.winid, 100)
vim.api.nvim_exec_autocmds('WinResized', {})
vim.wait(1000, function() return #lines(ui) == 16 end)
assert(#lines(ui) == 16, 'resize did not reflow the open menu')
local cursor = vim.api.nvim_win_get_cursor(ui.winid)
assert(lines(ui)[cursor[1]]:sub(cursor[2] + 1):find('k25', 1, true)
  and cursor[2] > 0, 'reflow did not retain the selected action in its new column')
vim.fn.maparg('<CR>', 'n', false, true).callback()
assert(chosen == 25, 'Enter lost its selected action after resizing')
vim.cmd('only')

vim.g.git_action_menu_group_layout = 'vertical'
ui = menu.show({ kind = 'long-operation', groups = { long_spec.groups[2] } })
assert(#lines(ui) == 37, 'vertical group layout no longer opts out of automatic columns')
ui.close()
vim.g.git_action_menu_group_layout = nil
vim.g.git_action_menu_layout = 'float'
ui = menu.show({ kind = 'long-operation', groups = { long_spec.groups[2] } })
assert(#lines(ui) == 13 and vim.api.nvim_win_get_config(ui.winid).relative == 'editor',
  'long operation group did not flow inside a float')
local float_width = vim.api.nvim_win_get_width(ui.winid)
for _, line in ipairs(lines(ui)) do
  assert(vim.fn.strdisplaywidth(line) <= float_width, 'flowed action overflowed the float')
end
-- Queued resize callbacks must remain harmless after the menu buffer is wiped.
vim.api.nvim_exec_autocmds('VimResized', {})
ui.close()
vim.wait(10, function() return false end)
vim.o.lines = original_lines
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
