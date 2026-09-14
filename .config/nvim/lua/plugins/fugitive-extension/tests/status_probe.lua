local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
-- Deliberately disable OS notifications: editor events must be sufficient.
package.loaded['features.status_watch'] = { subscribe = function() return function() end end }
package.loaded['features.worktree_watch'] = { subscribe = function() return function() end end }
local root = vim.fn.tempname()
vim.fn.mkdir(root .. '/nested', 'p')
local function git(args)
  local argv = { 'git', '-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid' }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end
git({ 'init', '-q' })
git({ 'remote', 'add', 'origin', root })
vim.fn.writefile({ 'one' }, root .. '/nested/a file.txt')
git({ 'add', '.' })
git({ 'commit', '-qm', 'initial' })
local executable = vim.fn.executable
vim.fn.executable = function(name) return name == 'gh' and 0 or executable(name) end
local status = require('features.status')
status.setup(vim.api.nvim_create_augroup('StatusProbeTest', { clear = true }))
local b = status.open({ work_tree = root, split = true })
local function contents() return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), '\n') end
assert(vim.wait(5000, function() return not contents():find('Loading') end, 20))
local function event(name) vim.api.nvim_exec_autocmds(name, { buffer = b }) end
local function additions()
  local renderer = require('features.status_renderer')
  for row = 1, vim.api.nvim_buf_line_count(b) do
    local entry = renderer.entry_at(b, row)
    if entry and entry.path == 'nested/a file.txt' then return entry.additions end
  end
end
-- A different editor saves a tracked file without touching the index.
vim.fn.writefile({ 'one', 'two' }, root .. '/nested/a file.txt')
event('FocusGained')
assert(vim.wait(5000, function() return additions() == 1 end, 20))
-- Same porcelain status, different content: file metadata must invalidate it.
vim.fn.writefile({ 'one', 'two', 'three' }, root .. '/nested/a file.txt')
event('WinEnter')
assert(vim.wait(5000, function() return additions() == 2 end, 20))
vim.fn.writefile({ 'new' }, root .. '/nested/new file.txt')
event('TermLeave')
assert(vim.wait(5000, function() return contents():find('new file.txt', 1, true) end, 20))
-- External history-only rewrite works even if filesystem notifications are absent.
git({ 'commit', '--amend', '--no-edit', '--reset-author', '-m', 'rewritten externally' })
event('FocusGained')
assert(vim.wait(5000, function() return contents():find('rewritten externally', 1, true) end, 20))
vim.wait(700, function() return false end)
local system, probes, other = vim.system, 0, 0
vim.system = function(argv, ...)
  if argv[2] == '--no-optional-locks' then probes = probes + 1 else other = other + 1 end
  return system(argv, ...)
end
event('BufEnter'); event('WinEnter'); event('FocusGained')
vim.wait(700, function() return false end)
assert(probes == 1 and other == 0, 'unchanged editor events caused duplicate/full refreshes')
local before = probes
vim.wait(1200, function() return false end)
assert(probes == before and other == 0, 'probe runs periodically')
vim.system = system
-- A hidden warm cache is checked on reentry.
vim.fn.maparg('q', 'n', false, true).callback()
vim.fn.delete(root .. '/nested/new file.txt')
status.open({ work_tree = root, split = true })
assert(vim.wait(5000, function() return not contents():find('new file.txt', 1, true) end, 20))
vim.api.nvim_buf_delete(b, { force = true })
vim.fn.executable = executable
vim.fn.delete(root, 'rf')
-- Pending and scheduled probes must not outlive their owning buffer.
local callbacks, kills, changes = {}, 0, 0
vim.system = function(_, _, callback)
  callbacks[#callbacks + 1] = callback
  return { kill = function() kills = kills + 1 end }
end
local probe = require('features.status_probe').new('/tmp', function() changes = changes + 1 end)
probe.check(); probe.check()
assert(vim.wait(1000, function() return #callbacks == 1 end, 10))
probe.stop(); probe.stop()
assert(kills == 1)
callbacks[1]({ code = 0, stdout = '# branch.oid late\0' })
vim.wait(20, function() return false end)
assert(changes == 0)
probe = require('features.status_probe').new('/tmp', function() changes = changes + 1 end)
probe.check(); probe.stop()
vim.wait(20, function() return false end)
assert(#callbacks == 1, 'scheduled work started after teardown')
vim.system = system
print('PASS: editor-event revalidation for external files/history, same-status edits, warm reopen, idle and coalescing')
