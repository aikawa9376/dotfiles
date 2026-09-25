-- Run from the plugin root: nvim --headless --clean -u NONE -l tests/status_discard_visual.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
package.loaded['git.features.status_watch'] = { subscribe = function() return function() end end }
package.loaded['git.features.worktree_watch'] = { subscribe = function() return function() end end }

local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return result.stdout or ''
end
git({ 'init', '-q' })
local path = root .. '/sample.txt'
local base = { 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'eleven', 'twelve' }
vim.fn.writefile(base, path)
vim.fn.writefile({ 'before', 'after' }, root .. '/conflict.txt')
git({ 'add', 'sample.txt', 'conflict.txt' })
git({ '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'base' })
local renderer = require('git.features.status_renderer')
local b = vim.api.nvim_create_buf(false, true)
local function snapshot()
  vim.api.nvim_buf_set_lines(b, 0, -1, false, assert(renderer.snapshot(b, root)))
end
local function find_row(text, start)
  for row = start or 1, vim.api.nvim_buf_line_count(b) do
    if (vim.api.nvim_buf_get_lines(b, row - 1, row, false)[1] or ''):find(text, 1, true) then return row end
  end
end
local function expand(section)
  snapshot()
  local heading = assert(find_row(section))
  local file = assert(find_row('sample.txt', heading + 1))
  assert(renderer.update_diff(b, file, 'show'))
  return file
end
local function lines() return vim.fn.readfile(path) end
local function discard(first, last)
  local ok, err = renderer.discard_range(b, first, last)
  assert(ok, err)
end

local changed = vim.deepcopy(base)
changed[2], changed[12] = 'TWO', 'TWELVE'
vim.fn.writefile(changed, path)
local file = expand('Unstaged changes')
discard(assert(find_row('-two', file)), assert(find_row('+TWO', file)))
assert(lines()[2] == 'two' and lines()[12] == 'TWELVE',
  'unstaged selected-line discard changed other lines')
assert(git({ 'diff', '--cached', '--', 'sample.txt' }) == '', 'unstaged discard changed the index')

changed = lines()
changed[2] = 'TWO'
vim.fn.writefile(changed, path)
file = expand('Unstaged changes')
local first, last = assert(find_row('+TWO', file)), assert(find_row('+TWELVE', file))
local ok = renderer.discard_range(b, first, last)
assert(not ok and lines()[2] == 'TWO' and lines()[12] == 'TWELVE',
  'cross-hunk Visual discard changed the file')

git({ 'add', 'sample.txt' })
changed = lines()
changed[10] = 'TEN'
vim.fn.writefile(changed, path)
file = expand('Staged changes')
discard(assert(find_row('-two', file)), assert(find_row('+TWO', file)))
assert(lines()[2] == 'two' and lines()[10] == 'TEN' and lines()[12] == 'TWELVE',
  'staged discard did not preserve unrelated worktree changes')
local staged = git({ 'show', ':sample.txt' })
assert(staged:find('two\n', 1, true) and staged:find('TWELVE', 1, true) and not staged:find('TEN', 1, true),
  'staged discard changed unrelated index content')

file = expand('Unstaged changes')
local stale = assert(find_row('+TEN', file))
changed = lines()
changed[10] = 'TEN_NEW'
vim.fn.writefile(changed, path)
ok = renderer.discard_range(b, stale, stale)
assert(not ok and lines()[10] == 'TEN_NEW',
  'stale displayed hunk was discarded')
changed[10] = 'TEN'
vim.fn.writefile(changed, path)

vim.fn.writefile({ 'alpha' }, root .. '/a.txt')
vim.fn.writefile({ 'beta' }, root .. '/b.txt')
snapshot()
local a, other = assert(find_row('a.txt')), assert(find_row('b.txt'))
assert(other == a + 1, 'untracked file rows are not adjacent')
discard(a, other)
assert(vim.fn.filereadable(root .. '/a.txt') == 0 and vim.fn.filereadable(root .. '/b.txt') == 0,
  'Visual file-row discard did not remove only selected files')

vim.fn.writefile({ 'keep' }, root .. '/untracked.txt')
snapshot()
local untracked = assert(find_row('untracked.txt'))
assert(renderer.update_diff(b, untracked, 'show'))
local pseudo_diff = assert(find_row('+keep', untracked))
ok = renderer.discard_range(b, pseudo_diff, pseudo_diff)
assert(not ok and vim.fn.filereadable(root .. '/untracked.txt') == 1,
  'Visual selection inside an untracked preview deleted the whole file')

vim.fn.writefile({ 'alpha', 'beta' }, root .. '/new.txt')
git({ 'add', 'new.txt' })
snapshot()
local new_file = assert(find_row('new.txt', find_row('Staged changes') + 1))
assert(renderer.update_diff(b, new_file, 'show'))
local alpha = assert(find_row('+alpha', new_file))
discard(alpha, alpha)
assert(vim.deep_equal(vim.fn.readfile(root .. '/new.txt'), { 'beta' })
  and git({ 'show', ':new.txt' }) == 'beta\n',
  'partial discard of a staged new file did not keep the other lines')

vim.fn.writefile({ 'STAGED', 'after' }, root .. '/conflict.txt')
git({ 'add', 'conflict.txt' })
vim.fn.writefile({ 'WORKTREE', 'after' }, root .. '/conflict.txt')
snapshot()
local conflict = assert(find_row('conflict.txt', find_row('Staged changes') + 1))
assert(renderer.update_diff(b, conflict, 'show'))
ok = renderer.discard_range(b, assert(find_row('-before', conflict)), assert(find_row('+STAGED', conflict)))
assert(not ok and git({ 'show', ':conflict.txt' }) == 'STAGED\nafter\n'
  and vim.fn.readfile(root .. '/conflict.txt')[1] == 'WORKTREE',
  'overlapping unstaged edits were changed by staged discard')

renderer.cleanup(b)
vim.api.nvim_buf_delete(b, { force = true })
local executable = vim.fn.executable
vim.fn.executable = function(name) return name == 'gh' and 0 or executable(name) end
local status = require('git.features.status')
status.setup(vim.api.nvim_create_augroup('StatusDiscardVisualTest', { clear = true }))
b = assert(status.open({ work_tree = root, split = true, focus = false }))
assert(vim.wait(5000, function() return find_row('Unstaged changes') end, 20))
file = assert(find_row('sample.txt', find_row('Unstaged changes') + 1))
assert(renderer.update_diff(b, file, 'show'))
local target = assert(find_row('-ten', file))
vim.api.nvim_win_set_cursor(0, { target, 0 })
vim.cmd('normal! Vj')
local mapping = vim.fn.maparg('X', 'x', false, true)
assert(type(mapping.callback) == 'function', 'status Visual X mapping is missing')
mapping.callback()
assert(vim.fn.mode() == 'n' and vim.wait(5000, function() return lines()[10] == 'ten' end, 20),
  'Visual X did not discard the selected status diff line')
assert(lines()[12] == 'TWELVE' and vim.fn.filereadable(root .. '/untracked.txt') == 1,
  'Visual X discarded an unselected change')

vim.fn.executable = executable
vim.api.nvim_buf_delete(b, { force = true })
vim.fn.delete(root, 'rf')
print('PASS: Visual X discards selected unstaged/staged lines and file rows; stale/cross-hunk previews stay safe')
