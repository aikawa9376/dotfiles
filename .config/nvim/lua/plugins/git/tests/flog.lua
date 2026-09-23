local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
vim.opt.rtp:prepend(plugin)
vim.opt.rtp:prepend(vim.fn.stdpath('data') .. '/lazy/lazy.nvim')
vim.cmd('filetype plugin on')
vim.g.flog_write_commit_graph = false
local spec = dofile(plugin .. '/init.lua'); spec.dir = plugin
require('lazy').setup({ spec = { spec, dofile(vim.fs.dirname(plugin) .. '/flog.lua') },
  install = { missing = false }, checker = { enabled = false }, change_detection = { enabled = false },
  lockfile = vim.fn.tempname(), performance = { rtp = { reset = false }, cache = { enabled = false } } })
local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
local objects = require('git.objects')
local function git(args) return objects.run(root, args) end
git({ 'init', '-q', '-b', 'main' }); git({ 'config', 'user.name', 'Test' }); git({ 'config', 'user.email', 'test@example.invalid' }); git({ 'config', 'commit.gpgsign', 'false' })
vim.fn.writefile({ 'one' }, root .. '/a.txt'); git({ 'add', '.' }); git({ 'commit', '-qm', 'first' })
vim.cmd('edit ' .. root .. '/a.txt')
local file = vim.api.nvim_get_current_buf()
assert(vim.g.git_graph_backend == nil, 'Test must exercise the unset default')
vim.cmd('Ggraph')
assert(vim.bo.filetype == 'floggraph', 'Flog did not open')
assert(vim.b.fugitive_work_tree == root and vim.fn['flog#backend#GetGitDir']() == root .. '/.git')
local hash = vim.fn['flog#Format']('%H')
assert(vim.trim(git({ 'rev-parse', hash })) == vim.trim(git({ 'rev-parse', 'HEAD' })))
vim.cmd('vertical belowright Flogsplitcommit')
local found = false
for _, win in ipairs(vim.api.nvim_list_wins()) do
  if vim.b[vim.api.nvim_win_get_buf(win)].custom_git_commit then found = true end
end
assert(found, 'Flog commit selection did not use native Gsplit')
assert(vim.fn.exists('*FugitiveGitDir') == 0 and vim.g.loaded_fugitive == nil)
vim.cmd('only')
vim.cmd('buffer ' .. file)
vim.cmd('GgraphBackend flog')
vim.cmd('Ggraph')
assert(vim.bo.filetype == 'floggraph')
vim.cmd('close')
-- The existing commit-panel key must use Flog without selecting a backend.
vim.g.git_graph_backend = nil
vim.cmd('Gedit HEAD')
local commit_win = vim.api.nvim_get_current_win()
vim.fn.maparg('<C-Space>', 'n', false, true).callback()
assert(vim.api.nvim_get_current_win() == commit_win)
assert(vim.g.flog_win and vim.bo[vim.api.nvim_win_get_buf(vim.g.flog_win)].filetype == 'floggraph')
vim.fn.maparg('<C-Space>', 'n', false, true).callback()
assert(vim.g.flog_win == nil, 'Graph toggle did not close Flog')
vim.cmd('GgraphBackend native')
vim.cmd('Ggraph')
assert(vim.bo.filetype == 'git')
vim.cmd('close')
for _, b in ipairs(vim.api.nvim_list_bufs()) do pcall(vim.api.nvim_buf_delete, b, { force = true }) end
vim.fn.delete(root, 'rf')
print('PASS: actual Flog with native backend, commit selection, configurable native/Flog graphs, no Fugitive')
