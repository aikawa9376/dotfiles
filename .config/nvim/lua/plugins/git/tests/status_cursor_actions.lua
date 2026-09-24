-- Run from plugin root: nvim --headless --clean -u NONE -l tests/status_cursor_actions.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
package.loaded['git.features.status_watch'] = { subscribe = function() return function() end end }
package.loaded['git.features.worktree_watch'] = { subscribe = function() return function() end end }

local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid' }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end
git({ 'init', '-qb', 'main' })
vim.fn.writefile({ 'base' }, root .. '/tracked.txt')
git({ 'add', '.' })
git({ 'commit', '-qm', 'base' })
vim.fn.writefile({ 'one' }, root .. '/only.txt')

local executable = vim.fn.executable
vim.fn.executable = function(name) return name == 'gh' and 0 or executable(name) end
local status = require('git.features.status')
status.setup(vim.api.nvim_create_augroup('StatusCursorActionsTest', { clear = true }))
local b = assert(status.open({ work_tree = root, split = true, focus = false }))
local function rows()
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end
local function row(pattern)
  for index, line in ipairs(rows()) do
    if line:match(pattern) then return index end
  end
end
local function cursor_line() return vim.api.nvim_get_current_line() end
local function press(key, mode)
  local map = vim.fn.maparg(key, mode or 'n', false, true)
  assert(type(map.callback) == 'function', 'missing map ' .. key)
  map.callback()
end
assert(vim.wait(5000, function() return row('^%? only%.txt$') end, 20))
vim.api.nvim_win_set_cursor(0, { row('^%? only%.txt$'), 0 })
press('s')
assert(vim.wait(5000, function() return row('^A only%.txt$') end, 20), 'untracked file did not stage')
assert(cursor_line():match('^Staged changes %(1%)$'),
  'cursor did not move to the destination section when Untracked disappeared')
vim.wait(450, function() return false end)
assert(cursor_line():match('^Staged changes %(1%)$'), 'delayed refresh moved the Staged cursor')

vim.api.nvim_win_set_cursor(0, { row('^A only%.txt$'), 0 })
press('u')
assert(vim.wait(5000, function() return row('^%? only%.txt$') end, 20), 'added file did not unstage')
assert(cursor_line():match('^Untracked files %(1%)$'),
  'cursor did not move to Untracked when Staged disappeared: ' .. cursor_line())

vim.fn.writefile({ 'a' }, root .. '/a.txt')
vim.fn.writefile({ 'b' }, root .. '/b.txt')
status.refresh_buffer(b)
vim.api.nvim_win_set_cursor(0, { row('^%? a%.txt$'), 0 })
press('s')
assert(vim.wait(5000, function() return row('^A a%.txt$') end, 20))
assert(cursor_line():match('^%? b%.txt$'),
  'staging the first file should advance to the next Untracked file')
press('s')
assert(vim.wait(5000, function() return row('^A b%.txt$') end, 20))
assert(cursor_line():match('^%? only%.txt$'),
  'repeated staging should continue through Untracked files')
press('s')
assert(vim.wait(5000, function() return row('^A only%.txt$') end, 20))
assert(cursor_line():match('^Staged changes %(3%)$'),
  'last Untracked file should move to the Staged heading')

for _, name in ipairs({ 'v1.txt', 'v2.txt', 'v3.txt' }) do
  vim.fn.writefile({ name }, root .. '/' .. name)
end
status.refresh_buffer(b)
local first, second = row('^%? v1%.txt$'), row('^%? v2%.txt$')
assert(first and second == first + 1, 'visual test files are not adjacent')
vim.api.nvim_win_set_cursor(0, { first, 0 })
vim.cmd('normal! Vj')
assert(vim.fn.mode() == 'V', 'failed to enter linewise Visual mode')
press('s', 'x')
assert(vim.fn.mode() == 'n', 'visual stage left the editor in Visual mode')
assert(vim.wait(5000, function() return row('^A v1%.txt$') and row('^A v2%.txt$') end, 20),
  'visual stage did not stage both files')
assert(cursor_line():match('^%? v3%.txt$'),
  'visual stage did not advance to the next Untracked file')
press('s')
assert(vim.wait(5000, function() return row('^A v3%.txt$') end, 20))
assert(cursor_line():match('^Staged changes %(6%)$'),
  'last Untracked file did not move to the Staged heading')

vim.api.nvim_win_set_cursor(0, { row('^A a%.txt$'), 0 })
press('X')
assert(vim.wait(5000, function() return not row('^A a%.txt$') end, 20),
  'discard did not remove selected staged file')
assert(cursor_line():match('^A b%.txt$'),
  'removed file did not fall back to adjacent staged file: ' .. cursor_line())

press('X')
assert(vim.wait(5000, function() return not row('^A b%.txt$') end, 20))
assert(cursor_line():match('^A only%.txt$'), 'cursor did not advance through Staged files')
for _ = 1, 4 do
  local selected = cursor_line()
  press('X')
  assert(vim.wait(5000, function() return not vim.tbl_contains(rows(), selected) end, 20))
end
assert(cursor_line() == 'Help: g?', 'empty status did not settle on the Help row')

vim.api.nvim_buf_delete(b, { force = true })
vim.fn.executable = executable
vim.fn.delete(root, 'rf')
print('PASS: sequential staging stays in source section, with destination/neighbor fallback; Visual mode exits')
