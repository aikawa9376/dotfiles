-- Cursor capture must not rescan the entire expanded status on each move.
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
package.loaded['git.features.status_watch'] = { subscribe = function() return function() end end }
package.loaded['git.features.worktree_watch'] = { subscribe = function() return function() end end }
local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false' }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait(); assert(result.code == 0, result.stderr)
end
git({ 'init', '-qb', 'main' })
vim.fn.writefile({ 'before' }, root .. '/tracked.txt')
git({ 'add', '.' }); git({ 'commit', '-qm', 'base' })
for i = 1, 120 do vim.fn.writefile({ 'one' }, root .. ('/new-%03d.txt'):format(i)) end
local executable = vim.fn.executable
vim.fn.executable = function(name) return name == 'gh' and 0 or executable(name) end
local status, renderer = require('git.features.status'), require('git.features.status_renderer')
status.setup(vim.api.nvim_create_augroup('StatusCursorPerf', { clear = true }))
local buf = assert(status.open({ work_tree = root, split = true, auto_fetch = false }))
local function file_row(path)
  for row = 1, vim.api.nvim_buf_line_count(buf) do
    local entry = renderer.entry_at(buf, row)
    if entry and not entry.header and entry.path == path then return row end
  end
end
assert(vim.wait(5000, function() return file_row('new-120.txt') end, 5))
local row = assert(file_row('new-100.txt'))
local get_lines, entry_at = vim.api.nvim_buf_get_lines, renderer.entry_at
local reads, lookups = 0, 0
vim.api.nvim_buf_get_lines = function(b, first, last, ...)
  if b == buf and first == 0 and last == -1 then reads = reads + 1 end
  return get_lines(b, first, last, ...)
end
renderer.entry_at = function(...) lookups = lookups + 1; return entry_at(...) end
for i = 1, 20 do
  vim.api.nvim_win_set_cursor(0, { row + i - 1, 0 })
  vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
end
vim.api.nvim_buf_get_lines, renderer.entry_at = get_lines, entry_at
print(('Status 20 moves: full-buffer reads=%d, entry lookups=%d'):format(reads, lookups))
assert(reads <= 1, 'Cursor movement repeatedly copied the whole status buffer')
assert(lookups <= 80, 'Cursor movement rescanned preceding file/diff rows')
-- Fresh rendering, expansion and provider projection must invalidate row indices.
local selected = assert(file_row('new-100.txt'))
if renderer.entry_position then
  local entry, direct, ordinal = renderer.entry_position(buf, selected)
  assert(entry.path == 'new-100.txt' and direct == selected and ordinal == 100)
  assert(renderer.update_diff(buf, selected, 'show'))
  local expanded = assert(file_row('new-101.txt'))
  entry, direct, ordinal = renderer.entry_position(buf, expanded)
  assert(entry.path == 'new-101.txt' and direct == expanded and ordinal == 101)
  local _, header, position = renderer.entry_position(buf, selected + 1)
  assert(header == selected and position == 100, 'Diff rows lost their file identity')
end
for _, b in ipairs(vim.api.nvim_list_bufs()) do pcall(vim.api.nvim_buf_delete, b, { force = true }) end
vim.fn.delete(root, 'rf')
print('PASS: bounded status cursor capture and expanded-row index lifetime')
