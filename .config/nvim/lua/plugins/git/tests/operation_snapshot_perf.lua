-- A status operation signature already resolved its Git directory for inspection.
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false' }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait(); assert(result.code == 0, result.stderr)
end
git({ 'init', '-qb', 'main' })
vim.fn.writefile({ 'base' }, root .. '/file.txt')
git({ 'add', '.' }); git({ 'commit', '-qm', 'base' })
local utils, renderer = require('git.utils'), require('git.features.status_renderer')
local resolve, calls = utils.get_git_dir, 0
utils.get_git_dir = function(...) calls = calls + 1; return resolve(...) end
local buf = vim.api.nvim_create_buf(false, true)
local lines = assert(renderer.snapshot(buf, root, {}))
assert(lines[1]:find('Head: main base', 1, true))
print(('Initial Status snapshot: Git-directory resolutions=%d'):format(calls))
assert(calls == 1, 'Operation inspection repeated a Git-directory query already made by its signature')
-- A cached directory still rechecks operation markers on every snapshot.
vim.fn.mkdir(root .. '/.git/rebase-merge', 'p')
vim.fn.writefile({ '2' }, root .. '/.git/rebase-merge/msgnum')
vim.fn.writefile({ '4' }, root .. '/.git/rebase-merge/end')
calls = 0
lines = assert(renderer.snapshot(buf, root, {}))
assert(table.concat(lines, '\n'):find('Rebase in progress', 1, true), 'Reusing the directory hid a new operation')
assert(calls == 0, 'A warm status forgot its already-resolved directory')
utils.get_git_dir = resolve
renderer.cleanup(buf); vim.api.nvim_buf_delete(buf, { force = true }); vim.fn.delete(root, 'rf')
print('PASS: reused operation directory, fresh progress markers and unchanged status header')
