local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local function git(cwd, args)
  local argv = { 'git', '-C', cwd, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid' }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
git(root, { 'init', '-q' })
git(root, { 'remote', 'add', 'origin', root })
vim.fn.writefile({ 'old' }, root .. '/file.txt')
git(root, { 'add', '.' })
git(root, { 'commit', '-qm', 'initial' })
vim.fn.writefile({ 'new' }, root .. '/file.txt')
local executable = vim.fn.executable
vim.fn.executable = function(name) return name == 'gh' and 0 or executable(name) end
local status = require('git.features.status')
status.setup(vim.api.nvim_create_augroup('StatusExternalTest', { clear = true }))
local b = status.open({ work_tree = root, split = true })
local function contents(buf) return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end
assert(vim.wait(5000, function() return contents(b):find('M file.txt', 1, true) and not contents(b):find('Loading') end, 20))
git(root, { 'add', '.' })
git(root, { 'commit', '-qm', 'external commit' })
assert(vim.wait(5000, function()
  return contents(b):find('external commit', 1, true) and not contents(b):find('M file.txt', 1, true)
end, 20), 'visible status ignored external commit')
-- Unchanged metadata must settle without repeatedly launching Git commands.
vim.wait(2000, function() return false end)
local system, calls = vim.system, 0
vim.system = function(...) calls = calls + 1; return system(...) end
vim.wait(2200, function() return false end)
assert(calls == 0, 'metadata monitor repeatedly refreshed unchanged status')
vim.system = system
-- Hidden buffers invalidate their warm cache too.
vim.fn.maparg('q', 'n', false, true).callback()
git(root, { 'commit', '--allow-empty', '-qm', 'hidden external commit' })
vim.wait(1500, function() return false end)
assert(status.open({ work_tree = root, split = true }) == b)
assert(vim.wait(5000, function() return contents(b):find('hidden external commit', 1, true) end, 20))
-- Linked worktrees update a ref in the common Git directory, not their HEAD file.
local linked = root .. '-linked'
git(root, { 'worktree', 'add', '-qb', 'linked-test', linked })
local linked_buf = status.open({ work_tree = linked, split = true })
assert(vim.wait(5000, function() return not contents(linked_buf):find('Loading') end, 20))
git(linked, { 'commit', '--allow-empty', '-qm', 'linked external commit' })
assert(vim.wait(5000, function() return contents(linked_buf):find('linked external commit', 1, true) end, 20))
vim.api.nvim_buf_delete(linked_buf, { force = true })
vim.api.nvim_buf_delete(b, { force = true })
-- Direct subscriptions stop notifications and tolerate duplicate cleanup.
local notifications = 0
local stop = require('git.features.status_watch').subscribe(root .. '/.git', function() notifications = notifications + 1 end)
vim.wait(200, function() return false end)
stop(); stop()
git(root, { 'commit', '--allow-empty', '-qm', 'after teardown' })
vim.wait(1200, function() return false end)
assert(notifications == 0)
vim.fn.executable = executable
vim.fn.delete(linked, 'rf')
vim.fn.delete(root, 'rf')
print('PASS: external commits in visible/hidden/linked status, idle work, and watcher cleanup')
