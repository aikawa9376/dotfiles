-- Run from the plugin root: nvim --headless --clean -u NONE -l tests/status_partial.lua
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
  return result.stdout or ''
end
git({ 'init', '-q' })
local path = root .. '/sample.txt'
local base = { 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'eleven', 'twelve' }
vim.fn.writefile(base, path)
git({ 'add', 'sample.txt' })
git({ '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'base' })
local changed = vim.deepcopy(base)
changed[1], changed[12] = 'ONE', 'TWELVE'
vim.fn.writefile(changed, path)

local renderer = require('git.features.status_renderer')
local b = vim.api.nvim_create_buf(false, true)
local function snapshot()
  vim.api.nvim_buf_set_lines(b, 0, -1, false, assert(renderer.snapshot(b, root)))
end
local function row_containing(pattern)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
    if line:find(pattern, 1, true) then return row end
  end
end
snapshot()
local file_row = assert(row_containing('sample.txt'))
assert(renderer.update_diff(b, file_row, 'show'))
local first_hunk = assert(row_containing('@@'))
assert(renderer.change_index(b, first_hunk, 'toggle'))
assert(git({ 'diff', '--cached', '--', 'sample.txt' }):find('+ONE', 1, true))
assert(not git({ 'diff', '--cached', '--', 'sample.txt' }):find('+TWELVE', 1, true))
snapshot()
local staged_section = assert(row_containing('Staged changes'))
local staged_hunk
for row = staged_section + 1, vim.api.nvim_buf_line_count(b) do
  local line = vim.api.nvim_buf_get_lines(b, row - 1, row, false)[1]
  if line:find('sample.txt', 1, true) then renderer.update_diff(b, row, 'show') end
  if line:match('^@@') then staged_hunk = row; break end
end
if not staged_hunk then
  for row = staged_section + 1, vim.api.nvim_buf_line_count(b) do
    local line = vim.api.nvim_buf_get_lines(b, row - 1, row, false)[1]
    if line:match('^@@') then staged_hunk = row; break end
  end
end
assert(staged_hunk)
assert(renderer.change_index(b, staged_hunk, 'unstage'))
assert(git({ 'diff', '--cached', '--', 'sample.txt' }) == '')

changed[3] = 'THREE'
vim.fn.writefile(changed, path)
snapshot()
file_row = assert(row_containing('sample.txt'))
assert(renderer.update_diff(b, file_row, 'show'))
local selected = assert(row_containing('+THREE'))
local ok, err = renderer.change_index_range(b, selected, selected, 'toggle')
assert(ok, err)
local cached = git({ 'diff', '--cached', '--', 'sample.txt' })
assert(cached:find('+THREE', 1, true) and not cached:find('+ONE', 1, true))
snapshot()
file_row = assert(row_containing('sample.txt'))
assert(renderer.update_diff(b, file_row, 'show'))
local remaining = assert(row_containing('+ONE'))
assert(renderer.change_index(b, remaining, 'toggle'))
cached = git({ 'diff', '--cached', '--', 'sample.txt' })
assert(cached:find('+ONE', 1, true) and cached:find('+THREE', 1, true))
snapshot()
staged_section = assert(row_containing('Staged changes'))
renderer.update_diff(b, staged_section + 1, 'show')
local staged_line
for row = staged_section + 1, vim.api.nvim_buf_line_count(b) do
  local line = vim.api.nvim_buf_get_lines(b, row - 1, row, false)[1]
  if line == '+THREE' then staged_line = row; break end
end
assert(staged_line)
ok, err = renderer.change_index_range(b, staged_line, staged_line, 'unstage')
assert(ok, err)
cached = git({ 'diff', '--cached', '--', 'sample.txt' })
assert(cached:find('+ONE', 1, true) and not cached:find('+THREE', 1, true))

snapshot()
file_row = assert(row_containing('sample.txt'))
renderer.update_diff(b, file_row, 'show')
local stale_hunk = assert(row_containing('@@'))
changed[5] = 'FIVE'
vim.fn.writefile(changed, path)
assert(not renderer.change_index(b, stale_hunk, 'toggle'), 'stale displayed hunk was applied')

vim.fn.writefile({ 'alpha', 'beta', 'gamma' }, root .. '/new.txt')
git({ 'add', 'new.txt' })
snapshot()
local new_row = assert(row_containing('new.txt'))
renderer.update_diff(b, new_row, 'show')
local alpha = assert(row_containing('+alpha'))
ok, err = renderer.change_index_range(b, alpha, alpha, 'unstage')
assert(ok, err)
local staged_new = git({ 'show', ':new.txt' })
assert(not staged_new:find('alpha', 1, true) and staged_new:find('beta', 1, true),
  'partial unstage of a new file removed too much')

renderer.cleanup(b)
vim.fn.delete(root, 'rf')
print('PASS: status hunk and selected-line staging/unstaging')
