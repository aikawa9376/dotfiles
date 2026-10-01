-- Run from plugin root: nvim --headless --clean -u NONE -l tests/branch_upstream.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path

local root = vim.fn.tempname() .. ' upstream'
vim.fn.mkdir(root, 'p')
local function git(args, allow_failure)
  local command = { 'git', '-C', root }
  vim.list_extend(command, args)
  local result = vim.system(command, { text = true }):wait()
  if not allow_failure then assert(result.code == 0, result.stderr) end
  return vim.trim(result.stdout or ''), result
end
git({ 'init', '-q', '-b', 'main' })
git({ 'config', 'user.name', 'Test' })
git({ 'config', 'user.email', 'test@example.invalid' })
vim.fn.writefile({ 'base' }, root .. '/file.txt')
git({ 'add', '.' })
git({ 'commit', '-qm', 'base' })
git({ 'branch', 'feature' })
local tip = git({ 'rev-parse', 'HEAD' })
git({ 'remote', 'add', 'origin', root })
git({ 'update-ref', 'refs/remotes/origin/main', tip })
git({ 'symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main' })

vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/file.txt'))
require('git.features.branch').setup(vim.api.nvim_create_augroup('BranchUpstreamTest', { clear = true }))
vim.cmd('Gbranch')
local b = vim.api.nvim_get_current_buf()
local function row_for(name)
  for row, branch in ipairs(vim.b[b].branch_map or {}) do
    if branch == name then return row end
  end
end
local function select_branch(name)
  vim.api.nvim_win_set_cursor(0, { assert(row_for(name), name .. ' is not shown'), 0 })
end
local function press(key)
  local mapping = vim.fn.maparg(key, 'n', false, true)
  assert(type(mapping.callback) == 'function', 'missing branch mapping ' .. key)
  mapping.callback()
end

select_branch('feature')
local choices = _G.fugitive_upstream_completion('')
assert(vim.tbl_contains(choices, 'main') and vim.tbl_contains(choices, 'origin/main')
  and not vim.tbl_contains(choices, 'feature') and not vim.tbl_contains(choices, 'origin/HEAD'),
  'upstream completion did not offer local and remote branches cleanly')
assert(vim.deep_equal(_G.fugitive_upstream_completion('origin/'), { 'origin/main' }),
  'upstream completion did not filter by prefix')

local input = vim.fn.input
local prompt, default, completion
vim.fn.input = function(p, d, c)
  prompt, default, completion = p, d, c
  return 'origin/main'
end
press('cou')
vim.fn.input = input
assert(prompt == 'Upstream for feature: ' and default == ''
  and completion == 'customlist,v:lua.fugitive_upstream_completion',
  'set upstream did not provide branch completion')
assert(git({ 'rev-parse', '--abbrev-ref', 'feature@{upstream}' }) == 'origin/main')
assert((vim.api.nvim_buf_get_lines(b, row_for('feature') - 1, row_for('feature'), false)[1] or '')
  :find('[origin/main]', 1, true), 'branch panel did not refresh after setting upstream')
assert(git({ 'branch', '--show-current' }) == 'main', 'changing another branch checked it out')

select_branch('feature')
vim.fn.input = function(p, d, c)
  prompt, default, completion = p, d, c
  return 'main'
end
press('cou')
vim.fn.input = input
assert(default == 'origin/main' and git({ 'rev-parse', '--abbrev-ref', 'feature@{upstream}' }) == 'main',
  'set upstream did not replace an existing upstream')

select_branch('feature')
press('coU')
local _, missing = git({ 'rev-parse', '--abbrev-ref', 'feature@{upstream}' }, true)
assert(missing.code ~= 0, 'unset upstream kept the tracking branch')
assert(not (vim.api.nvim_buf_get_lines(b, row_for('feature') - 1, row_for('feature'), false)[1] or '')
  :find('[main]', 1, true), 'branch panel did not refresh after clearing upstream')
press('coU')
assert(git({ 'branch', '--show-current' }) == 'main', 'no-op unset changed branches')

select_branch('feature')
vim.fn.input = function() return 'missing-ref' end
press('cou')
vim.fn.input = input
_, missing = git({ 'rev-parse', '--abbrev-ref', 'feature@{upstream}' }, true)
assert(missing.code ~= 0, 'invalid upstream changed branch configuration')

select_branch('origin/main')
local called = false
vim.fn.input = function() called = true; return 'main' end
press('cou')
vim.fn.input = input
assert(not called, 'remote branch was accepted for upstream configuration')
assert(git({ 'branch', '--show-current' }) == 'main')

select_branch('feature')
vim.fn.input = function() return 'origin/main' end
press('cou')
vim.fn.input = input
git({ 'update-ref', '-d', 'refs/remotes/origin/main' })
press('coU')
local _, stale = git({ 'config', '--get', 'branch.feature.merge' }, true)
assert(stale.code ~= 0, 'unset did not clear an upstream whose remote ref disappeared')

vim.api.nvim_buf_delete(b, { force = true })
vim.fn.delete(root, 'rf')
print('PASS: branch upstream set/unset, completion, remote-row guard, and panel refresh')
