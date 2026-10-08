local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
local function git(args) return vim.trim(require('git.objects').run(root, args)) end
git({ 'init', '-q' }); git({ 'config', 'user.name', 'Test' }); git({ 'config', 'user.email', 'test@example.invalid' }); git({ 'config', 'commit.gpgsign', 'false' })
vim.fn.writefile({ 'first' }, root .. '/file.txt'); git({ 'add', '.' }); git({ 'commit', '-qm', 'first' })
local first = git({ 'rev-parse', 'HEAD' })
vim.fn.writefile({ 'second' }, root .. '/file.txt'); git({ 'add', '.' }); git({ 'commit', '-qm', 'second' })
vim.cmd('edit ' .. root .. '/file.txt')
local origin = vim.api.nvim_get_current_buf()
require('git.utils').set_buf_work_tree(origin, root)
vim.fn.writefile({ 'staged' }, root .. '/file.txt'); git({ 'add', '.' })
vim.fn.writefile({ 'unstaged' }, root .. '/file.txt')
local actions = require('git.features.commit_actions')
local result
actions.open_edit_commit(first, origin, { reopen = false, on_complete = function(hash) result = hash end })
local draft = vim.api.nvim_get_current_buf()
assert(draft ~= origin and vim.fn.maparg('<C-s>', 'n', false, true).callback)
assert(vim.fn.maparg('<Leader>a', 'n') == '', 'message save must not need Leader')
vim.api.nvim_buf_set_lines(draft, 0, -1, false, { 'reword ancestor from float' })
local confirm = vim.fn.confirm
vim.fn.confirm = function() return 1 end
vim.cmd('write')
vim.fn.confirm = confirm
assert(result and git({ 'log', '-1', '--format=%s', 'HEAD^' }) == 'reword ancestor from float')
assert(git({ 'show', ':file.txt' }) == 'staged' and vim.fn.readfile(root .. '/file.txt')[1] == 'unstaged')
assert(not vim.api.nvim_buf_is_valid(draft))
assert(_G.git_foldtext == nil, 'Legacy view globals leaked into the independent actions')
vim.api.nvim_buf_delete(origin, { force = true }); vim.fn.delete(root, 'rf')
print('PASS: shared message float uses guarded rewrite, preserving staged/unstaged work without legacy view setup')
