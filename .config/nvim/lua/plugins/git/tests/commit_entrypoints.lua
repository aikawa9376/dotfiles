local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false' }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr); return vim.trim(result.stdout or '')
end
git({ 'init', '-q' }); vim.fn.writefile({ 'hello' }, root .. '/a.txt'); git({ 'add', '.' }); git({ 'commit', '-qm', 'initial' })
local hash = git({ 'rev-parse', 'HEAD' })
local api = require('git.features.commit')
require('git').setup()
vim.cmd('cd ' .. vim.fn.fnameescape(root))
vim.cmd('Gedit ' .. hash)
assert(api.model(0).hash == hash)
vim.cmd('GitCommit ' .. hash)
assert(api.model(0).hash == hash)
assert(vim.fn.exists(':GitCommitLegacy') == 0)
local commands = require('git.features.commands')
commands.setup()
commands.open_preview_window(hash, root)
local preview_custom = false
for _, win in ipairs(vim.api.nvim_list_wins()) do
  local buf = vim.api.nvim_win_get_buf(win)
  if vim.b[buf].custom_git_commit then
    preview_custom = true
    assert(vim.bo[buf].filetype == 'fugitivecommit' and vim.bo[buf].bufhidden == 'delete')
  end
end
assert(preview_custom, 'commit preview bypassed custom view')
commands.close_preview()
vim.cmd('Gedit ' .. hash .. ':a.txt')
assert(not vim.b.custom_git_commit)
assert(vim.api.nvim_get_current_line() == 'hello')
assert(vim.fn.exists('*FugitiveGitDir') == 0)
for _, b in ipairs(vim.api.nvim_list_bufs()) do pcall(vim.api.nvim_buf_delete, b, { force = true }) end
vim.fn.delete(root, 'rf')
print('PASS: independent commit, preview and blob entrypoints')
