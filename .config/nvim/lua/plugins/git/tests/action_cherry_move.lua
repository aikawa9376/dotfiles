-- Run from plugin root: nvim --headless --clean -u NONE -l tests/action_cherry_move.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path

local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
local function write(path, value) vim.fn.writefile({ value }, root .. '/' .. path) end
local function commit(path, value, message)
  write(path, value)
  git({ 'add', path })
  git({ 'commit', '-qm', message })
  return git({ 'rev-parse', 'HEAD' })
end
git({ 'init', '-qb', 'main' })
git({ 'config', 'user.name', 'Test' })
git({ 'config', 'user.email', 'test@example.invalid' })
commit('base.txt', 'base', 'base')
git({ 'switch', '-qc', 'source' })
local selected = commit('selected.txt', 'selected', 'selected')
commit('later.txt', 'later', 'later')
git({ 'switch', '-q', 'main' })
commit('main.txt', 'main', 'main')

local move = require('git.features.magit_cherry_move')
local ok, err = move.harvest(root, selected, 'source')
assert(ok, err)
assert(git({ 'branch', '--show-current' }) == 'main', 'harvest changed the current branch')
assert(vim.fn.filereadable(root .. '/selected.txt') == 1, 'harvest did not pick the commit')
assert(git({ 'rev-list', '--count', 'main..source' }) == '1',
  'harvest removed the later source commit')
assert(git({ 'show', 'source:later.txt' }) == 'later', 'source lost a later change')
local source_history = git({ 'log', '--format=%s', 'source' })
assert(not source_history:find('selected', 1, true), 'harvest left the selected source commit')

local donated = commit('donated.txt', 'donated', 'donated')
ok, err = move.donate(root, donated, 'source')
assert(ok, err)
assert(git({ 'branch', '--show-current' }) == 'main', 'donate changed the current branch')
assert(vim.fn.filereadable(root .. '/donated.txt') == 0, 'donate left the change on main')
assert(git({ 'show', 'source:donated.txt' }) == 'donated', 'donate did not copy the change')

local apply = require('git.features.magit_apply')
local before = git({ 'rev-parse', 'HEAD' })
ok, err = apply.apply({ work_tree = root, commit = donated }, false)
assert(ok, err)
assert(vim.fn.readfile(root .. '/donated.txt')[1] == 'donated',
  'regular apply did not write the worktree')
assert(git({ 'rev-parse', 'HEAD' }) == before, 'regular apply created a commit')
assert(git({ 'diff', '--cached', '--name-only' }) == '', 'regular apply staged the patch')
vim.fn.delete(root .. '/donated.txt')

write('staged.txt', 'staged content')
git({ 'add', 'staged.txt' })
vim.fn.delete(root .. '/staged.txt')
ok, err = apply.apply({ work_tree = root, panel = 'status',
  path = 'staged.txt', section = 'staged' }, false)
assert(ok, err)
assert(vim.fn.readfile(root .. '/staged.txt')[1] == 'staged content',
  'regular apply did not restore the selected staged patch')
assert(git({ 'diff', '--cached', '--name-only' }) == 'staged.txt',
  'regular apply changed the staged patch')
git({ 'reset', '-q', '--hard' })

local baseline = {}
for i = 1, 26 do baseline[i] = 'line ' .. i end
vim.fn.writefile(baseline, root .. '/multi.txt')
git({ 'add', 'multi.txt' })
git({ 'commit', '-qm', 'multi base' })
local changed = vim.deepcopy(baseline)
changed[2], changed[24] = 'first hunk', 'second hunk'
vim.fn.writefile(changed, root .. '/multi.txt')
git({ 'add', 'multi.txt' })
vim.fn.writefile(baseline, root .. '/multi.txt')
local renderer = require('git.features.status_renderer')
local actions = require('git.features.magit_actions')
local utils = require('git.utils')
local status = vim.api.nvim_create_buf(true, false)
utils.set_buf_work_tree(status, root)
vim.bo[status].filetype = 'gitstatus'
vim.api.nvim_set_current_buf(status)
vim.api.nvim_buf_set_lines(status, 0, -1, false, assert(renderer.snapshot(status, root)))
local file_row
for row = 1, vim.api.nvim_buf_line_count(status) do
  local entry = renderer.entry_at(status, row)
  if entry and entry.section == 'staged' and entry.path == 'multi.txt' then
    file_row = row; break
  end
end
assert(file_row and renderer.update_diff(status, file_row, 'show'))
local hunk_row
for row, line in ipairs(vim.api.nvim_buf_get_lines(status, 0, -1, false)) do
  if line:match('^@@') and renderer.entry_at(status, row).section == 'staged' then
    hunk_row = row; break
  end
end
assert(hunk_row, 'staged fixture did not display a hunk')
vim.api.nvim_win_set_cursor(0, { file_row, 0 })
assert(apply.context(status, hunk_row).hunk, 'apply context ignored its explicit row')
vim.api.nvim_win_set_cursor(0, { hunk_row, 0 })
actions.attach(status)
local function press(key)
  local mapping = vim.fn.maparg(key, 'n', false, true)
  assert(type(mapping.callback) == 'function', 'missing menu key ' .. key)
  mapping.callback()
end
press('<Space><Space>')
press('a')
assert(vim.api.nvim_get_current_buf() == status,
  'apply did not return to the selected staged hunk')
local applied = vim.fn.readfile(root .. '/multi.txt')
assert(applied[2] == 'first hunk' and applied[24] == baseline[24],
  'regular apply changed more than the selected staged hunk')
require('git.features.magit_apply').setup()
vim.api.nvim_set_current_buf(status)
vim.api.nvim_buf_set_lines(status, 0, -1, false, assert(renderer.snapshot(status, root)))
for row, line in ipairs(vim.api.nvim_buf_get_lines(status, 0, -1, false)) do
  local entry = renderer.entry_at(status, row)
  if line:match('^@@') and entry and entry.section == 'staged' then
    vim.api.nvim_win_set_cursor(0, { row, 0 }); break
  end
end
press('<Space><Space>')
press('v')
assert(vim.b[vim.api.nvim_get_current_buf()].git_action_menu_kind == 'apply-variants',
  'status v did not open apply variants')
press('v')
assert(vim.deep_equal(vim.fn.readfile(root .. '/multi.txt'), baseline),
  'apply variants did not reverse the selected staged hunk')
vim.api.nvim_set_current_buf(status)
vim.api.nvim_buf_set_lines(status, 0, -1, false, assert(renderer.snapshot(status, root)))
for row, line in ipairs(vim.api.nvim_buf_get_lines(status, 0, -1, false)) do
  local entry = renderer.entry_at(status, row)
  if line:match('^@@') and entry and entry.section == 'staged' then
    vim.api.nvim_win_set_cursor(0, { row, 0 }); break
  end
end
vim.cmd('GitApply')
assert(vim.fn.readfile(root .. '/multi.txt')[2] == 'first hunk',
  'GitApply from status did not apply the selected staged hunk')
vim.api.nvim_buf_set_lines(status, 0, -1, false, assert(renderer.snapshot(status, root)))
for row, line in ipairs(vim.api.nvim_buf_get_lines(status, 0, -1, false)) do
  local entry = renderer.entry_at(status, row)
  if line:match('^@@') and entry and entry.section == 'staged' then
    vim.api.nvim_win_set_cursor(0, { row, 0 }); break
  end
end
vim.cmd('GitReverse')
assert(vim.deep_equal(vim.fn.readfile(root .. '/multi.txt'), baseline),
  'GitReverse from status did not reverse the selected staged hunk')
vim.api.nvim_buf_delete(status, { force = true })
git({ 'reset', '-q', '--hard' })

git({ 'switch', '-qc', 'tip-source' })
local tip = commit('tip.txt', 'tip', 'tip')
git({ 'switch', '-q', 'main' })
ok, err = move.harvest(root, tip, 'tip-source')
assert(ok, err)
assert(git({ 'rev-parse', 'tip-source' }) == git({ 'rev-parse', 'main^' }),
  'harvest did not move a source branch at the selected tip')
write('dirty.txt', 'dirty')
ok, err = move.donate(root, tip, 'source')
assert(not ok and err:find('worktree changes', 1, true),
  'donate accepted a dirty worktree')
vim.fn.delete(root .. '/dirty.txt')

local other = vim.fn.tempname()
git({ 'worktree', 'add', '-q', '-b', 'occupied', other, 'main' })
local other_commit = vim.system({ 'git', '-C', other, 'commit', '--allow-empty', '-qm',
  'occupied commit' }, { text = true }):wait()
assert(other_commit.code == 0, other_commit.stderr)
local occupied = git({ 'rev-parse', 'occupied' })
ok, err = move.harvest(root, occupied, 'occupied')
assert(not ok and err:find('another worktree', 1, true),
  'harvest rewrote a branch checked out in another worktree')
git({ 'worktree', 'remove', other })

vim.fn.delete(root, 'rf')
print('PASS: harvest, donate, and regular apply preserve branch and index semantics')
