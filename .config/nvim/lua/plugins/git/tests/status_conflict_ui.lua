-- Run from plugin root: nvim --headless --clean -u NONE -l tests/status_conflict_ui.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
package.loaded['git.features.status_watch'] = { subscribe = function() return function() end end }
package.loaded['git.features.worktree_watch'] = { subscribe = function() return function() end end }

local root = vim.fn.tempname() .. ' conflict-ui'
vim.fn.mkdir(root, 'p')
local function git(args, allow_failure)
  local argv = { 'git', '-C', root }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  if not allow_failure then assert(result.code == 0, result.stderr) end
  return result
end
local function write(path, value) vim.fn.writefile({ value }, root .. '/' .. path) end
git({ 'init', '-qb', 'main' })
git({ 'config', 'user.name', 'Test' })
git({ 'config', 'user.email', 'test@example.invalid' })
write('changed.txt', 'base')
git({ 'add', '.' })
git({ 'commit', '-qm', 'base' })
git({ 'switch', '-qc', 'other' })
write('added.txt', 'theirs')
write('changed.txt', 'theirs')
git({ 'add', '.' })
git({ 'commit', '-qm', 'theirs' })
git({ 'switch', '-q', 'main' })
write('added.txt', 'ours')
write('changed.txt', 'ours')
git({ 'add', '.' })
git({ 'commit', '-qm', 'ours' })
git({ 'branch', '--set-upstream-to=other', 'main' })
assert(git({ 'merge', 'other' }, true).code ~= 0)
write('plain.txt', 'untracked')

local executable = vim.fn.executable
vim.fn.executable = function(name) return name == 'gh' and 0 or executable(name) end
local status = require('git.features.status')
status.setup(vim.api.nvim_create_augroup('StatusConflictUiTest', { clear = true }))
local bufnr = assert(status.open({ work_tree = root, split = true }))
local function lines() return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) end
local function row_for(pattern)
  for row, line in ipairs(lines()) do
    if line:match(pattern) then return row end
  end
end
assert(vim.wait(5000, function()
  local all = table.concat(lines(), '\n')
  return all:find('Unmerged paths', 1, true) and not all:find('Loading repository details', 1, true)
end, 20), 'status did not finish loading')
local header = assert(row_for('^Unmerged paths'))
local added = assert(row_for('^AA added%.txt$'))
local changed = assert(row_for('^UU changed%.txt$'))
assert(vim.fn.foldlevel(header) > 0 and vim.fn.foldclosed(header) == -1,
  'Unmerged paths should start open even with multiple files')
assert(not lines()[added + 1]:match('^@@') and not lines()[changed + 1]:match('^@@'),
  'conflict file diffs should start closed')
local function press(key)
  local mapping = vim.fn.maparg(key, 'n', false, true)
  assert(mapping.callback, 'missing keymap ' .. key)
  mapping.callback()
end
local unpushed = assert(row_for('^Unpushed %[only%]'))
vim.api.nvim_win_set_cursor(0, { header, 0 })
press('gp')
assert(vim.api.nvim_win_get_cursor(0)[1] == unpushed + 1,
  'gp did not focus the open Unpushed section')
press('gm')
assert(vim.api.nvim_get_current_line():match('^AA added%.txt$'),
  'gm did not focus the first unmerged file')
vim.api.nvim_win_set_cursor(0, { header, 0 })
press('<Tab>')
assert(vim.fn.foldclosed(header) == header, 'Tab did not close Unmerged paths')
press('gp')
press('gm')
assert(vim.api.nvim_win_get_cursor(0)[1] == header,
  'gm did not focus the closed Unmerged paths heading')
press('<Tab>')
assert(vim.fn.foldclosed(header) == -1, 'Tab did not reopen Unmerged paths')
assert(vim.fn.maparg('c3', 'n') == '', 'old c3 mapping is still active')
vim.api.nvim_win_set_cursor(0, { added, 0 })
press('d')
local windows = vim.api.nvim_tabpage_list_wins(0)
assert(#windows == 3, 'd on a conflict did not open three-way diff')
for index, label in ipairs({ 'base', 'ours', 'theirs' }) do
  local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(windows[index]))
  assert(name:find('/' .. label .. '/added.txt', 1, true), 'wrong three-way pane: ' .. name)
end
vim.cmd('tabclose')
vim.api.nvim_win_set_cursor(0, { added, 0 })
press('o')
assert(lines()[added + 1]:match('^@@'), 'o did not expand the conflict file diff')
vim.api.nvim_win_set_cursor(0, { added + 1, 0 })
press('dh')
assert(#vim.api.nvim_tabpage_list_wins(0) == 3 and vim.fn.winlayout()[1] == 'col',
  'dh on a conflict did not open a horizontal three-way diff')
vim.cmd('tabclose')

local merge_row = assert(row_for('^Merge:'))
assert(not row_for('^Current:'), 'merge current summary still occupies a second row')
vim.api.nvim_win_set_cursor(0, { merge_row, 0 })
local groups
require('git.features.action_menu').show = function(_, value) groups = value end
press('g?')
local has_continue = false
for _, group in ipairs(groups or {}) do
  for _, action in ipairs(group.actions) do
    if action.key == 'rr' then has_continue = true end
  end
end
assert(has_continue, 'merged Current header lost operation actions')
local operation = require('git.features.operation')
for kind, title in pairs({ cherry_pick = 'Cherry-pick', revert = 'Revert', rebase = 'Rebase' }) do
  local rendered = operation.status_lines({ kind = kind, label = title .. ' in progress',
    current = { hash = 'abcdef0', subject = 'subject' } })
  assert(rendered[1] == title .. ': abcdef0 subject' and not rendered[2]:match('^Current:'),
    title .. ' operation still uses a separate Current row')
end
local progressing = operation.status_lines({ kind = 'cherry_pick', label = 'Cherry-pick in progress',
  current_step = 2, total_steps = 3, current = { hash = 'abcdef0', subject = 'subject' } })
assert(progressing[1] == 'Cherry-pick (2/3): abcdef0 subject',
  'combined operation heading lost sequencer progress')

local plain = assert(row_for('^%? plain%.txt$'))
vim.api.nvim_win_set_cursor(0, { plain, 0 })
press('d')
assert(#vim.api.nvim_tabpage_list_wins(0) == 2, 'd on ordinary file should retain two-way diff')
vim.cmd('tabclose')

write('changed.txt', 'manual result')
vim.api.nvim_win_set_cursor(0, { assert(row_for('^UU changed%.txt$')), 0 })
press('o')
local result_row = assert(row_for('^%+manual result$'))
local highlight_ns = assert(vim.api.nvim_get_namespaces().fugitive_extension_syntax)
assert(vim.wait(2000, function()
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, highlight_ns,
    { result_row - 1, 0 }, { result_row - 1, -1 }, { details = true })
  for _, mark in ipairs(marks) do
    if mark[4].hl_group == 'GitStatusConflictLine' then return true end
  end
  return false
end), 'actual status refresh did not highlight the manually resolved conflict')

vim.api.nvim_buf_delete(bufnr, { force = true })
vim.fn.delete(root, 'rf')
print('PASS: open conflict section, closed file diffs, context-sensitive d, and merged Current actions')
