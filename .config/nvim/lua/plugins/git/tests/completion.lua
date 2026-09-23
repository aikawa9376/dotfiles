local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local root = vim.fn.tempname() .. ' completion'; vim.fn.mkdir(root .. '/nested', 'p')
local objects = require('git.objects')
local function git(args) return objects.run(root, args) end
git({ 'init', '-q', '-b', 'main' }); git({ 'config', 'user.name', 'Test' }); git({ 'config', 'user.email', 'test@example.invalid' }); git({ 'config', 'commit.gpgsign', 'false' })
vim.fn.writefile({ 'base' }, root .. '/nested/a file.txt'); git({ 'add', '.' }); git({ 'commit', '-qm', 'first' })
git({ 'branch', 'feature/DMM' }); git({ 'remote', 'add', 'origin', '/unused' })
require('git').setup()
vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/nested/a file.txt'))
local work = vim.api.nvim_get_current_buf()
local function complete(line) return vim.fn.getcompletion(line, 'cmdline') end
local function has(line, item) assert(vim.tbl_contains(complete(line), item), line .. ': ' .. vim.inspect(complete(line))) end
has('Git bl', 'blame')
has('Git --no-pager bl', 'blame')
has('Git -c color.ui=false checkout feature/', 'feature/DMM')
assert(#complete('Git commit -m bl') == 0)
for _, command in ipairs({ 'Gedit', 'Gsplit', 'Gvsplit', 'Gtabedit', 'Gread', 'Gdiff', 'Gdiffsplit', 'Gclog', 'Gllog', 'Glog', 'FugitiveLog', 'GitCommit' }) do
  has(command .. ' feature/', 'feature/DMM')
  assert(not vim.tbl_contains(complete(command .. ' bl'), 'blame'), 'subcommand leaked into ' .. command)
end
has('Gedit feature/DMM:', 'feature/DMM:nested/')
has('Gedit feature/DMM:nested/', 'feature/DMM:nested/a\\ file.txt')
has('Gedit :0:nested/', ':0:nested/a\\ file.txt')
has('Git diff --ca', '--cached')
has('Git checkout feature/', 'feature/DMM')
has('Git add nested/', 'nested/a\\ file.txt')
has('Git log -- nested/', 'nested/a\\ file.txt')
has('Glog -- nested/', 'nested/a\\ file.txt')
has('Git push or', 'origin')
has('Gwrite nested/', 'nested/a\\ file.txt')
has('Glcd ne', 'nested/')
vim.cmd('Gedit feature/DMM:%')
assert(vim.api.nvim_get_current_line() == 'base')
vim.cmd('Gedit feature/DMM:%') -- historical buffer context
assert(vim.api.nvim_get_current_line() == 'base')
vim.cmd('buffer ' .. work)
vim.cmd('Gedit feature/DMM:nested/a\\ file.txt')
assert(vim.api.nvim_get_current_line() == 'base')
-- A file absent at a real branch is not an invalid revision, and must not
-- replace the source window or emit an unhandled Lua traceback.
vim.fn.writefile({ 'new' }, root .. '/new.txt')
vim.cmd('edit ' .. root .. '/new.txt')
local original, notices, notify = vim.api.nvim_get_current_buf(), {}, vim.notify
vim.notify = function(message) notices[#notices + 1] = message end
vim.cmd('Gedit feature/DMM:%')
vim.notify = notify
assert(vim.api.nvim_get_current_buf() == original)
assert(#notices == 1 and notices[1]:find('feature/DMM:new.txt', 1, true) and notices[1]:find("not in 'feature/DMM'", 1, true), vim.inspect(notices))
assert(not notices[1]:find('Needed a single revision', 1, true))
for _, b in ipairs(vim.api.nvim_list_bufs()) do pcall(vim.api.nvim_buf_delete, b, { force = true }) end
vim.fn.delete(root, 'rf')
print('PASS: per-command and positional completion, revision trees/index, root-relative escaped paths, slash branch/current file')
