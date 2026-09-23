vim.env.GIT_AUTHOR_DATE = '2000-01-01T00:00:00Z'
vim.env.GIT_COMMITTER_DATE = '2000-01-01T00:00:00Z'
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
vim.opt.rtp:prepend(vim.fn.stdpath('data') .. '/lazy/gitsigns.nvim')
require('gitsigns').setup({ update_debounce = 10 })
vim.o.number, vim.o.relativenumber, vim.o.wrap = true, true, true
vim.o.foldmethod, vim.o.foldenable, vim.o.foldcolumn = 'indent', true, '1'
local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid' }
  vim.list_extend(argv, args)
  local r = vim.system(argv, { text = true }):wait(); assert(r.code == 0, r.stderr); return vim.trim(r.stdout or '')
end
git({ 'init', '-q' })
local lines = {}; for i = 1, 100 do lines[i] = 'line ' .. i end
vim.fn.writefile(lines, root .. '/file.txt'); vim.fn.writefile({ 'first' }, root .. '/other.txt')
git({ 'add', '.' }); git({ 'commit', '-qm', 'initial' })
lines[10], lines[80] = 'changed ten', 'changed eighty'
vim.fn.writefile(lines, root .. '/file.txt'); vim.fn.writefile({ 'second' }, root .. '/other.txt')
vim.fn.writefile({ 'new line' }, root .. '/added.txt')
git({ 'add', '.' }); git({ 'commit', '-qm', 'modified' })
local api = require('git.features.commit')
api.setup(vim.api.nvim_create_augroup('CommitBlobReturnTest', { clear = true }))
local b = api.open({ work_tree = root, split = true })
local function press(key) assert(vim.fn.maparg(key, 'n', false, true).callback, key)() end
local function find(text)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do if line == text then return row end end
end
api.expand_file(b, 'file.txt')
api.expand_file(b, 'other.txt')
vim.api.nvim_win_set_cursor(0, { find('M other.txt'), 0 }); press('<')
vim.api.nvim_win_set_cursor(0, { find('+changed eighty'), 5 }); vim.cmd('normal! zt')
local view = vim.fn.winsaveview()
local function stable(lines)
  return vim.tbl_map(function(line) return line:gsub('%(%d+ seconds? ago%)', '(recent)') end, lines)
end
local original = stable(vim.api.nvim_buf_get_lines(b, 0, -1, false))
local name = vim.api.nvim_buf_get_name(b)
press('<CR>')
local blob = vim.api.nvim_get_current_buf()
local blob_name = vim.api.nvim_buf_get_name(blob)
local expected_name = require('git.objects').uri(root, git({ 'rev-parse', 'HEAD' }) .. ':file.txt')
  :gsub('^git%-object:', 'git-commit-blob:')
assert(blob_name == expected_name, 'blob URI should identify the repository, revision and path without an open counter')
assert(vim.bo[blob].bufhidden == 'wipe' and not vim.bo[blob].modifiable)
assert(vim.wo.number and vim.wo.relativenumber and vim.wo.wrap, 'blob inherited panel display options')
assert(vim.wo.foldmethod == 'indent' and vim.wo.foldenable and vim.wo.foldcolumn == '1')
assert(vim.wait(2000, function()
  local summary = vim.b[blob].gitsigns_status_dict
  return summary and summary.changed == 2
end, 10), 'Gitsigns should mark both changes against the selected parent')
local signs_ns = vim.api.nvim_get_namespaces().gitsigns_signs_
assert(vim.wait(2000, function()
  return signs_ns and #vim.api.nvim_buf_get_extmarks(blob, signs_ns, 0, -1, {}) > 0
end, 10), 'Commit preview should place visible Gitsigns signs')
assert(vim.fn.line('.') == 80, 'blob cursor should map to the file line')
assert(not vim.api.nvim_buf_is_loaded(b), 'panel must still unload after opening a blob')
vim.cmd('execute "normal! \\<C-o>"')
assert(vim.wait(1000, function() return vim.api.nvim_get_current_buf() == b and vim.fn.line('.') == view.lnum end, 10), 'Ctrl-o did not restore panel cursor')
assert(vim.deep_equal(stable(vim.api.nvim_buf_get_lines(b, 0, -1, false)), original), 'expanded/collapsed file state was lost')
local restored = vim.fn.winsaveview()
assert(restored.col == view.col and restored.topline == view.topline, 'column or scroll position was lost')
assert(not vim.wo.number and not vim.wo.relativenumber)
assert(not vim.api.nvim_buf_is_loaded(blob), 'custom blob should be removed on return')
-- A second round trip must retain the current view, not the original first-open state.
vim.api.nvim_win_set_cursor(0, { find('+changed ten'), 3 }); vim.cmd('normal! zt')
local newer = vim.fn.winsaveview()
press('<CR>')
assert(vim.api.nvim_buf_get_name(0) == blob_name, 'reopening the same blob should keep its name')
assert(vim.wait(2000, function() return vim.b.gitsigns_status_dict ~= nil end, 10))
vim.cmd('execute "normal! \\<C-o>"')
assert(vim.wait(1000, function() return vim.api.nvim_get_current_buf() == b and vim.fn.line('.') == newer.lnum end, 10))
assert(vim.fn.winsaveview().topline == newer.topline)
-- A removed line in a modified file opens the parent blob at its old line.
vim.api.nvim_win_set_cursor(0, { find('-line 80'), 2 })
press('<CR>')
assert(vim.b.lazyagent_note_source.revision == git({ 'rev-parse', 'HEAD^' }))
assert(vim.fn.line('.') == 80 and vim.api.nvim_get_current_line() == 'line 80')
assert(vim.wait(2000, function() return vim.b.gitsigns_status_dict ~= nil end, 10))
vim.cmd('execute "normal! \\<C-o>"')
assert(vim.wait(1000, function() return vim.api.nvim_get_current_buf() == b and vim.fn.line('.') == find('-line 80') end, 10))
-- New files compare with an empty parent-side file even with attach_to_untracked disabled.
vim.api.nvim_win_set_cursor(0, { find('A added.txt'), 0 }); press('<CR>')
assert(vim.wait(2000, function()
  local summary = vim.b.gitsigns_status_dict
  return summary and summary.added == 1
end, 10), 'Gitsigns should mark an added file')
vim.cmd('execute "normal! \\<C-o>"')
assert(vim.wait(1000, function() return vim.api.nvim_get_current_buf() == b end, 10))
-- Wiping explicitly discards the saved view.
vim.api.nvim_buf_delete(b, { force = true })
vim.cmd('edit ' .. vim.fn.fnameescape(name))
assert(not table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('@@', 1, true))
for _, buf in ipairs(vim.api.nvim_list_bufs()) do pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
vim.fn.delete(root, 'rf')
print('PASS: custom blob lifecycle/options and Gitsigns parent comparison, file line, real Ctrl-o restores folds/cursor/scroll, repeated return, wipe cleanup')
