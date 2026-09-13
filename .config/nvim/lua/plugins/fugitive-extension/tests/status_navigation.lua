-- Run from the plugin root: nvim --headless --clean -u NONE -l tests/status_navigation.lua
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
end
git({ 'init', '-q' })
vim.fn.writefile({ 'one' }, root .. '/sample.txt')
git({ 'add', 'sample.txt' })
git({ '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'initial' })
vim.fn.writefile({ 'one', 'two' }, root .. '/sample.txt')
vim.fn.writefile({ 'new' }, root .. '/new.txt')
vim.fn.writefile({ 'staged' }, root .. '/staged.txt')
git({ 'add', 'staged.txt' })
-- Do not query GitHub from a navigation test.
local executable = vim.fn.executable
vim.fn.executable = function(name) return name == 'gh' and 0 or executable(name) end
local status = require('features.status')
status.setup(vim.api.nvim_create_augroup('StatusNavigationTest', { clear = true }))
local b = assert(status.open({ work_tree = root, split = true }))
assert(vim.api.nvim_get_current_line():find('Loading'), 'initial status should be asynchronous')
assert(vim.wait(5000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), '\n')
  return text:find('Unpushed %[only%]') and not text:find('Loading')
end, 20))
assert(vim.api.nvim_get_current_line():match('sample%.txt$'), 'cold open did not focus unstaged entry')
local function press(key) vim.fn.maparg(key, 'n', false, true).callback() end
press('gU')
assert(vim.api.nvim_get_current_line():match('new%.txt$'), 'gU did not focus untracked entry')
press('gu')
assert(vim.api.nvim_get_current_line():match('sample%.txt$'), 'gu did not focus unstaged entry')
local syncs = 0
require('features.worktree').sync_current_worktree_to_primary = function() syncs = syncs + 1 end
press('gs')
assert(vim.api.nvim_get_current_line():match('staged%.txt$') and syncs == 0, 'gs should only navigate to staged')
press('gws')
assert(syncs == 1, 'gws did not invoke worktree sync')
assert(vim.fn.maparg('gw', 'n') == '', 'gw should not have a competing mapping')
press('gu')
local prompt
vim.ui.select = function(_, opts) prompt = opts.prompt end
press('gx')
assert(prompt == 'Index flag for sample.txt:', 'gx did not retain index flag management')
local groups
require('features.action_menu').show = function(_, value) groups = value end
press('g?')
local actions = {}
for _, group in ipairs(groups) do
  for _, action in ipairs(group.actions) do actions[action.key] = action.label end
end
assert(actions.gu == 'Go to unstaged changes')
assert(actions.gU == 'Go to untracked files')
assert(actions.gx == 'Manage update-index flags')
assert(actions.gs == 'Go to staged changes')
vim.bo[b].modifiable = true
vim.bo[b].readonly = false
vim.api.nvim_buf_set_lines(b, -1, -1, false, { '', 'Worktrees (1)' })
vim.bo[b].modifiable = false
vim.bo[b].readonly = true
vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(b), 0 })
press('g?')
local sync_key
for _, group in ipairs(groups) do
  for _, action in ipairs(group.actions) do
    if action.label == 'Sync current worktree to primary' then sync_key = action.key end
  end
end
assert(sync_key == 'gws', 'worktree help retained old sync key')
-- A queued WinEnter restore must not undo the new opening position.
press('gU')
press('q')
assert(status.open({ work_tree = root, split = true }) == b)
vim.wait(10, function() return false end)
assert(vim.api.nvim_get_current_line():match('sample%.txt$'), 'warm open restored an obsolete cursor anchor')
press('gU')
press('q')
vim.api.nvim_exec_autocmds('User', { pattern = 'FugitiveChanged', data = { work_tree = root } })
assert(status.open({ work_tree = root, split = true }) == b)
vim.wait(500, function() return false end)
assert(vim.api.nvim_get_current_line():match('sample%.txt$'), 'dirty reopen restored the pre-refresh anchor')
-- No unstaged section: do not keep a pending jump that could fire on a later edit.
git({ 'checkout', '--', 'sample.txt' })
vim.api.nvim_buf_delete(b, { force = true })
b = assert(status.open({ work_tree = root, split = true }))
assert(vim.wait(5000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), '\n')
  return text:find('Unpushed %[only%]') and not text:find('Loading')
end, 20))
press('gU')
status.refresh_buffer(b)
assert(vim.api.nvim_get_current_line():match('new%.txt$'), 'missing section left a delayed cursor jump')
vim.api.nvim_buf_delete(b, { force = true })
vim.fn.delete(root, 'rf')
print('PASS: cold/warm focus, gu/gU/gx, help labels, missing unstaged section')
