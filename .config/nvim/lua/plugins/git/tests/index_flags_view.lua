-- Run from plugin root: nvim --headless --clean -u NONE -l tests/index_flags_view.lua
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
  return vim.trim(result.stdout or '')
end
git({ 'init', '-qb', 'main' })
for _, name in ipairs({ 'modified.txt', 'missing.txt', 'clean.txt' }) do
  vim.fn.writefile({ 'before' }, root .. '/' .. name)
end
git({ 'add', '.' })
git({ 'commit', '-qm', 'base' })
git({ 'update-index', '--skip-worktree', '--', 'modified.txt' })
git({ 'update-index', '--assume-unchanged', '--', 'missing.txt' })
git({ 'update-index', '--skip-worktree', '--', 'clean.txt' })
vim.fn.writefile({ 'after' }, root .. '/modified.txt')
vim.fn.delete(root .. '/missing.txt')

local executable = vim.fn.executable
vim.fn.executable = function(name) return name == 'gh' and 0 or executable(name) end
local status = require('git.features.status')
status.setup(vim.api.nvim_create_augroup('IndexFlagsViewTest', { clear = true }))
local b = status.open({ work_tree = root, split = true })
local flagged_state = require('git.features.index_flags').inspect(root)
assert(not require('git.features.index_flags').entry_at_row(flagged_state,
  { 'Staged changes (1)', 'M modified.txt', '', 'Index flags [local] (1)', 'M modified.txt' }, 2),
  'native file rows must not be mistaken for Index flags')
local function lines() return vim.api.nvim_buf_get_lines(b, 0, -1, false) end
local function row_matching(pattern)
  for row, line in ipairs(lines()) do
    if line:match(pattern) then return row end
  end
end
assert(vim.wait(5000, function() return row_matching('^Index flags %[local%] %(3%)$') end, 20))
local heading = row_matching('^Index flags %[local%]')
assert(vim.fn.foldclosed(heading) == heading, 'Index flags should default closed even with three files')
assert(row_matching('^M modified%.txt$') and row_matching('^D missing%.txt$')
  and row_matching('^  clean%.txt$'), 'flagged file rows do not use normal change markers')
assert(not table.concat(lines(), '\n'):find('  skip ', 1, true), 'flag type leaked into file rows')

local icon_ns = vim.api.nvim_create_namespace('fugitive_status_icons')
local function statistics(row)
  local marks = vim.api.nvim_buf_get_extmarks(b, icon_ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })
  for _, mark in ipairs(marks) do
    local chunks = mark[4].virt_text
    if chunks then
      local parts = {}
      for _, chunk in ipairs(chunks) do parts[#parts + 1] = chunk[1] end
      local result = table.concat(parts)
      if result:find('+', 1, true) or result:find('-', 1, true) then return result end
    end
  end
  return ''
end
assert(statistics(row_matching('^M modified%.txt$')):find('+1', 1, true)
  and statistics(row_matching('^M modified%.txt$')):find('-1', 1, true),
  'modified flagged file lacks +/- statistics')
assert(statistics(row_matching('^D missing%.txt$')):find('-1', 1, true),
  'missing flagged file lacks deletion statistics')

vim.api.nvim_win_set_cursor(0, { heading, 0 })
vim.fn.maparg('<Tab>', 'n', false, true).callback()
assert(vim.fn.foldclosed(heading) == -1, 'Tab did not open Index flags fold')
local file_row = row_matching('^M modified%.txt$')
vim.api.nvim_win_set_cursor(0, { file_row, 0 })
vim.fn.maparg('=', 'n', false, true).callback()
assert(row_matching('^@@ ') and row_matching('^%-before$') and row_matching('^%+after$'),
  'inline flagged diff did not show index-to-worktree changes')
status.refresh_buffer(b)
assert(row_matching('^%+after$') and vim.fn.foldclosed(heading) == -1,
  'inline diff or fold state was lost on refresh')
local hunk = row_matching('^@@ ')
vim.api.nvim_win_set_cursor(0, { hunk, 0 })
vim.fn.maparg('=', 'n', false, true).callback()
assert(not row_matching('^@@ '), 'toggle on a hunk did not close its file diff')

vim.api.nvim_win_set_cursor(0, { heading, 0 })
vim.fn.maparg('<Tab>', 'n', false, true).callback()
assert(vim.fn.foldclosed(heading) == heading, 'Tab did not close Index flags fold')
local warning = row_matching('^Hidden changes:')
vim.api.nvim_win_set_cursor(0, { warning, 0 })
vim.fn.maparg('<CR>', 'n', false, true).callback()
assert(vim.wait(1000, function() return vim.fn.foldclosed(heading) == -1 end, 20),
  'Hidden changes did not reveal Index flags')

vim.api.nvim_buf_delete(b, { force = true })
vim.fn.executable = executable
vim.fn.delete(root, 'rf')
print('PASS: flagged files use change rows, +/- statistics, inline diffs and regular folds')
