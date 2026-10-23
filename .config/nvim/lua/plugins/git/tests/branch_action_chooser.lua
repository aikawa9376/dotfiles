-- Run: python3 tests/run.py branch_action_chooser
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
vim.opt.rtp:prepend(plugin)
local root = vim.fn.tempname() .. ' branch chooser'
vim.fn.mkdir(root, 'p')
local function git(args, opts)
  local argv = { 'git', '-C', root }; vim.list_extend(argv, args)
  local result = vim.system(argv, vim.tbl_extend('force', { text = true }, opts or {})):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout or '')
end
git({ 'init', '-qb', 'main' })
git({ 'config', 'user.name', 'Test' }); git({ 'config', 'user.email', 'test@example.invalid' })
git({ 'config', 'commit.gpgsign', 'false' })
vim.fn.writefile({ 'base' }, root .. '/file.txt')
git({ 'add', '.' })
git({ 'commit', '-qm', 'base' }, { env = { GIT_COMMITTER_DATE = '@' .. (os.time() - 5) .. ' +0000' } })
git({ 'branch', 'topic' })
local head = git({ 'rev-parse', 'HEAD' })
require('git.features.branch').setup(vim.api.nvim_create_augroup('BranchChooserTest', { clear = true }))
vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/file.txt'))
vim.cmd('Gbranch')
local buf = vim.api.nvim_get_current_buf()
local function select_topic()
  for row, name in ipairs(vim.b[buf].branch_map) do
    if name == 'topic' then vim.api.nvim_win_set_cursor(0, { row, 0 }); return row end
  end
  error('topic row missing')
end
local function press(key)
  local map = vim.fn.maparg(key, 'n', false, true)
  assert(type(map.callback) == 'function', 'missing mapping ' .. key)
  map.callback()
end
local input, notify = vim.fn.input, vim.notify
local calls, warnings = {}, {}
vim.fn.input = function(prompt, default)
  calls[#calls + 1] = { prompt = prompt, default = default }
  return '' -- Cancel before stash/fetch/rebase.
end
vim.notify = function(message) warnings[#warnings + 1] = message end
local function open_chooser()
  press('R')
  local row = select_topic()
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  calls, warnings = {}, {}
  press('gO')
  return row, line
end
open_chooser(); press('R')
assert(#calls == 1 and calls[1].prompt == 'Rebase on: ' and calls[1].default == 'topic')
local row, before = open_chooser()
-- A notified update can still change the relative date while the menu is open.
vim.wait(1100, function() return false end, 10)
vim.api.nvim_exec_autocmds('User', { pattern = 'GitChanged', data = { work_tree = root } })
assert(vim.wait(5000, function()
  return vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] ~= before
end, 10), 'notified refresh did not finish')
press('R')
local after = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
assert(before ~= after, 'fixture did not cross a relative-date boundary')
assert(#calls == 1 and calls[1].default == 'topic' and #warnings == 0,
  'relative-date refresh suppressed the rebase prompt: ' .. vim.inspect(warnings))

-- A different branch taking the captured row must still be rejected.
open_chooser()
git({ 'branch', '-D', 'topic' }); git({ 'branch', 'replacement' })
vim.api.nvim_exec_autocmds('User', { pattern = 'GitChanged', data = { work_tree = root } })
assert(vim.wait(5000, function() return vim.tbl_contains(vim.b[buf].branch_map, 'replacement') end, 10))
press('R')
assert(#calls == 0 and vim.tbl_contains(warnings, 'Selected item changed; reopen the action chooser'),
  'chooser acted on a replacement branch')

-- Identical displayed names must not make a tag interchangeable with a branch.
git({ 'branch', '-D', 'replacement' }); git({ 'branch', 'topic' })
open_chooser()
git({ 'branch', '-D', 'topic' }); git({ 'tag', 'topic' })
vim.api.nvim_exec_autocmds('User', { pattern = 'GitChanged', data = { work_tree = root } })
assert(vim.wait(5000, function()
  for r, name in ipairs(vim.b[buf].branch_map) do
    if name == 'topic' and vim.b[buf].branch_kinds[r] == 'tags' then return true end
  end
end, 10))
press('R')
assert(#calls == 0 and vim.tbl_contains(warnings, 'Selected item changed; reopen the action chooser'),
  'chooser treated a same-name tag as the selected branch')
assert(git({ 'rev-parse', 'HEAD' }) == head and git({ 'status', '--porcelain' }) == '')
vim.fn.input, vim.notify = input, notify
vim.api.nvim_buf_delete(buf, { force = true }); vim.fn.delete(root, 'rf')
print('PASS: Branch chooser tolerates date refresh and rejects replacement branches/tags before rebase input')
