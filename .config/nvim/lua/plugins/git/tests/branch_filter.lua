-- Run from the plugin root: nvim --headless --clean -u NONE -l tests/branch_filter.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path

local root = vim.fn.tempname() .. ' branch-filter'
vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout or '')
end
local function names(bufnr)
  return vim.b[bufnr].branch_map or {}
end
local function row_for(bufnr, name)
  for row, item in ipairs(names(bufnr)) do
    if item == name then return row end
  end
end
local function row_for_kind(bufnr, name, kind)
  for row, item in ipairs(names(bufnr)) do
    if item == name and (vim.b[bufnr].branch_kinds or {})[row] == kind then return row end
  end
end
local function press(key)
  local mapping = vim.fn.maparg(key, 'n', false, true)
  assert(type(mapping.callback) == 'function', 'missing mapping ' .. key)
  mapping.callback()
end

git({ 'init', '-q', '-b', 'main' })
git({ 'config', 'user.name', 'Test' })
git({ 'config', 'user.email', 'test@example.invalid' })
vim.fn.writefile({ 'base' }, root .. '/file.txt')
git({ 'add', '.' })
git({ 'commit', '-qm', 'base' })
git({ 'branch', 'feature' })
local tip = git({ 'rev-parse', 'HEAD' })
git({ 'update-ref', 'refs/remotes/origin/main', tip })
git({ 'update-ref', 'refs/remotes/upstream/feature', tip })
git({ 'symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main' })
git({ 'tag', 'release' })
git({ 'tag', '-am', 'annotated release', 'v1' })
git({ 'tag', 'feature' })

vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/file.txt'))
require('git.features.branch').setup(vim.api.nvim_create_augroup('BranchFilterTest', { clear = true }))
vim.cmd('Gbranch')
local bufnr = vim.api.nvim_get_current_buf()
assert(vim.b[bufnr].branch_filter == 'all')
assert(row_for(bufnr, 'main') and row_for(bufnr, 'feature')
  and row_for(bufnr, 'origin/main') and row_for(bufnr, 'upstream/feature')
  and row_for(bufnr, 'release') and row_for(bufnr, 'v1'), 'All omitted refs')
assert(row_for_kind(bufnr, 'feature', 'local_') and row_for_kind(bufnr, 'feature', 'tags'),
  'same-name branch and tag were not kept distinct')
assert(not row_for(bufnr, 'origin/HEAD'), 'remote symbolic HEAD appeared as a branch')
assert(vim.b[bufnr].branch_kinds[row_for(bufnr, 'release')] == 'tags')
assert(not vim.bo[bufnr].modifiable, 'branch panel became editable')

vim.api.nvim_win_set_cursor(0, { row_for(bufnr, 'feature'), 0 })
press('gl')
assert(vim.b[bufnr].branch_filter == 'local_' and #names(bufnr) == 2)
assert(row_for(bufnr, 'feature') == vim.fn.line('.'), 'selected branch moved during filtering')
assert(not row_for(bufnr, 'release') and not row_for(bufnr, 'origin/main'))
assert(vim.fn.maparg('gr', 'n', false, true).nowait == 1,
  'remote filter must not wait for longer gr-prefixed mappings')
press('gr')
assert(vim.b[bufnr].branch_filter == 'remote' and #names(bufnr) == 2,
  vim.inspect({ vim.b[bufnr].branch_filter, names(bufnr) }))
assert(row_for(bufnr, 'origin/main') and row_for(bufnr, 'upstream/feature'))
press('gt')
assert(vim.b[bufnr].branch_filter == 'tags' and #names(bufnr) == 3)
assert(row_for(bufnr, 'release') and row_for(bufnr, 'v1'))
vim.api.nvim_win_set_cursor(0, { row_for_kind(bufnr, 'feature', 'tags'), 0 })
local logged_ref
vim.api.nvim_create_user_command('FugitiveLog', function(opts) logged_ref = opts.args end, { nargs = '*' })
press('L')
assert(logged_ref == 'refs/tags/feature', 'tag log did not use an unambiguous tag ref')
local input = vim.fn.input
local prompted = false
vim.fn.input = function() prompted = true; return 'main' end
press('cou')
vim.fn.input = input
assert(not prompted, 'tag accepted branch upstream action')
local confirm = vim.fn.confirm
vim.fn.confirm = function() error('tag accepted branch deletion') end
press('X')
vim.fn.confirm = confirm
press('R')
assert(vim.b[bufnr].branch_filter == 'tags' and row_for(bufnr, 'release'),
  'refresh lost the active filter')
press('ga')
assert(vim.b[bufnr].branch_filter == 'all' and row_for(bufnr, 'main')
  and row_for(bufnr, 'release'), 'All did not restore branches and tags')
assert(not vim.bo[bufnr].modifiable, 'filtering made the panel editable')
git({ 'tag', '-d', 'release', 'v1', 'feature' })
press('gt')
assert(vim.b[bufnr].branch_filter == 'tags' and #names(bufnr) == 0,
  'an empty tag view should remain usable')
vim.api.nvim__redraw({ flush = true })

vim.api.nvim_buf_delete(bufnr, { force = true })
vim.fn.delete(root, 'rf')
print('PASS: branch reference filters, tags, cursor, and branch action guard')
