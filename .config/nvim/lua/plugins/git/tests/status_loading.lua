local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
vim.g.git_status_auto_fetch = false
package.loaded['git.features.status_watch'] = { subscribe = function() return function() end end }
package.loaded['git.features.worktree_watch'] = { subscribe = function() return function() end end }
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid' }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end
git({ 'init', '-qb', 'main' })
git({ 'commit', '--allow-empty', '-qm', 'initial' })
local system, executable = vim.system, vim.fn.executable
local github
vim.fn.executable = function(name) return name == 'gh' and 1 or executable(name) end
vim.system = function(argv, opts, callback)
  if argv[1] == 'gh' then github = callback; return {} end
  return system(argv, opts, callback)
end
local modules = require('git.features.status_modules')
local loading = require('git.features.loading')
local requests = {}
modules.setup({
  { id = 'first', title = 'First shelf', before = 'commits', load = function(_, done) requests.first = done end },
  { id = 'second', title = 'Second shelf', before = 'commits', load = function(_, done) requests.second = done end },
})
local status = require('git.features.status')
status.setup(vim.api.nvim_create_augroup('StatusLoadingTest', { clear = true }))
local buf = status.open({ work_tree = root, split = true })
local function wait(fn) assert(vim.wait(5000, fn, 10), 'Status did not settle') end
local function text() return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end
assert(loading.busy(buf), 'Initial async status was not tracked')
wait(function() return github and requests.first and requests.second and text():find('Commits %[latest') end)
requests.second({ { id = 'b', text = 'Second item' } })
wait(function() return text():find('Second item', 1, true) end)
assert(not text():find('Loading', 1, true) and not text():find('First shelf', 1, true),
  'Pending work introduced loading rows or an empty shelf')
wait(function() return loading.status(buf) ~= '' end)
requests.first({ { id = 'a', text = 'First item' } })
wait(function() return text():find('First item', 1, true) end)
-- Let full repository enrichment run after both shelves have been published.
vim.wait(500, function() return false end, 10)
local contents = text()
assert(contents:find('First item') < contents:find('Second item')
  and contents:find('Second item') < contents:find('Commits %[latest'), 'Enrichment lost shelf placement/order')
assert(loading.busy(buf) and loading.status(buf) ~= '', 'Other completions hid the pending PR request')
github({ code = 1, stderr = 'fixture request failed' })
wait(function() return not loading.busy(buf) end)
wait(function() return loading.status(buf) == '' end)
modules.refresh(buf)
assert(loading.busy(buf))
vim.api.nvim_buf_delete(buf, { force = true })
assert(not loading.busy(buf) and loading.status(buf) == '', 'Closing Status retained its display')
vim.wait(20, function() return false end)
vim.system, vim.fn.executable = system, executable
modules.setup({})
-- Failure before the first native snapshot must also settle its loading token.
local renderer = require('git.features.status_renderer')
local snapshot_async = renderer.snapshot_async
renderer.snapshot_async = function(_, _, _, done) vim.schedule(function() done(nil, 'fixture failure') end) end
vim.fn.executable = function(name) return name == 'gh' and 0 or executable(name) end
local failed = status.open({ work_tree = root, split = true })
wait(function() return not loading.busy(failed) end)
vim.api.nvim_buf_delete(failed, { force = true })
renderer.snapshot_async, vim.fn.executable = snapshot_async, executable
vim.fn.delete(root, 'rf')
print('PASS: shared initial/shelf/PR loading survives ordered rendering and enrichment, request failure and close')
