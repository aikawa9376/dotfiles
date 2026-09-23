local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local fugitive = vim.fn.stdpath('data') .. '/lazy/vim-fugitive'
assert(vim.fn.isdirectory(fugitive) == 1, 'Installed vim-fugitive required')
vim.opt.rtp:prepend(fugitive)
vim.cmd('runtime plugin/fugitive.vim')
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
local api = require('features.commit')
api.setup(vim.api.nvim_create_augroup('CommitEntrypointsTest', { clear = true }))
vim.cmd('cd ' .. vim.fn.fnameescape(root))
vim.cmd('edit fugitive://' .. root .. '/.git//' .. hash)
assert(vim.wait(3000, function() return vim.b.custom_git_commit == true end, 10), 'Fugitive object did not open custom view')
local custom = vim.api.nvim_get_current_buf()
assert(api.model(custom).hash == hash)
local old = assert(api.open_legacy({ work_tree = root, revision = hash }))
vim.wait(50, function() return false end)
assert(vim.api.nvim_get_current_buf() == old and vim.bo[old].filetype == 'git' and not vim.b[old].custom_git_commit)
assert(vim.fn.maparg('X', 'n') ~= '' and vim.fn.maparg('cw', 'n') ~= '', 'legacy mappings missing')
vim.cmd('GitCommit ' .. hash)
assert(api.model(0).hash == hash)
vim.cmd('GitCommit! ' .. hash)
assert(vim.api.nvim_get_current_buf() == old)
-- Explicit legacy preference is honored for direct callers as well.
vim.g.fugitive_extension_commit_view = 'legacy'
assert(api.open({ work_tree = root, revision = hash }) == old)
vim.g.fugitive_extension_commit_view = nil
local commands = require('features.commands')
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
-- Blob objects remain ordinary Fugitive blobs.
vim.cmd('edit fugitive://' .. root .. '/.git//' .. hash .. '/a.txt')
vim.wait(50, function() return false end)
assert(not vim.b.custom_git_commit)
for _, b in ipairs(vim.api.nvim_list_bufs()) do pcall(vim.api.nvim_buf_delete, b, { force = true }) end
vim.fn.delete(root, 'rf')
print('PASS: real Fugitive URI interception, custom/legacy commands, opt-out, unchanged blob entrypoint')
