-- Run from plugin root: nvim --headless --clean -u NONE -l tests/action_apply_commands.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path

local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
local function write(lines) vim.fn.writefile(lines, root .. '/multi.txt') end
local function read() return vim.fn.readfile(root .. '/multi.txt') end
local original = {}
for i = 1, 26 do original[i] = 'line ' .. i end
git({ 'init', '-qb', 'main' })
git({ 'config', 'user.name', 'Test' })
git({ 'config', 'user.email', 'test@example.invalid' })
write(original)
git({ 'add', '.' })
git({ 'commit', '-qm', 'base' })
local base = git({ 'rev-parse', 'HEAD' })
git({ 'switch', '-qc', 'feature' })
local changed = vim.deepcopy(original)
changed[2], changed[24] = 'first change', 'second change'
write(changed)
git({ 'commit', '-qam', 'two hunks' })
local selected = git({ 'rev-parse', 'HEAD' })
git({ 'switch', '-q', 'main' })

local view = require('git.features.commit')
view.setup(vim.api.nvim_create_augroup('ApplyCommandsTest', { clear = true }))
require('git.features.magit_apply').setup()
local buf = assert(view.open({ work_tree = root, revision = selected }))
local function row_for(pattern)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:find(pattern, 1, true) then return row end
  end
  error('missing ' .. pattern)
end
local function focus(pattern) vim.api.nvim_win_set_cursor(0, { row_for(pattern), 0 }) end
local function press(key)
  local mapping = vim.fn.maparg(key, 'n', false, true)
  assert(type(mapping.callback) == 'function', 'missing ' .. key)
  mapping.callback()
end
focus('M multi.txt')
vim.cmd('GitApply')
assert(vim.deep_equal(read(), changed), 'GitApply did not apply commit-panel file')
vim.cmd('GitReverse')
assert(vim.deep_equal(read(), original), 'GitReverse did not reverse commit-panel file')
press('o')
focus('@@')
press('a')
assert(read()[2] == changed[2] and read()[24] == original[24],
  'commit-panel a applied more than the selected hunk')
press('v')
assert(vim.deep_equal(read(), original), 'commit-panel v did not reverse the hunk')
assert(git({ 'rev-parse', 'HEAD' }) == base and git({ 'diff', '--cached', '--name-only' }) == '',
  'regular apply/reverse changed HEAD or index')

local ordinary = vim.api.nvim_create_buf(true, false)
require('git.utils').set_buf_work_tree(ordinary, root)
vim.api.nvim_set_current_buf(ordinary)
git({ 'config', 'color.ui', 'always' })
git({ 'config', 'diff.noprefix', 'true' })
vim.cmd('GitApply ' .. selected)
assert(vim.deep_equal(read(), changed), 'GitApply revision argument failed outside a panel')
vim.cmd('GitReverse ' .. selected)
assert(vim.deep_equal(read(), original), 'GitReverse revision argument failed outside a panel')
vim.cmd('GitApply! ' .. selected)
assert(vim.deep_equal(read(), changed) and git({ 'diff', '--cached', '--name-only' }) == 'multi.txt',
  'GitApply! did not apply a three-way patch to worktree and index')
git({ 'config', '--unset', 'color.ui' })
git({ 'config', '--unset', 'diff.noprefix' })
git({ 'reset', '-q', '--hard' })
write(changed)
git({ 'stash', 'push', '-qm', 'apply test' })
local stash_buf = assert(require('git.objects').open('stash@{0}', 'vsplit', root))
assert(vim.bo[stash_buf].filetype == 'fugitivecommit',
  'opening a stash object did not reach the commit panel')
local stash_file_row
for row, line in ipairs(vim.api.nvim_buf_get_lines(stash_buf, 0, -1, false)) do
  if line:find('M multi.txt', 1, true) then stash_file_row = row; break end
end
assert(stash_file_row, 'stash commit panel omitted the changed file')
vim.api.nvim_win_set_cursor(0, { stash_file_row, 0 })
press('a')
assert(vim.deep_equal(read(), changed), 'commit-panel a did not apply the stash file patch')
press('v')
assert(vim.deep_equal(read(), original), 'commit-panel v did not reverse the stash file patch')

local ours = vim.deepcopy(original)
ours[2] = 'conflicting local commit'
write(ours)
git({ 'commit', '-qam', 'conflicting local commit' })
local utils = require('git.utils')
local original_changed, refreshed = utils.fire_fugitive_changed, false
utils.fire_fugitive_changed = function(opts) refreshed = opts.work_tree == root end
local applied, apply_err = require('git.features.magit_apply').apply(
  { work_tree = root, commit = selected }, true, false)
utils.fire_fugitive_changed = original_changed
assert(not applied and apply_err ~= '' and git({ 'ls-files', '-u' }) ~= '',
  'fixture did not leave a three-way conflict')
assert(refreshed, 'three-way conflicts did not refresh repository panels')

vim.api.nvim_buf_delete(buf, { force = true })
vim.api.nvim_buf_delete(stash_buf, { force = true })
vim.api.nvim_buf_delete(ordinary, { force = true })
vim.fn.delete(root, 'rf')
print('PASS: GitApply/GitReverse commands and commit-panel file/hunk mappings')
