-- Run from the plugin root: nvim --headless --clean -u NONE -l tests/status_auto_fetch.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path

local base = vim.fn.tempname()
local origin, seed, local_root, publisher = base .. '/origin.git', base .. '/seed', base .. '/local', base .. '/publisher'
vim.fn.mkdir(base, 'p')
local function git(root, args)
  local argv = { 'git', '-C', root }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout or '')
end

git(base, { 'init', '--bare', '-q', '-b', 'main', origin })
git(base, { 'init', '-q', '-b', 'main', seed })
git(seed, { 'config', 'user.name', 'Test' })
git(seed, { 'config', 'user.email', 'test@example.invalid' })
vim.fn.writefile({ 'initial' }, seed .. '/file.txt')
git(seed, { 'add', '.' })
git(seed, { 'commit', '-qm', 'initial' })
git(seed, { 'remote', 'add', 'origin', origin })
git(seed, { 'push', '-qu', 'origin', 'main' })
git(base, { 'clone', '-q', origin, local_root })
git(base, { 'clone', '-q', origin, publisher })
git(publisher, { 'config', 'user.name', 'Publisher' })
git(publisher, { 'config', 'user.email', 'publisher@example.invalid' })
vim.fn.writefile({ 'updated remotely' }, publisher .. '/file.txt')
git(publisher, { 'commit', '-qam', 'remote update' })
local remote_tip = git(publisher, { 'rev-parse', 'HEAD' })
git(publisher, { 'push', 'origin', 'main' })
local initial_remote_tip = git(local_root, { 'rev-parse', 'refs/remotes/origin/main' })
assert(initial_remote_tip ~= remote_tip, 'local clone already has the remote update')

local auto_fetch_event = false
vim.api.nvim_create_autocmd('User', {
  pattern = 'FugitiveChanged',
  callback = function(ev)
    if ev.data and ev.data.reason == 'status-auto-fetch' then auto_fetch_event = true end
  end,
})
local status = require('git.features.status')
status.setup(vim.api.nvim_create_augroup('StatusAutoFetchTest', { clear = true }))
local bufnr = assert(status.open({ work_tree = local_root, split = true }))
assert(git(local_root, { 'rev-parse', 'refs/remotes/origin/main' }) == initial_remote_tip,
  'status open waited for fetch to finish')
assert(vim.wait(10000, function()
  return git(local_root, { 'rev-parse', 'refs/remotes/origin/main' }) == remote_tip
end, 20), 'opening status did not fetch the configured remote')
assert(vim.wait(5000, function() return auto_fetch_event end, 20),
  'successful auto-fetch did not refresh repository consumers')

vim.api.nvim_buf_delete(bufnr, { force = true })
vim.fn.delete(base, 'rf')
print('PASS: status opens immediately, fetches asynchronously, and refreshes after success')
