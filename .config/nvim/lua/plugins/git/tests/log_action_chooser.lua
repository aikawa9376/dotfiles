-- Run: python3 tests/run.py log_action_chooser
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
vim.opt.rtp:prepend(plugin)
local root = vim.fn.tempname() .. ' log chooser'; vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
    '-c', 'commit.gpgsign=false' }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr); return vim.trim(result.stdout or '')
end
git({ 'init', '-qb', 'main' })
vim.fn.writefile({ 'base' }, root .. '/file.txt'); git({ 'add', '.' }); git({ 'commit', '-qm', 'base' })
local head = git({ 'rev-parse', 'HEAD' })
local jobstart, confirm, notify = vim.fn.jobstart, vim.fn.confirm, vim.notify
local deliver
vim.fn.jobstart = function(argv, opts)
  if type(argv) == 'table' and vim.tbl_contains(argv, '--shortstat') then
    local on_exit = opts.on_exit
    opts.on_exit = function(...)
      local args = { ... }
      deliver = function() on_exit(unpack(args)) end
    end
  end
  return jobstart(argv, opts)
end
require('git.features.log').setup(vim.api.nvim_create_augroup('LogChooserTest', { clear = true }))
vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/file.txt')); vim.cmd('GitLog')
local buf = vim.api.nvim_get_current_buf()
local function press(key)
  local map = vim.fn.maparg(key, 'n', false, true)
  assert(type(map.callback) == 'function', 'missing mapping ' .. key); map.callback()
end
local calls, warnings = 0, {}
vim.fn.confirm = function() calls = calls + 1; return 2 end
vim.notify = function(message) warnings[#warnings + 1] = message end
assert(vim.wait(5000, function() return deliver ~= nil end, 10), 'shortstat job did not finish')
local before = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
press('gH')
deliver()
assert(vim.wait(5000, function()
  return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] ~= before
end, 10), 'shortstat did not update the selected commit display')
press('R')
assert(calls == 1, 'shortstat refresh suppressed reset confirmation: ' .. vim.inspect(warnings))

-- A new commit replacing the captured row must not receive the old action.
press('gH')
vim.fn.writefile({ 'changed' }, root .. '/file.txt'); git({ 'add', '.' }); git({ 'commit', '-qm', 'new tip' })
local new_head = git({ 'rev-parse', 'HEAD' })
press('R')
assert(calls == 1 and vim.tbl_contains(warnings, 'Selected item changed; reopen the action chooser'),
  'log chooser confirmed a different commit')
assert(new_head ~= head and git({ 'rev-parse', 'HEAD' }) == new_head)
vim.fn.jobstart, vim.fn.confirm, vim.notify = jobstart, confirm, notify
vim.api.nvim_buf_delete(buf, { force = true }); vim.fn.delete(root, 'rf')
print('PASS: Log chooser tolerates async shortstat enrichment and rejects a replacement commit')
