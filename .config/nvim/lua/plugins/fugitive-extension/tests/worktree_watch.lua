local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local root = vim.fn.tempname()
vim.fn.mkdir(root .. '/nested/empty/deep', 'p')
vim.fn.mkdir(root .. '/ignored/deep', 'p')
local function git(args)
  local argv = { 'git', '-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid' }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end
git({ 'init', '-q' })
vim.fn.writefile({ 'ignored/' }, root .. '/.gitignore')
vim.fn.writefile({ 'one' }, root .. '/nested/file.txt')
git({ 'add', '.' }); git({ 'commit', '-qm', 'initial' })
-- Count only worktree handles, without retaining/inspecting closed uv objects.
local factory, live_handles = vim.uv.new_fs_event, 0
vim.uv.new_fs_event = function()
  local handle = factory()
  if not debug.getinfo(2, 'S').source:find('/features/worktree_watch.lua', 1, true) then return handle end
  live_handles = live_handles + 1
  return {
    start = function(_, ...) return handle:start(...) end,
    stop = function() return handle:stop() end,
    close = function()
      assert(handle, 'double close')
      local closing = handle; handle = nil
      live_handles = live_handles - 1
      closing:close()
    end,
  }
end
local executable = vim.fn.executable
vim.fn.executable = function(name) return name == 'gh' and 0 or executable(name) end
local status = require('features.status')
status.setup(vim.api.nvim_create_augroup('WorktreeEventsTest', { clear = true }))
local b = status.open({ work_tree = root, split = true })
local function contents() return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), '\n') end
assert(vim.wait(5000, function() return live_handles == 4 and not contents():find('Loading') end, 20))
local current = vim.api.nvim_get_current_win()
-- No focus, buffer, write or shell autocommands are fired in these operations.
vim.fn.writefile({ 'one', 'two' }, root .. '/nested/file.txt')
assert(vim.wait(5000, function() return contents():find('M nested/file.txt', 1, true) end, 20))
vim.fn.writefile({ 'new' }, root .. '/nested/empty/deep/new.txt')
assert(vim.wait(5000, function() return contents():find('nested/empty/', 1, true) end, 20), 'preexisting empty directories were not watched')
vim.fn.mkdir(root .. '/brand/new/deep', 'p')
vim.fn.writefile({ 'new tree' }, root .. '/brand/new/deep/a.txt')
assert(vim.wait(5000, function() return live_handles == 7 and contents():find('brand/', 1, true) end, 20))
vim.fn.writefile({ 'one', 'two', 'three' }, root .. '/nested/file.txt')
assert(vim.wait(5000, function()
  local renderer = require('features.status_renderer')
  for row = 1, vim.api.nvim_buf_line_count(b) do
    local entry = renderer.entry_at(b, row)
    if entry and entry.path == 'nested/file.txt' and entry.additions == 2 then return true end
  end
end, 20))
vim.fn.rename(root .. '/nested/file.txt', root .. '/nested/renamed.txt')
assert(vim.wait(5000, function() return contents():find('nested/renamed.txt', 1, true) end, 20))
vim.fn.delete(root .. '/brand', 'rf')
assert(vim.wait(5000, function() return live_handles == 4 and not contents():find('brand/', 1, true) end, 20))
assert(vim.api.nvim_get_current_win() == current, 'refresh moved window focus')
vim.wait(1500, function() return false end)
local system, calls = vim.system, 0
vim.system = function(...) calls = calls + 1; return system(...) end
vim.fn.writefile({ 'ignored edit' }, root .. '/ignored/deep/output.txt')
vim.wait(1200, function() return false end)
assert(calls == 0, 'ignored subtree triggered Git work')
vim.system = system
-- Ignore-rule changes add/remove directory coverage without restarting status.
vim.fn.writefile({}, root .. '/.gitignore')
assert(vim.wait(5000, function() return live_handles == 6 end, 20))
vim.fn.writefile({ 'ignored/' }, root .. '/.gitignore')
assert(vim.wait(5000, function() return live_handles == 4 end, 20))
-- Duplicate subscriptions share directory handles.
local cancel = require('features.worktree_watch').subscribe(root, function() end)
assert(live_handles == 4)
cancel(); cancel()
assert(live_handles == 4)
vim.api.nvim_buf_delete(b, { force = true })
assert(live_handles == 0, 'status teardown leaked directory watches')
for _ = 1, 20 do
  cancel = require('features.worktree_watch').subscribe(root, function() error('late callback') end)
  cancel(); cancel()
end
vim.wait(300, function() return false end)
assert(live_handles == 0)
vim.uv.new_fs_event = factory
vim.fn.executable = executable
vim.fn.delete(root, 'rf')
print('PASS: live external edits/new paths/empty directories/rename/delete, ignored subtree idle, shared watches and teardown')
