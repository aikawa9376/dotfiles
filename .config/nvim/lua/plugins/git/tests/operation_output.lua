-- Run from the plugin root: nvim --headless --clean -u NONE -l tests/operation_output.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
vim.opt.rtp:prepend(plugin)
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local function git(args)
  local cmd = { 'git', '-C', root }
  vim.list_extend(cmd, args)
  local result = vim.system(cmd, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout or '')
end
git({ 'init', '-q', '-b', 'main' })
git({ 'config', 'user.name', 'Test' })
git({ 'config', 'user.email', 'test@example.invalid' })
git({ 'config', 'commit.gpgsign', 'false' })
vim.fn.writefile({ 'one' }, root .. '/file.txt')
git({ 'add', '.' })
git({ 'commit', '-qm', 'first' })
require('git').setup()
vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/file.txt'))
local original = vim.api.nvim_get_current_win()
vim.fn.writefile({ 'two' }, root .. '/file.txt')
vim.cmd('Git add file.txt')
assert(#vim.api.nvim_list_wins() == 1, 'Git add opened an output window')
vim.cmd('Git commit -m second')
assert(#vim.api.nvim_list_wins() == 1, 'Git commit opened an output window')
assert(git({ 'log', '-1', '--format=%s' }) == 'second')
vim.fn.writefile({ 'three' }, root .. '/file.txt')
vim.cmd('Git stash push')
assert(#vim.api.nvim_list_wins() == 1, 'Git stash push opened an output window')
vim.cmd('Git stash pop')
assert(#vim.api.nvim_list_wins() == 1, 'Git stash pop opened an output window')
vim.cmd('Git branch -v')
assert(#vim.api.nvim_list_wins() == 2, 'read-only Git output should remain inspectable')
vim.cmd('close')
git({ 'remote', 'add', 'origin', root })
vim.cmd('Git fetch origin')
assert(vim.wait(10000, function() return #vim.api.nvim_list_wins() == 1 end, 20),
  'successful Git terminal did not close')
assert(vim.api.nvim_get_current_win() == original, 'Git terminal did not restore source focus')
vim.cmd('Git! fetch origin')
assert(vim.wait(10000, function()
  local b = vim.api.nvim_get_current_buf()
  local job = vim.b[b].terminal_job_id
  return job and vim.fn.jobwait({ job }, 0)[1] ~= -1
end, 20), 'diagnostic fetch did not finish')
assert(#vim.api.nvim_list_wins() == 2, 'Git! should retain successful terminal output')
vim.cmd('close')
local notifications = {}
local original_notify = vim.notify
vim.notify = function(message, level)
  notifications[#notifications + 1] = { message = tostring(message), level = level }
end
vim.cmd('Git fetch missing-remote')
assert(vim.wait(10000, function()
  return #vim.api.nvim_list_wins() == 1 and #notifications > 0
end, 20), 'failed Git terminal was left open')
assert(notifications[#notifications].level == vim.log.levels.ERROR
  and notifications[#notifications].message:find('missing-remote', 1, true),
  'Git failure details were not notified')

local panel = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(panel)
require('git.utils').set_buf_work_tree(panel, root)
vim.bo[panel].filetype = 'fugitivebranch'
local changed = 0
vim.api.nvim_create_autocmd('User', { pattern = 'FugitiveChanged', callback = function() changed = changed + 1 end })
local panel_job = require('git.commands').git({ args = 'fetch origin', bang = false })
assert(#vim.api.nvim_list_wins() == 1, 'panel Git operation opened a result window')
assert(vim.wait(10000, function()
  return vim.fn.jobwait({ panel_job }, 0)[1] ~= -1 and changed > 0
end, 20), 'panel Git operation did not finish')
panel_job = require('git.commands').git({ args = 'fetch missing-remote', bang = false })
assert(#vim.api.nvim_list_wins() == 1, 'failed panel Git operation opened a result window')
assert(vim.wait(10000, function()
  return vim.fn.jobwait({ panel_job }, 0)[1] ~= -1 and #notifications >= 2
end, 20), 'panel Git failure was not notified')
assert(notifications[#notifications].message:find('missing-remote', 1, true), 'panel failure lost Git stderr')
vim.fn.writefile({ 'four' }, root .. '/file.txt')
git({ 'add', 'file.txt' })
panel_job = require('git.commands').git({ args = 'commit', bang = false })
assert(#vim.api.nvim_list_wins() == 1, 'panel commit opened a terminal preview')
assert(vim.wait(10000, function() return vim.bo.filetype == 'gitcommit' end, 20),
  'panel commit did not open the message editor')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'panel commit' })
vim.cmd('write')
vim.cmd('close')
assert(vim.wait(10000, function() return git({ 'log', '-1', '--format=%s' }) == 'panel commit' end, 20),
  'panel commit did not resume after editing')
assert(vim.wait(10000, function() return vim.fn.jobwait({ panel_job }, 0)[1] ~= -1 end, 20),
  'panel commit job did not finish')
assert(#vim.api.nvim_list_wins() == 1, 'panel commit left a preview window')
vim.notify = original_notify
for _, b in ipairs(vim.api.nvim_list_bufs()) do pcall(vim.api.nvim_buf_delete, b, { force = true }) end
vim.fn.delete(root, 'rf')
print('PASS: panel operations avoid previews, failures notify, and Git! retains output')
