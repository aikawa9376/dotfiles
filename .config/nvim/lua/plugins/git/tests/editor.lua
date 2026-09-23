local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local root = vim.fn.tempname() .. ' editor repo'; vim.fn.mkdir(root, 'p')
local function git(args) return require('git.objects').run(root, args) end
git({ 'init', '-q' }); git({ 'config', 'user.name', 'Test' }); git({ 'config', 'user.email', 'test@example.invalid' }); git({ 'config', 'commit.gpgsign', 'false' })
vim.fn.writefile({ 'hello' }, root .. '/file.txt'); git({ 'add', '.' })
require('git').setup(); vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/file.txt'))
vim.cmd('Git commit')
local job = vim.b.terminal_job_id
assert(vim.wait(10000, function() return vim.bo.filetype == 'gitcommit' end, 20), 'Git editor did not open in this Neovim')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'message from parent Neovim' }); vim.cmd('write'); vim.cmd('close')
assert(vim.wait(10000, function()
  local r = vim.system({ 'git', '-C', root, 'log', '-1', '--format=%s' }, { text = true }):wait()
  return r.code == 0 and vim.trim(r.stdout) == 'message from parent Neovim'
end, 20), 'Git did not resume after closing message buffer')
assert(vim.wait(5000, function() return vim.fn.jobwait({ job }, 0)[1] ~= -1 end, 20), 'Git job did not exit')
-- Interactive rebase uses the same sequence editor, then the message editor.
vim.fn.writefile({ 'second' }, root .. '/file.txt'); git({ 'add', '.' }); git({ 'commit', '-qm', 'second' })
vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/file.txt'))
vim.cmd('Git rebase -i HEAD~1')
job = vim.b.terminal_job_id
assert(vim.wait(10000, function() return vim.bo.filetype == 'gitrebase' end, 20), 'Sequence editor did not open')
local todo = vim.api.nvim_buf_get_lines(0, 0, -1, false)
for i, line in ipairs(todo) do if line:match('^pick ') then todo[i] = line:gsub('^pick ', 'reword '); break end end
vim.api.nvim_buf_set_lines(0, 0, -1, false, todo); vim.cmd('write'); vim.cmd('close')
assert(vim.wait(10000, function() return vim.bo.filetype == 'gitcommit' end, 20), 'Reword editor did not open')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'reword through sequence editor' }); vim.cmd('write'); vim.cmd('close')
assert(vim.wait(10000, function() return vim.fn.jobwait({ job }, 0)[1] ~= -1 end, 20), 'Rebase did not exit')
assert(vim.trim(git({ 'log', '-1', '--format=%s' })) == 'reword through sequence editor')
assert(vim.fn.exists('*FugitiveGitDir') == 0)
for _, b in ipairs(vim.api.nvim_list_bufs()) do pcall(vim.api.nvim_buf_delete, b, { force = true }) end
vim.fn.delete(root, 'rf')
print('PASS: real Git editor RPC, commit and interactive rebase/reword, save/close and completion without Fugitive')
