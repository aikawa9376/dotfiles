local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
vim.opt.rtp:prepend(vim.fn.stdpath('data') .. '/lazy/gitsigns.nvim')
require('gitsigns').setup({ update_debounce = 10 })
local objects = require('git.objects')
local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid' }
  vim.list_extend(argv, args)
  local result = vim.system(argv):wait(); assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout or '')
end
git({ 'init', '-q' })
vim.fn.writefile({ 'one', 'two' }, root .. '/file.txt')
git({ 'add', '.' }); git({ 'commit', '-qm', 'first' })
vim.fn.writefile({ 'one', 'changed' }, root .. '/file.txt')
git({ 'add', '.' }); git({ 'commit', '-qm', 'second' })
local main_branch = git({ 'symbolic-ref', '--short', 'HEAD' })
git({ 'checkout', '-qb', 'feature', 'HEAD^' })
vim.fn.writefile({ 'branch', 'two' }, root .. '/file.txt')
git({ 'add', '.' }); git({ 'commit', '-qm', 'feature change' })
git({ 'checkout', '-q', main_branch })
require('git').setup()
objects.open('HEAD:file.txt', 'edit', root)
assert(vim.wait(2000, function()
  local status = vim.b.gitsigns_status_dict
  return status and status.changed == 1
end, 10), 'Historical Gedit blob should compare against its parent')
local signs_ns = vim.api.nvim_get_namespaces().gitsigns_signs_
assert(vim.wait(2000, function()
  return signs_ns and #vim.api.nvim_buf_get_extmarks(0, signs_ns, 0, -1, {}) > 0
end, 10), 'Gitsigns should place visible signs, not just status counts')
assert(vim.api.nvim_buf_get_name(0):match('^git%-object://'), 'Gedit uses the shared object URI')
objects.open('feature:file.txt', 'edit', root)
local branch_ok = vim.wait(2000, function()
  local status = vim.b.gitsigns_status_dict
  return status and (status.added or 0) + (status.changed or 0) + (status.removed or 0) > 1
end, 10)
assert(branch_ok, 'Another branch should compare its file with the current HEAD file: ' .. vim.inspect(vim.b.gitsigns_status_dict))
assert(require('gitsigns.cache').cache[vim.api.nvim_get_current_buf()].git_obj.revision == 'HEAD')
assert(#vim.api.nvim_buf_get_extmarks(0, signs_ns, 0, -1, {}) > 0)
objects.open(':0:file.txt', 'edit', root)
assert(vim.wait(2000, function() return vim.b.gitsigns_status_dict ~= nil end, 10), 'Index blob should attach Gitsigns')
vim.fn.delete(root, 'rf')
print('PASS: Gedit blob Gitsigns parent, other branch and index comparison')
