-- Run from the plugin root: nvim --headless --clean -u NONE -l tests/branch_delete.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path

local root = vim.fn.tempname() .. ' branch-delete'
local remote_root = vim.fn.tempname() .. ' branch-delete-remote'
vim.fn.mkdir(root, 'p')
local function run(cwd, args)
  local argv = { 'git', '-C', cwd }
  vim.list_extend(argv, args)
  return vim.system(argv, { text = true }):wait()
end
local function git(args)
  local result = run(root, args)
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout or '')
end
local function exists(ref, cwd)
  return run(cwd or root, { 'show-ref', '--verify', '--quiet', ref }).code == 0
end
local function press(key, mode)
  local mapping = vim.fn.maparg(key, mode or 'n', false, true)
  assert(type(mapping.callback) == 'function', 'missing mapping ' .. key)
  mapping.callback()
end

git({ 'init', '-q', '-b', 'main' })
git({ 'config', 'user.name', 'Test' })
git({ 'config', 'user.email', 'test@example.invalid' })
vim.fn.writefile({ 'base' }, root .. '/file.txt')
git({ 'add', '.' })
git({ 'commit', '-qm', 'base' })
git({ 'init', '--bare', '-q', remote_root })
git({ 'remote', 'add', 'origin', remote_root })
git({ 'push', '-q', 'origin', 'HEAD:refs/heads/change-treesitter-master' })
git({ 'branch', 'origin/change-treesitter-master' })
local tip = git({ 'rev-parse', 'HEAD' })

vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/file.txt'))
require('git.features.branch').setup(vim.api.nvim_create_augroup('BranchDeleteTest', { clear = true }))
vim.cmd('Gbranch')
local buf = vim.api.nvim_get_current_buf()
local function row(name, kind)
  for i, item in ipairs(vim.b[buf].branch_map or {}) do
    if item == name and (vim.b[buf].branch_kinds or {})[i] == kind then return i end
  end
  error('missing row: ' .. kind .. ' ' .. name)
end
local function select(name, kind)
  vim.api.nvim_win_set_cursor(0, { row(name, kind), 0 })
end
local confirm = vim.fn.confirm
vim.fn.confirm = function() return 2 end
select('origin/change-treesitter-master', 'remote')
press('X')
assert(exists('refs/remotes/origin/change-treesitter-master'), 'cancel deleted tracking ref')
vim.fn.confirm = function() return 1 end
press('X')
assert(not exists('refs/remotes/origin/change-treesitter-master'), 'remote X did not delete tracking ref')
assert(exists('refs/heads/origin/change-treesitter-master'), 'remote X deleted same-name local branch')
assert(exists('refs/heads/change-treesitter-master', remote_root), 'X deleted branch on remote server')
press('R')
select('origin/change-treesitter-master', 'local_')
press('X')
assert(not exists('refs/heads/origin/change-treesitter-master'), 'slash local branch treated as remote')

git({ 'branch', 'zz-local' })
git({ 'update-ref', 'refs/remotes/upstream/mixed', tip })
git({ 'tag', 'zz-tag' })
press('R')
local first, last = row('zz-local', 'local_'), row('zz-tag', 'tags')
assert(first < row('upstream/mixed', 'remote') and last == first + 2, 'unexpected selection order')
vim.api.nvim_win_set_cursor(0, { first, 0 })
vim.cmd('normal! V')
vim.api.nvim_win_set_cursor(0, { last, 0 })
press('X', 'v')
vim.cmd('normal! \27')
assert(not exists('refs/heads/zz-local') and not exists('refs/remotes/upstream/mixed'),
  'mixed Visual selection did not delete each branch in its namespace')
assert(exists('refs/tags/zz-tag') and exists('refs/heads/main'), 'Visual X deleted unselected ref or tag')

local tree = git({ 'rev-parse', 'HEAD^{tree}' })
local unmerged = git({ 'commit-tree', tree, '-p', tip, '-m', 'unmerged feature' })
git({ 'update-ref', 'refs/heads/unmerged', unmerged })
press('R')
select('unmerged', 'local_')
local prompts = 0
vim.fn.confirm = function() prompts = prompts + 1; return prompts == 1 and 1 or 2 end
press('X')
assert(prompts == 2 and exists('refs/heads/unmerged'), 'force-delete cancellation was ignored')
vim.fn.confirm = function() return 1 end
press('X')
assert(not exists('refs/heads/unmerged'), 'force delete of unmerged local branch failed')
assert(git({ 'rev-parse', 'HEAD' }) == tip and vim.fn.readfile(root .. '/file.txt')[1] == 'base',
  'branch deletion changed HEAD or worktree')
vim.fn.confirm = confirm
vim.api.nvim_buf_delete(buf, { force = true })
vim.fn.delete(root, 'rf')
vim.fn.delete(remote_root, 'rf')
print('PASS: local/remote X, colliding names, mixed Visual selection, cancellation and force delete')
