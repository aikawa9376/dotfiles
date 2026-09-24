-- Run from the plugin root: nvim --headless --clean -u NONE -l tests/log_range.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path

local root = vim.fn.tempname() .. ' log-range repo'
vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout or '')
end
local function write(lines) vim.fn.writefile(lines, root .. '/a file.txt') end
local function commit(subject)
  git({ 'add', '.' })
  git({ 'commit', '-qm', subject })
end
local function subjects()
  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
end
local function assert_read_only()
  assert(not vim.bo.modifiable and vim.bo.readonly, 'log panel must remain read-only')
  assert(not pcall(vim.api.nvim_buf_set_lines, 0, 0, 1, false, { 'edited' }),
    'log panel accepted a direct buffer edit')
end

git({ 'init', '-q', '-b', 'main' })
git({ 'config', 'user.name', 'Test' })
git({ 'config', 'user.email', 'test@example.invalid' })
git({ 'config', 'commit.gpgsign', 'false' })
write({ 'one', 'two', 'three' }); commit('initial')
local initial_hash = git({ 'rev-parse', 'HEAD' })
write({ 'one', 'TWO', 'three' }); commit('selected line')
write({ 'ONE', 'TWO', 'three' }); commit('other line')

require('git').setup()
vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/a file.txt'))
local file_buf = vim.api.nvim_get_current_buf()
vim.cmd('2,2Glog')
assert_read_only()
vim.api.nvim_exec_autocmds('User', { pattern = 'FugitiveChanged', data = { work_tree = root } })
assert_read_only()
local selected = subjects()
assert(selected:find('selected line', 1, true) and selected:find('initial', 1, true))
assert(not selected:find('other line', 1, true), 'range log included an unrelated change')
local range = vim.b.fugitive_log_line_history
assert(range.first == 2 and range.last == 2 and range.path == 'a file.txt')
vim.cmd('close')

require('git.objects').open(initial_hash .. ':a file.txt', nil, root)
vim.cmd('2,2Glog')
assert(subjects():find('initial', 1, true) and not subjects():find('selected line', 1, true),
  'historical blob range should start from its displayed revision')
assert(vim.b.fugitive_log_line_history.revision == initial_hash)
vim.cmd('close')
vim.cmd('2,2Glog HEAD')
assert(subjects():find('selected line', 1, true), 'explicit revision overrides the displayed blob')
vim.cmd('close')
vim.api.nvim_set_current_buf(file_buf)

vim.cmd('1,1FugitiveLog')
assert(subjects():find('other line', 1, true) and not subjects():find('selected line', 1, true))
vim.cmd('close')

vim.cmd('Glog')
assert_read_only()
assert(subjects():find('other line', 1, true) and subjects():find('selected line', 1, true))
vim.cmd('close')

assert(vim.api.nvim_get_current_buf() == file_buf)
local spec = dofile(plugin .. '/init.lua')
local visual_mapping
for _, entry in ipairs(spec.keys) do
  if entry[1] == 'g<space>l' and entry.mode == 'x' then visual_mapping = entry[2] end
end
assert(type(visual_mapping) == 'function', 'Visual g<Space>l mapping is missing')
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.cmd('normal! Vj')
assert(vim.fn.mode() == 'V', 'test must be in Visual Line mode')
visual_mapping()
range = vim.b.fugitive_log_line_history
assert(range and range.first == 2 and range.last == 3, 'Visual mapping lost selected row range')
assert(subjects():find('selected line', 1, true) and not subjects():find('other line', 1, true))
vim.cmd('close')

-- A later insertion moves the selected line from row 2 to row 3 at HEAD.
-- The commit diff must still focus its historical row 2.
write({ 'prefix', 'ONE', 'TWO', 'three' }); commit('line shift')
vim.cmd('edit!')
vim.cmd('3,3Glog')
local log_buf = vim.api.nvim_get_current_buf()
local focus_by_commit = vim.b[log_buf].fugitive_log_line_focus
local selected_row, selected_hash, initial_row
for row, line in ipairs(vim.api.nvim_buf_get_lines(log_buf, 0, -1, false)) do
  if line:find('selected line', 1, true) then
    selected_row, selected_hash = row, line:match('^(%x+)')
  elseif line:find('initial', 1, true) then
    initial_row = row
  end
end
assert(selected_row and initial_row and focus_by_commit[selected_hash].first == 2,
  'line history must retain the old row after an insertion above it')
vim.api.nvim_win_set_cursor(0, { selected_row, 0 })
local log_win = vim.api.nvim_get_current_win()
local preview_map = vim.fn.maparg('<C-p>', 'n', false, true)
assert(preview_map.callback, 'log preview mapping is missing')
preview_map.callback()
local preview_win
for _, win in ipairs(vim.api.nvim_list_wins()) do
  if win ~= log_win and vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'fugitivecommit' then
    preview_win = win
  end
end
assert(preview_win, 'commit preview did not open')
local preview_buf = vim.api.nvim_win_get_buf(preview_win)
local preview_row = vim.api.nvim_win_get_cursor(preview_win)[1]
assert(vim.api.nvim_buf_get_lines(preview_buf, preview_row - 1, preview_row, false)[1] == '+TWO',
  'preview did not focus the selected line diff')
vim.api.nvim_win_set_cursor(log_win, { initial_row, 0 })
vim.api.nvim_exec_autocmds('CursorMoved', { buffer = log_buf })
assert(vim.wait(1000, function()
  local buf = vim.api.nvim_win_get_buf(preview_win)
  local row = vim.api.nvim_win_get_cursor(preview_win)[1]
  return vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] == '+two'
end, 10), 'moving through the log did not refocus the preview')
require('git.features.commands').close_preview()

vim.api.nvim_win_set_cursor(log_win, { selected_row, 0 })
local enter_map = vim.fn.maparg('<CR>', 'n', false, true)
assert(enter_map.callback, 'log Enter mapping is missing')
enter_map.callback()
assert(vim.bo.filetype == 'fugitivecommit' and vim.api.nvim_get_current_line() == '+TWO',
  'Enter did not focus the selected line diff in the commit panel')
vim.cmd('tabclose')
vim.cmd('close')

vim.fn.delete(root, 'rf')
print('PASS: line history, Visual mapping, spaced paths, and focused preview/commit diffs')
