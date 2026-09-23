local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root }; vim.list_extend(argv, args)
  local r = vim.system(argv, { text = true }):wait(); assert(r.code == 0, r.stderr); return vim.trim(r.stdout or '')
end
local function write(text) vim.fn.writefile(text, root .. '/a file.txt') end
git({ 'init', '-q' }); git({ 'config', 'user.name', 'Test' }); git({ 'config', 'user.email', 'test@example.invalid' }); git({ 'config', 'commit.gpgsign', 'false' })
write({ 'one', 'two' }); git({ 'add', '.' }); git({ 'commit', '-qm', 'initial' })
write({ 'one', 'new', 'another' }); git({ 'add', '.' }); git({ 'commit', '-qm', 'changes' })
local api = require('features.commit')
local b = api.open({ work_tree = root })
local function find(text)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do if line == text then return row end end
end
api.expand_file(b, 'a file.txt')
local confirm = vim.fn.confirm
vim.fn.confirm = function(prompt) return prompt:find('now empty', 1, true) and 2 or 1 end
local line = assert(find('+another'))
vim.api.nvim_win_set_cursor(0, { line, 0 })
vim.cmd('normal! v')
vim.fn.maparg('X', 'x', false, true).callback()
assert(git({ 'show', 'HEAD:a file.txt' }) == 'one\nnew', 'selected line discard changed unrelated lines')
api.expand_file(b, 'a file.txt')
vim.api.nvim_win_set_cursor(0, { find('@@ -1,2 +1,2 @@'), 0 })
vim.fn.maparg('X', 'n', false, true).callback()
assert(git({ 'show', 'HEAD:a file.txt' }) == 'one\ntwo', 'hunk discard failed')
assert(#api.model(b).entries == 0)
-- Drop the now-empty commit using the same rewrite engine.
local hash, err = require('features.commit_rewrite').apply(root, api.model(b).hash, { drop = true })
assert(hash, err)
assert(git({ 'show', '-s', '--format=%s', 'HEAD' }) == 'initial')
vim.fn.confirm = confirm
vim.api.nvim_buf_delete(b, { force = true }); vim.fn.delete(root, 'rf')
print('PASS: visual selected-line discard, hunk discard, empty commit drop')
