-- Run from plugin root: nvim --headless --clean -u NONE -l tests/status_cursor_edit.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
package.loaded['git.features.status_watch'] = { subscribe = function() return function() end end }
package.loaded['git.features.worktree_watch'] = { subscribe = function() return function() end end }

local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local function git(args)
  local command = { 'git', '-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid' }
  vim.list_extend(command, args)
  local result = vim.system(command, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end
git({ 'init', '-qb', 'main' })
local path = root .. '/sample.txt'
local base = {}
for number = 1, 24 do base[number] = 'line ' .. number end
vim.fn.writefile(base, path)
git({ 'add', 'sample.txt' })
git({ 'commit', '-qm', 'base' })
local changed = vim.deepcopy(base)
changed[5], changed[20] = 'CHANGED FIVE', 'CHANGED TWENTY'
vim.fn.writefile(changed, path)

local executable = vim.fn.executable
vim.fn.executable = function(name) return name == 'gh' and 0 or executable(name) end
local status = require('git.features.status')
local renderer = require('git.features.status_renderer')
status.setup(vim.api.nvim_create_augroup('StatusCursorEditTest', { clear = true }))
local b = assert(status.open({ work_tree = root, split = true, focus = false }))
local function row_containing(text)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
    if line:find(text, 1, true) then return row end
  end
end
assert(vim.wait(5000, function() return row_containing('M sample.txt') end, 20))
local status_win = vim.api.nvim_get_current_win()
local file_row = assert(row_containing('M sample.txt'))
assert(renderer.update_diff(b, file_row, 'show'))
local selected = assert(row_containing('+CHANGED FIVE'))
vim.api.nvim_win_set_cursor(status_win, { selected, 1 })
local open = vim.fn.maparg('<CR>', 'n', false, true)
assert(type(open.callback) == 'function')
open.callback()
assert(vim.api.nvim_get_current_win() ~= status_win and vim.api.nvim_win_get_buf(status_win) == b,
  'opening a file did not leave status visible')
assert(vim.api.nvim_buf_get_name(0) == path, 'status did not open the selected file')
assert((vim.api.nvim_buf_get_lines(b, vim.api.nvim_win_get_cursor(status_win)[1] - 1,
  vim.api.nvim_win_get_cursor(status_win)[1], false)[1] or '') == '+CHANGED FIVE',
  'opening the file already moved the status cursor')

local file_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(file_buf, 19, 20, false, { 'CHANGED TWENTY AGAIN' })
vim.cmd('silent write')
assert(vim.wait(5000, function() return row_containing('+CHANGED TWENTY AGAIN') end, 20),
  'saving the file did not refresh the visible status panel')
vim.wait(450, function() return false end)
local function status_line()
  local row = vim.api.nvim_win_get_cursor(status_win)[1]
  return vim.api.nvim_buf_get_lines(b, row - 1, row, false)[1]
end
assert(status_line() == '+CHANGED FIVE',
  'refresh moved status cursor from the selected diff line to ' .. tostring(status_line()))

vim.api.nvim_buf_set_lines(file_buf, 4, 5, false, { 'CHANGED FIVE AGAIN' })
vim.cmd('silent write')
assert(vim.wait(5000, function() return row_containing('+CHANGED FIVE AGAIN') end, 20),
  'saving the selected line did not refresh the visible status panel')
vim.wait(450, function() return false end)
assert(status_line() == '+CHANGED FIVE AGAIN',
  'editing the selected diff line moved status cursor to ' .. tostring(status_line()))

vim.fn.executable = executable
vim.api.nvim_buf_delete(b, { force = true })
vim.fn.delete(root, 'rf')
print('PASS: status cursor stays on or near an inline diff after opening and editing its file')
