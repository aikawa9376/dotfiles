local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout or '')
end
local function write(path, lines) vim.fn.writefile(lines, root .. '/' .. path) end
local function commit(msg) git({ 'add', '.' }); git({ 'commit', '-qm', msg }); return git({ 'rev-parse', 'HEAD' }) end
git({ 'init', '-q', '-b', 'main' })
git({ 'config', 'user.name', 'Test' }); git({ 'config', 'user.email', 'test@example.invalid' })
git({ 'config', 'commit.gpgsign', 'false' })
write('a file.txt', { 'one', 'two' })
local initial = commit('initial\n\nroot body')
write('a file.txt', { 'one', 'changed' })
write('deleted.txt', { 'delete later' })
local second = commit('second\n\nmessage body')
git({ 'mv', 'a file.txt', 'renamed file.txt' })
vim.fn.delete(root .. '/deleted.txt')
write('new.txt', { 'new' }); write('binary.dat', { 'bin\nary' })
local tip = commit('third')
local api = require('features.commit')
local models = require('features.commit_model')
api.setup(vim.api.nvim_create_augroup('CommitViewTest', { clear = true }))
local b = assert(api.open({ work_tree = root, revision = second }))
assert(vim.bo[b].filetype == 'fugitivecommit' and vim.bo[b].buftype == 'acwrite')
local function press(key) local mapping = vim.fn.maparg(key, 'n', false, true); assert(mapping.callback, key); mapping.callback() end
local function content() return vim.api.nvim_buf_get_lines(b, 0, -1, false) end
local function find(pattern)
  for row, line in ipairs(content()) do if line:find(pattern, 1, true) then return row end end
  error('missing line: ' .. pattern)
end
local function focus(pattern) vim.api.nvim_win_set_cursor(0, { find(pattern), 0 }) end
local function text() return table.concat(content(), '\n') end
assert(text():find('message body', 1, true))
assert(text():find('M a file.txt', 1, true) and not text():find('@@'))
focus('M a file.txt'); press('o')
assert(text():find('-two', 1, true) and text():find('+changed', 1, true))
assert(api.entry_at(b, find('+changed')).path == 'a file.txt')
assert(require('fugitive_utils').get_commit(b) == second)
local subject = #api.model(b).header + 1
vim.api.nvim_buf_set_lines(b, subject - 1, subject, false, { 'edited second', 'extra paragraph' })
focus('M a file.txt'); press('o')
assert(text():find('extra paragraph', 1, true) and vim.bo[b].modified)
focus('M a file.txt'); press('o')
assert(api.entry_at(b, find('+changed')).path == 'a file.txt')
-- Reword an ancestor while preserving staged, unstaged, and untracked work.
write('new.txt', { 'new', 'staged' }); git({ 'add', 'new.txt' })
write('new.txt', { 'new', 'staged', 'unstaged' }); write('untracked.txt', { 'keep' })
local staged, unstaged = git({ 'diff', '--cached', '--binary' }), git({ 'diff', '--binary' })
local head_before_write = git({ 'rev-parse', 'HEAD' })
assert(not pcall(vim.cmd, 'write ' .. vim.fn.fnameescape(root .. '/export.txt')))
assert(git({ 'rev-parse', 'HEAD' }) == head_before_write, 'writing to a file unexpectedly rewrote history')
vim.cmd('write')
local rewritten = api.model(b).hash
assert(rewritten ~= second and rewritten ~= git({ 'rev-parse', 'HEAD' }))
assert(git({ 'show', '-s', '--format=%B', rewritten }):find('extra paragraph', 1, true))
assert(git({ 'rev-parse', rewritten .. '^{tree}' }) == git({ 'rev-parse', second .. '^{tree}' }))
assert(git({ 'diff', '--cached', '--binary' }) == staged and git({ 'diff', '--binary' }) == unstaged)
assert(vim.fn.readfile(root .. '/untracked.txt')[1] == 'keep' and not vim.bo[b].modified)
local old_head = git({ 'rev-parse', 'HEAD' })
vim.api.nvim_buf_set_lines(b, 0, 1, false, { 'damaged metadata' })
assert(not api.write(b) and git({ 'rev-parse', 'HEAD' }) == old_head)
vim.api.nvim_buf_set_lines(b, 0, 1, false, { api.model(b).header[1] }); vim.bo[b].modified = false
-- A commit hook rejection aborts the rebase, restores work, and keeps the draft.
write('.git/hooks/commit-msg', { '#!/bin/sh', 'exit 1' })
vim.fn.setfperm(root .. '/.git/hooks/commit-msg', 'rwxr-xr-x')
local edited_subject = find('edited second')
vim.api.nvim_buf_set_lines(b, edited_subject - 1, edited_subject, false, { 'draft rejected by hook' })
assert(not api.write(b))
assert(text():find('draft rejected by hook', 1, true) and vim.bo[b].modified)
assert(git({ 'rev-parse', 'HEAD' }) == old_head)
assert(git({ 'diff', '--cached', '--binary' }) == staged and git({ 'diff', '--binary' }) == unstaged)
vim.fn.delete(root .. '/.git/hooks/commit-msg')
vim.api.nvim_buf_set_lines(b, edited_subject - 1, edited_subject, false, { 'edited second' })
vim.bo[b].modified = false
local model = assert(models.load(root, tip))
local entries = {}
for _, entry in ipairs(model.entries) do entries[entry.path] = entry end
assert(entries['renamed file.txt'].old_path == 'a file.txt')
assert(entries['deleted.txt'].status == 'D' and entries['binary.dat'].binary)
assert(models.inline(model, entries['renamed file.txt']))
local root_model = assert(models.load(root, initial))
assert(#root_model.parents == 0 and root_model.entries[1].status == 'A')
assert(table.concat(assert(models.inline(root_model, root_model.entries[1])), '\n'):find('+one', 1, true))
focus('M a file.txt'); press('d')
local wins = vim.api.nvim_tabpage_list_wins(0)
assert(#wins == 2)
local buffers = {}
for _, win in ipairs(wins) do buffers[#buffers + 1] = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), '\n') end
assert(vim.tbl_contains(buffers, 'one\ntwo') and vim.tbl_contains(buffers, 'one\nchanged'))
vim.cmd('tabclose'); vim.api.nvim_set_current_buf(b)
for _, key in ipairs({ 'X', 'A', 'cw', 'gA', 'C', 'O', 'p', '~', 'gf', 'gq', '<C-y>', '<C-Space>', 'gL', 'gp', 'q', 'R', 'g?' }) do
  assert(vim.fn.maparg(key, 'n') ~= '', 'missing inherited action: ' .. key)
end
vim.api.nvim_buf_delete(b, { force = true }); assert(api.model(b) == nil)
vim.fn.delete(root, 'rf')
print('PASS: custom commit, drafts, reword ancestor, dirty state, immutable diff, root/rename/binary, actions, teardown')
