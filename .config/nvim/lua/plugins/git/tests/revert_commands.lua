local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false' }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr); return vim.trim(result.stdout or '')
end
git({ 'init', '-qb', 'main' })
git({ 'config', 'user.name', 'Test' }); git({ 'config', 'user.email', 'test@example.invalid' })
git({ 'config', 'commit.gpgsign', 'false' })
vim.fn.writefile({ 'base' }, root .. '/file.txt')
git({ 'add', '.' }); git({ 'commit', '-qm', 'base' })
vim.fn.writefile({ 'changed' }, root .. '/file.txt')
git({ 'commit', '-qam', 'change' }); local change = git({ 'rev-parse', 'HEAD' })
vim.fn.writefile({ 'other' }, root .. '/other.txt')
git({ 'add', '.' }); git({ 'commit', '-qm', 'other' }); local other = git({ 'rev-parse', 'HEAD' })
require('git.utils').set_buf_work_tree(0, root)
local commands = require('git.features.commands')
local events, completed = 0, 0
vim.api.nvim_create_autocmd('User', { pattern = 'GitChanged', callback = function(ev)
  assert(ev.data.work_tree == root); events = events + 1
end })
commands.revert_commits({ other }, function() completed = completed + 1 end)
assert(vim.wait(1000, function() return completed == 1 end))
assert(events == 1, 'successful revert did not refresh repository panels')
assert(vim.fn.filereadable(root .. '/other.txt') == 0)
git({ 'reset', '--hard', other })
vim.fn.writefile({ 'later' }, root .. '/file.txt')
git({ 'commit', '-qam', 'later' }); local head = git({ 'rev-parse', 'HEAD' })
local revert_attempts = 0
local system = vim.system
vim.system = function(args, ...)
  if vim.tbl_contains(args, 'revert') then revert_attempts = revert_attempts + 1 end
  return system(args, ...)
end
commands.revert_commits({ change, other }, function() completed = completed + 1 end)
vim.system = system
vim.wait(30, function() return false end)
assert(events == 2, 'failed revert did not refresh conflict state')
assert(revert_attempts == 1, 'revert continued after a conflict')
assert(completed == 1 and git({ 'rev-parse', 'HEAD' }) == head)
assert(vim.fn.filereadable(root .. '/other.txt') == 1, 'later selected commit was reverted after a conflict')
git({ 'revert', '--abort' })
-- A merge keeps main's changes and removes only the merged side, via -m 1.
git({ 'checkout', '-qb', 'side', change })
vim.fn.writefile({ 'side' }, root .. '/side.txt')
git({ 'add', '.' }); git({ 'commit', '-qm', 'side' })
git({ 'checkout', 'main' }); git({ 'merge', '--no-ff', '-m', 'merge side', 'side' })
local merge = git({ 'rev-parse', 'HEAD' })
commands.revert_commits({ merge }, function() completed = completed + 1 end)
assert(vim.wait(1000, function() return completed == 2 end))
assert(events == 3 and vim.fn.filereadable(root .. '/side.txt') == 0)
assert(vim.fn.readfile(root .. '/file.txt')[1] == 'later', 'merge revert used the wrong parent')
-- A later invalid target must still publish the earlier successful mutation.
commands.revert_commits({ other, 'invalid-revision' }, function() completed = completed + 1 end)
assert(vim.wait(1000, function() return events == 4 end))
assert(completed == 2)
assert(vim.fn.filereadable(root .. '/other.txt') == 0)
vim.fn.delete(root, 'rf')
print('PASS: cold revert, success/conflict/partial-failure notifications, stopping and merge mainline')
