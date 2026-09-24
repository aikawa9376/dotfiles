-- Run from the plugin root: nvim --headless --clean -u NONE -l tests/status_subjects.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local function git(args)
  local cmd = { 'git', '-C', root }
  vim.list_extend(cmd, args)
  local result = vim.system(cmd, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout or '')
end
git({ 'init', '-q', '-b', 'main' })
git({ 'config', 'user.name', 'Test' })
git({ 'config', 'user.email', 'test@example.invalid' })
vim.fn.writefile({ 'one' }, root .. '/file.txt')
git({ 'add', '.' })
git({ 'commit', '-qm', 'base subject' })
git({ 'remote', 'add', 'origin', root })
git({ 'update-ref', 'refs/remotes/origin/main', 'HEAD' })
git({ 'branch', '--set-upstream-to=origin/main' })
git({ 'remote', 'add', 'publish', root })
git({ 'update-ref', 'refs/remotes/publish/main', 'HEAD' })
git({ 'config', 'branch.main.pushRemote', 'publish' })
git({ 'config', 'push.default', 'current' })

local renderer = require('git.features.status_renderer')
local b = vim.api.nvim_create_buf(false, true)
local original_system = vim.system
local subject_reads = 0
vim.system = function(command, opts, callback)
  if command[1] == 'git' and command[2] == 'log' and command[3] == '-1' then
    subject_reads = subject_reads + 1
  end
  return original_system(command, opts, callback)
end
local function snapshot()
  return assert(renderer.snapshot(b, root))
end
local function fast_snapshot()
  local lines
  renderer.snapshot_async(b, root, {}, function(value, err)
    assert(value, err)
    lines = value
  end)
  assert(vim.wait(5000, function() return lines ~= nil end, 20))
  return lines
end
local first = snapshot()
assert(first[1]:find('base subject', 1, true) and first[2]:find('base subject', 1, true)
  and first[3]:find('base subject', 1, true))
assert(subject_reads == 3, 'initial snapshot should load all ref subjects')
vim.fn.writefile({ 'two' }, root .. '/file.txt')
git({ 'add', 'file.txt' })
local fast = fast_snapshot()
assert(fast[1] == first[1] and fast[2] == first[2] and fast[3] == first[3],
  'fast status dropped unchanged subjects')
assert(subject_reads == 3, 'fast status re-read subjects')
local staged = snapshot()
assert(staged[1] == first[1] and staged[2] == first[2] and staged[3] == first[3])
assert(subject_reads == 3, 'staging re-read unchanged subjects')
git({ 'commit', '-qm', 'new subject' })
local changed = snapshot()
assert(changed[1]:find('new subject', 1, true))
assert(changed[2]:find('base subject', 1, true))
assert(subject_reads == 4, 'changed HEAD did not refresh exactly once')
git({ 'update-ref', 'refs/remotes/origin/main', 'HEAD' })
changed = snapshot()
assert(changed[2]:find('new subject', 1, true))
assert(subject_reads == 5, 'advanced upstream did not refresh exactly once')
renderer.cleanup(b)
vim.system = original_system
vim.fn.delete(root, 'rf')
print('PASS: unchanged header subjects survive fast refresh and only changed refs are re-read')
