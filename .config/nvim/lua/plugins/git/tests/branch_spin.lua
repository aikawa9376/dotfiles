-- Run: nvim --headless --clean -u NONE -l tests/branch_spin.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path

local spin = require('git.features.branch_spin')
local roots = {}
local function git(root, args, allow_failure)
  local command = { 'git', '-C', root }
  vim.list_extend(command, args)
  local result = vim.system(command, { text = true }):wait()
  if not allow_failure then assert(result.code == 0, result.stderr) end
  return vim.trim(result.stdout or ''), result
end

local function fixture()
  local root = vim.fn.tempname()
  table.insert(roots, root)
  vim.fn.mkdir(root, 'p')
  git(root, { 'init', '-q', '-b', 'main' })
  git(root, { 'config', 'user.name', 'Test' })
  git(root, { 'config', 'user.email', 'test@example.invalid' })
  vim.fn.writefile({ 'base' }, root .. '/file.txt')
  git(root, { 'add', '.' })
  git(root, { 'commit', '-qm', 'base' })
  local base = git(root, { 'rev-parse', 'HEAD' })
  git(root, { 'remote', 'add', 'origin', root })
  git(root, { 'update-ref', 'refs/remotes/origin/main', base })
  git(root, { 'branch', '--set-upstream-to=origin/main', 'main' })
  vim.fn.writefile({ 'base', 'one' }, root .. '/file.txt')
  git(root, { 'commit', '-qam', 'one' })
  vim.fn.writefile({ 'base', 'one', 'two' }, root .. '/file.txt')
  git(root, { 'commit', '-qam', 'two' })
  return root, base, git(root, { 'rev-parse', 'HEAD' })
end

local root, base, tip = fixture()
local first = git(root, { 'rev-parse', 'HEAD^' })
local selected = assert(spin.plan(root, 'spinout', tip))
assert(selected.base == first and selected.from == tip)
assert(spin.run(root, 'last-only', 'spinout', selected))
assert(git(root, { 'rev-parse', 'main' }) == first)
assert(git(root, { 'rev-parse', 'last-only' }) == tip)

root, base, tip = fixture()
local initial = git(root, { 'rev-parse', 'HEAD~2' })
assert(not spin.plan(root, 'spinoff', initial), 'upstream commit was accepted as FROM')
assert(not spin.plan(root, 'spinoff', 'missing-commit'), 'unknown FROM was accepted')

root, base, tip = fixture()
local plan = assert(spin.plan(root, 'spinoff'))
assert(plan.branch == 'main' and plan.base == base and plan.ahead == 2 and plan.checkout)
local result = assert(spin.run(root, 'feature', 'spinoff', plan))
assert(result.checkout and git(root, { 'branch', '--show-current' }) == 'feature')
assert(git(root, { 'rev-parse', 'main' }) == base and git(root, { 'rev-parse', 'feature' }) == tip)
assert(git(root, { 'rev-parse', '--abbrev-ref', 'feature@{upstream}' }) == 'main')
assert(vim.fn.readfile(root .. '/file.txt')[3] == 'two', 'spinoff lost the new branch worktree')

root, base, tip = fixture()
result = assert(spin.run(root, 'feature', 'spinout'))
assert(not result.checkout and git(root, { 'branch', '--show-current' }) == 'main')
assert(git(root, { 'rev-parse', 'main' }) == base and git(root, { 'rev-parse', 'feature' }) == tip)
assert(git(root, { 'rev-parse', '--abbrev-ref', 'feature@{upstream}' }) == 'main')
assert(#vim.fn.readfile(root .. '/file.txt') == 1, 'spinout did not restore the source worktree')

root, base, tip = fixture()
vim.fn.writefile({ 'base', 'one', 'two', 'staged' }, root .. '/file.txt')
git(root, { 'add', 'file.txt' })
vim.fn.writefile({ 'base', 'one', 'two', 'staged', 'unstaged' }, root .. '/file.txt')
vim.fn.writefile({ 'untracked' }, root .. '/new.txt')
local before = git(root, { 'status', '--porcelain=v1', '--untracked-files=all' })
plan = assert(spin.plan(root, 'spinout'))
assert(plan.dirty and plan.checkout)
result = assert(spin.run(root, 'feature', 'spinout', plan))
assert(result.checkout and git(root, { 'branch', '--show-current' }) == 'feature')
assert(git(root, { 'rev-parse', 'main' }) == base and git(root, { 'rev-parse', 'feature' }) == tip)
assert(git(root, { 'status', '--porcelain=v1', '--untracked-files=all' }) == before,
  'dirty spinout did not carry staged, unstaged, and untracked changes')

root, base, tip = fixture()
git(root, { 'branch', '--unset-upstream' })
result = assert(spin.run(root, 'feature', 'spinout'))
assert(not result.base and git(root, { 'rev-parse', 'main' }) == tip)
assert(git(root, { 'branch', '--show-current' }) == 'main')
assert(git(root, { 'rev-parse', '--abbrev-ref', 'feature@{upstream}' }) == 'main')
assert(not spin.run(root, 'feature', 'spinoff'), 'existing destination was overwritten')
assert(not spin.run(root, 'bad name', 'spinoff'), 'invalid branch name was accepted')
plan = assert(spin.plan(root, 'spinoff'))
vim.fn.writefile({ 'changed' }, root .. '/file.txt')
assert(not spin.run(root, 'later', 'spinoff', plan), 'stale plan was accepted')
local _, later = git(root, { 'show-ref', '--verify', '--quiet', 'refs/heads/later' }, true)
assert(later.code ~= 0, 'stale plan created a branch')

root, base, tip = fixture()
local old_cwd = vim.fn.getcwd()
vim.cmd('cd ' .. vim.fn.fnameescape(root))
require('git.features.branch').setup(vim.api.nvim_create_augroup('BranchSpinTest', { clear = true }))
assert(vim.fn.exists(':GbranchSpinoff') == 2 and vim.fn.exists(':GbranchSpinout') == 2,
  'branch spin commands were not registered')
vim.cmd('Gbranch')
local branch_buf = vim.api.nvim_get_current_buf()
assert(vim.fn.maparg('bs', 'n', false, true).callback, 'branch list has no spin-off action')
assert(vim.fn.maparg('bS', 'n', false, true).callback, 'branch list has no spin-out action')
local input, confirm = vim.fn.input, vim.fn.confirm
vim.fn.input = function() return 'ui-feature' end
vim.fn.confirm = function() return 1 end
vim.fn.maparg('bs', 'n', false, true).callback()
vim.fn.input, vim.fn.confirm = input, confirm
assert(git(root, { 'branch', '--show-current' }) == 'ui-feature', 'branch list spin-off did not check out')
assert(git(root, { 'rev-parse', 'main' }) == base and git(root, { 'rev-parse', 'ui-feature' }) == tip)
vim.api.nvim_buf_delete(branch_buf, { force = true })
vim.cmd('cd ' .. vim.fn.fnameescape(old_cwd))

root, base, tip = fixture()
vim.cmd('cd ' .. vim.fn.fnameescape(root))
vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/file.txt'))
require('git.features.commands').setup()
require('git.features.log').setup(vim.api.nvim_create_augroup('BranchSpinLogTest', { clear = true }))
vim.cmd('FugitiveLog')
local log_buf = vim.api.nvim_get_current_buf()
local log_map = vim.fn.maparg('bS', 'n', false, true)
assert(log_map.callback, 'log has no spin-out action')
local tip_row
for row, line in ipairs(vim.api.nvim_buf_get_lines(log_buf, 0, -1, false)) do
  if line:match('^' .. tip:sub(1, 7)) then tip_row = row; break end
end
assert(tip_row, 'log did not show tip commit')
vim.api.nvim_win_set_cursor(0, { tip_row, 0 })
input, confirm = vim.fn.input, vim.fn.confirm
vim.fn.input = function() return 'log-feature' end
vim.fn.confirm = function() return 1 end
log_map.callback()
vim.fn.input, vim.fn.confirm = input, confirm
assert(git(root, { 'rev-parse', 'main' }) == git(root, { 'rev-parse', tip .. '^' }),
  'log spin-out ignored the commit boundary')
assert(git(root, { 'rev-parse', 'log-feature' }) == tip)
vim.api.nvim_buf_delete(log_buf, { force = true })
vim.cmd('cd ' .. vim.fn.fnameescape(old_cwd))

for _, path in ipairs(roots) do vim.fn.delete(path, 'rf') end
print('PASS: spin-off, clean/dirty spin-out, tracking, no upstream, validation, and stale plans')
