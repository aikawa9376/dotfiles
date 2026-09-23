-- Run: nvim --headless --clean -u NONE -l tests/status_statistics.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
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
git({ 'init', '-q' })
vim.fn.writefile({ 'one' }, root .. '/sample.txt')
git({ 'add', '.' })
git({ 'commit', '-qm', 'initial' })
vim.fn.writefile({ 'one', 'two' }, root .. '/sample.txt')
vim.fn.writefile({ 'staged' }, root .. '/staged.txt')
git({ 'add', 'staged.txt' })
vim.fn.writefile({ 'new', 'lines' }, root .. '/new file.txt')
vim.fn.writefile({ 'no', 'final newline' }, root .. '/no-eol.txt', 'b')
vim.fn.writefile({}, root .. '/empty.txt')
local function write_bytes(path, bytes)
  local file = assert(io.open(root .. '/' .. path, 'wb'))
  assert(file:write(bytes))
  file:close()
end
write_bytes('binary.dat', 'binary\0content')
write_bytes('large.txt', string.rep('x\n', 40000) .. 'last')
assert(vim.uv.fs_symlink('new file.txt', root .. '/link.txt'))
local executable = vim.fn.executable
vim.fn.executable = function(name) return name == 'gh' and 0 or executable(name) end
local status = require('git.features.status')
local renderer = require('git.features.status_renderer')
status.setup(vim.api.nvim_create_augroup('StatusStatisticsTest', { clear = true }))
local b = assert(status.open({ work_tree = root, split = true }))
local function entry(section, path)
  for row = 1, vim.api.nvim_buf_line_count(b) do
    local value = renderer.entry_at(b, row)
    if value and value.section == section and value.path == path then return value end
  end
end
assert(vim.wait(5000, function()
  local value = entry('unstaged', 'sample.txt')
  return value and value.additions == 1
end, 10))
local function displayed_counts()
  local values = {}
  local ns = vim.api.nvim_create_namespace('fugitive_status_icons')
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(b, ns, 0, -1, { details = true })) do
    local value = renderer.entry_at(b, mark[2] + 1)
    for _, chunk in ipairs(mark[4].virt_text or {}) do
      if chunk[2] == 'FugitiveStatAdd' and value then
        values[value.section .. ':' .. value.path] = chunk[1]
      end
    end
  end
  return values
end
assert(displayed_counts()['untracked:new file.txt'] == ' +2', 'untracked count missing')
assert(displayed_counts()['untracked:no-eol.txt'] == ' +2', 'unterminated last line not counted')
assert(displayed_counts()['untracked:empty.txt'] == ' +0', 'empty file count missing')
assert(displayed_counts()['untracked:link.txt'] == ' +1', 'symlink target content was counted')
assert(entry('untracked', 'binary.dat').binary, 'binary file treated as text')
assert(entry('untracked', 'large.txt').additions == 40001, 'chunked line count is incorrect')
-- Observe the actual preliminary paint, before delayed enrichment can hide a gap.
local snapshot_async = renderer.snapshot_async
local paints, observed = 0, nil
renderer.snapshot_async = function(bufnr, work_tree, opts, callback)
  return snapshot_async(bufnr, work_tree, opts, function(...)
    callback(...)
    paints = paints + 1
    observed = displayed_counts()
  end)
end
vim.fn.writefile({ 'one', 'two', 'three' }, root .. '/sample.txt')
vim.fn.writefile({ 'new', 'lines', 'more' }, root .. '/new file.txt')
vim.fn.maparg('R', 'n', false, true).callback()
assert(vim.wait(5000, function() return paints > 0 end, 10))
assert(observed['unstaged:sample.txt'] == ' +1', 'preliminary paint erased unstaged statistics')
assert(observed['staged:staged.txt'] == ' +1', 'preliminary paint erased staged statistics')
assert(observed['untracked:new file.txt'] == ' +2', 'preliminary paint erased untracked statistics')
assert(vim.wait(5000, function()
  return displayed_counts()['unstaged:sample.txt'] == ' +2'
end, 10), 'enrichment did not replace cached counts')
assert(displayed_counts()['untracked:new file.txt'] == ' +3', 'untracked edit did not update count')
-- Section changes must not reuse the old unstaged counts for a staged entry.
git({ 'add', 'sample.txt' })
git({ 'add', 'new file.txt', 'no-eol.txt', 'link.txt', 'binary.dat', 'large.txt' })
local before = paints
vim.fn.maparg('R', 'n', false, true).callback()
assert(vim.wait(5000, function() return paints > before end, 10))
assert(observed['staged:sample.txt'] == nil, 'counts leaked across sections')
assert(vim.wait(5000, function()
  return displayed_counts()['staged:sample.txt'] == ' +2'
end, 10))
assert(displayed_counts()['staged:new file.txt'] == ' +3', 'staging changed line count')
assert(displayed_counts()['staged:no-eol.txt'] == ' +2', 'staging changed unterminated line count')
assert(displayed_counts()['staged:link.txt'] == ' +1', 'staging changed symlink count')
assert(entry('staged', 'binary.dat').binary, 'staging changed binary classification')
assert(entry('staged', 'large.txt').additions == 40001, 'staging changed chunked count')
-- Read-only snapshots must not refresh the index stat cache after a touch.
git({ 'reset', '--hard', '-q', 'HEAD' })
local index = root .. '/.git/index'
local before_index = vim.fn.readfile(index, 'b')
vim.fn.writefile({ 'one' }, root .. '/sample.txt')
assert(renderer.snapshot(b, root))
assert(vim.deep_equal(before_index, vim.fn.readfile(index, 'b')), 'sync snapshot wrote the index')
local done = false
snapshot_async(b, root, {}, function(lines)
  assert(lines)
  done = true
end)
assert(vim.wait(5000, function() return done end, 10))
assert(vim.deep_equal(before_index, vim.fn.readfile(index, 'b')), 'async snapshot wrote the index')
vim.api.nvim_buf_delete(b, { force = true })
vim.fn.delete(root, 'rf')
print('PASS: statistics survive preliminary paint, update after enrichment, and stay section-local; snapshots do not write index')
