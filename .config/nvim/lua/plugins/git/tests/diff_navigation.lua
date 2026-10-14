-- Standalone/native hunks wrap without changing inline or ordinary keymaps.
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.rtp:prepend(plugin)
local api = vim.api
local navigation = require('git.features.diff_navigation')
navigation.setup()
require('git.output').setup(api.nvim_create_augroup('DiffNavigationTestOutput', { clear = true }))
local function key(key, count)
  vim.cmd('normal ' .. (count and tostring(count) or '') .. key)
end
local function row() return api.nvim_win_get_cursor(0)[1] end
local function at(line, col) api.nvim_win_set_cursor(0, { line, col or 0 }) end
local function mapped()
  assert(vim.wait(1000, function()
    return vim.fn.maparg(']]', 'n', false, true).desc == 'Next diff hunk (wrap)'
  end, 1), 'Diff mappings were not installed')
end
-- Unified headers, counts, file boundaries and folds, regardless of wrapscan.
vim.o.wrapscan = false
vim.cmd('enew')
api.nvim_buf_set_lines(0, 0, -1, false, {
  'diff --git a/a b/a', '--- a/a', '+++ b/a', '@@ -1 +1 @@', '-old', '+new',
  '@@ -20 +20 @@', '-old', '+new', 'diff --git a/b b/b', '@@@ -1 -1 +1 @@@', '-old', '+new',
})
vim.bo.filetype = 'git'
vim.wo.foldmethod = 'manual'
vim.cmd('4,6fold'); at(1)
key(']]'); assert(row() == 4 and vim.fn.foldclosed(row()) == -1)
key(']]'); assert(row() == 7)
key(']]'); assert(row() == 11)
key(']]'); assert(row() == 4)
key('[['); assert(row() == 11)
key(']]', 5); assert(row() == 7)
key('[[', 4); assert(row() == 4)
vim.cmd('enew!'); api.nvim_buf_set_lines(0, 0, -1, false, { 'preview', '@@ -1 +1 @@', '-a', '+b' })
vim.bo.filetype = 'diff'; at(4)
key(']]'); assert(row() == 2); key('[['); assert(row() == 2)
api.nvim_buf_set_lines(0, 0, -1, false, { 'No hunks', 'unchanged' }); at(2, 3)
local cursor = api.nvim_win_get_cursor(0)
key(']]'); key('[['); assert(vim.deep_equal(api.nvim_win_get_cursor(0), cursor))

local function pair(old, new)
  vim.cmd('tabnew')
  local left, left_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  api.nvim_buf_set_lines(left_buf, 0, -1, false, old)
  vim.cmd('vnew')
  local right, right_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  api.nvim_buf_set_lines(right_buf, 0, -1, false, new)
  vim.cmd('diffthis'); api.nvim_set_current_win(left); vim.cmd('diffthis'); vim.cmd('diffupdate')
  mapped()
  return left, right, left_buf, right_buf
end
-- First/last-line and multi-line changes; ignore settings and counts stay native.
vim.o.diffopt = 'internal,filler,context:0,algorithm:histogram'
local old = { 'old', 'same', 'old', 'old', 'same', 'old', 'old' }
local new = { 'new', 'same', 'new', 'new', 'same', 'new', 'new' }
local left, right, left_buf, right_buf = pair(old, new)
for _, win in ipairs({ left, right }) do
  api.nvim_set_current_win(win); mapped(); at(1)
  key(']]'); assert(row() == 3); key(']]'); assert(row() == 6)
  key(']]'); assert(row() == 1); key('[['); assert(row() == 6)
  key('[[', 4); assert(row() == 3); key(']]', 5); assert(row() == 1)
  at(7); key(']]'); assert(row() == 1)
end
-- Edits update native hunks rather than retaining an old comparison cache.
api.nvim_buf_set_lines(right_buf, 2, 4, false, { 'old', 'old' }); vim.cmd('diffupdate')
at(1); key(']]'); assert(row() == 6); key(']]'); assert(row() == 1)
vim.cmd('tabclose!')
-- Pure deletions and EOF filler are navigable from either side.
left, right = pair({ 'same', 'deleted', 'same', 'deleted' }, { 'same', 'same' })
api.nvim_set_current_win(left); mapped(); at(1)
key(']]'); assert(row() == 2); key(']]'); assert(row() == 4)
key(']]'); assert(row() == 2); key('[['); assert(row() == 4)
api.nvim_set_current_win(right); mapped(); at(1)
key(']]'); assert(row() == 2); key(']]'); assert(row() == 2); key('[['); assert(row() == 2)
vim.cmd('tabclose!')
-- Three-way conflict windows use the same native change set.
left, right = pair({ 'a', 'same', 'c' }, { 'b', 'same', 'c' })
vim.cmd('vnew'); api.nvim_buf_set_lines(0, 0, -1, false, { 'a', 'same', 'd' }); vim.cmd('diffthis'); vim.cmd('diffupdate')
api.nvim_set_current_win(left); mapped(); at(1)
key(']]'); assert(row() == 3); key(']]'); assert(row() == 1); key('[['); assert(row() == 3)
vim.cmd('tabclose!')
-- No visible changes, including differences suppressed by diffopt, are a no-op.
left, right = pair({ 'same', 'two' }, { 'same', 'two' })
at(2, 1); cursor = api.nvim_win_get_cursor(0); key(']]'); key('[[')
assert(vim.deep_equal(api.nvim_win_get_cursor(0), cursor))
api.nvim_buf_set_lines(0, 0, 1, false, { '   same' }); vim.o.diffopt = vim.o.diffopt .. ',iwhiteall'; vim.cmd('diffupdate')
key(']]'); key('[['); assert(vim.deep_equal(api.nvim_win_get_cursor(0), cursor))
vim.cmd('tabclose!')
-- A buffer shown in diff and ordinary windows preserves its original maps.
vim.cmd('tabnew')
local normal = api.nvim_get_current_win()
local work = api.nvim_get_current_buf()
api.nvim_buf_set_lines(work, 0, -1, false, { 'a', 'same', 'c' })
local called = 0
local original = function() called = called + 1 end
vim.keymap.set('n', ']]', original, { buffer = work, desc = 'Ordinary next', nowait = true })
vim.keymap.set('n', '[[', 'gg', { buffer = work, silent = true })
vim.cmd('vsplit'); local diff_win = api.nvim_get_current_win(); vim.cmd('diffthis')
vim.cmd('vnew'); api.nvim_buf_set_lines(0, 0, -1, false, { 'b', 'same', 'd' }); vim.cmd('diffthis'); vim.cmd('diffupdate')
api.nvim_set_current_win(diff_win); mapped(); at(1); key(']]'); assert(row() == 3 and called == 0)
api.nvim_set_current_win(normal)
assert(vim.wait(1000, function() return vim.fn.maparg(']]', 'n', false, true).callback == original end, 1))
key(']]'); assert(called == 1); key('[['); assert(row() == 1)
assert(vim.fn.maparg(']]', 'n', false, true).nowait == 1)
api.nvim_set_current_win(diff_win); mapped(); at(1); key('[['); assert(row() == 3)
vim.cmd('diffoff!')
assert(vim.wait(1000, function() return vim.fn.maparg(']]', 'n', false, true).callback == original end, 1))
key(']]'); assert(called == 2)
-- Later map changes are not overwritten by teardown.
vim.cmd('diffthis'); mapped()
vim.keymap.set('n', ']]', 'G', { buffer = work, desc = 'New ordinary next' })
vim.cmd('diffoff!')
vim.wait(20)
assert(vim.fn.maparg(']]', 'n', false, true).desc == 'New ordinary next')
vim.cmd('tabclose!')
-- Removing a temporary local map reveals the current global mapping.
local global_called = 0
vim.keymap.set('n', ']]', function() global_called = global_called + 1 end)
left, right = pair({ 'a', 'same', 'c' }, { 'b', 'same', 'd' })
at(1); key(']]'); assert(row() == 3 and global_called == 0)
vim.keymap.set('n', ']]', function() global_called = global_called + 10 end)
vim.cmd('diffoff!')
assert(vim.wait(1000, function() return vim.fn.maparg(']]', 'n', false, true).buffer == 0 end, 1))
key(']]'); assert(global_called == 10)
vim.cmd('tabclose!')
print('PASS: unified/native cyclic hunks, counts, folds, edits, EOF deletions, conflicts, diffopt, no-op and map restoration')
