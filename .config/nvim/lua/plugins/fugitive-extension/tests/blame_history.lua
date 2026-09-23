local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid' }
  vim.list_extend(argv, args)
  local r = vim.system(argv, { text = true }):wait(); assert(r.code == 0, r.stderr); return vim.trim(r.stdout or '')
end
git({ 'init', '-q' })
local lines = {}; for n = 1, 20 do lines[n] = 'line ' .. n end
vim.fn.writefile(lines, root .. '/file.txt'); git({ 'add', '.' }); git({ 'commit', '-qm', 'base' })
local base = git({ 'rev-parse', 'HEAD' }); local branch = git({ 'branch', '--show-current' })
git({ 'checkout', '-qb', 'side' }); lines[2] = 'side'; vim.fn.writefile(lines, root .. '/file.txt')
git({ 'commit', '-qam', 'side' }); local side = git({ 'rev-parse', 'HEAD' })
git({ 'checkout', '-q', branch }); lines[2], lines[18] = 'line 2', 'main'; vim.fn.writefile(lines, root .. '/file.txt')
git({ 'commit', '-qam', 'main' }); local main = git({ 'rev-parse', 'HEAD' })
git({ 'merge', '--no-ff', '--no-commit', 'side' })
lines[2], lines[10] = 'side', 'merged line'; vim.fn.writefile(lines, root .. '/file.txt')
git({ 'add', '.' }); git({ 'commit', '-qm', 'merge resolution' }); local merge = git({ 'rev-parse', 'HEAD' })
local info = require('features.commit_info')
assert(info.lines(root, merge)[1]:find('(HEAD)', 1, true))
assert(info.lines(root, main)[1]:find('(HEAD~1)', 1, true))
assert(info.lines(root, base)[1]:find('(HEAD~2)', 1, true))
assert(info.lines(root, side)[1]:find('merged history', 1, true))
local tree = git({ 'rev-parse', 'HEAD^{tree}' })
local divergent = git({ 'commit-tree', tree, '-p', base, '-m', 'divergent' })
assert(info.lines(root, divergent)[1]:find('diverged from HEAD', 1, true))
local ahead = git({ 'commit-tree', tree, '-p', merge, '-m', 'ahead' })
assert(info.lines(root, ahead)[1]:find('1 commits ahead', 1, true))
assert(table.concat(info.lines(root, merge), '\n'):find('refs ', 1, true))
vim.cmd('edit ' .. root .. '/file.txt'); local code = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(0, { 10, 0 })
local blame = require('features.blame'); blame.setup(vim.api.nvim_create_augroup('BlameHistoryTest', { clear = true }))
local b = blame.open(); assert(vim.wait(2000, function() return vim.fn.bufwinid(b) ~= -1 end, 10)); local panel = vim.api.nvim_get_current_win()
local function press(key)
  assert(vim.fn.maparg(key, 'n', false, true).callback, key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), 'xt', false)
end
local function wait(fn, label) assert(vim.wait(2000, fn, 10), label) end
local function revision()
  local source = vim.b[vim.api.nvim_win_get_buf(code)].lazyagent_note_source
  return source and source.revision
end
wait(function() return vim.api.nvim_buf_line_count(b) == 20 end, 'initial')
local commands = require('features.commands')
commands.show_commit_info_float(base, true, true)
local found_info = false
for _, w in ipairs(vim.api.nvim_list_wins()) do
  local buf = vim.api.nvim_win_get_buf(w)
  if vim.bo[buf].filetype == 'gitcommitinfo' then
    assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:find('(HEAD~2)', 1, true))
    found_info = true
  end
end
assert(found_info, 'shared C float must show the same HEAD relationship')
commands.close_commit_info_float()
press('-'); wait(function() return revision() == merge end, 'reblame selected commit')
vim.cmd('normal 2P'); wait(function() return revision() == side end, 'numbered merge parent')
assert(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(code), 9, 10, false)[1] == 'line 10')
press('<C-o>'); assert(revision() == merge)
press('~'); wait(function() return revision() == main end, 'first parent')
press('<C-o>'); vim.cmd('normal 2~'); wait(function() return revision() == base end, 'counted first-parent history')
local warnings = {}; local notify = vim.notify; vim.notify = function(msg) warnings[#warnings + 1] = msg end
press('~'); assert(#warnings == 1 and revision() == base, 'root parent must not replace either pane')
vim.notify = notify
press('<C-o>'); assert(revision() == merge)
press('C'); assert(vim.api.nvim_win_get_width(panel) == 11)
press('A'); assert(vim.api.nvim_win_get_width(panel) > 10)
press('d')
assert(vim.wo.diff and #vim.api.nvim_tabpage_list_wins(0) == 2)
assert(vim.api.nvim_get_current_line() == 'merged line')
press('q')
wait(function() return vim.api.nvim_get_current_win() == panel end, 'q must return from diff without closing blame or Neovim')
for _ = 1, 3 do
  press('d'); vim.cmd('wincmd h'); press('q')
  wait(function() return vim.api.nvim_get_current_win() == panel end, 'repeated q from left diff')
end
vim.api.nvim_set_current_win(panel)
press('q'); assert(#vim.api.nvim_list_wins() == 1)
-- External replacement of the code pane closes the orphaned blame session.
b = blame.open(); assert(vim.wait(2000, function() return vim.fn.bufwinid(b) ~= -1 end, 10)); panel = vim.api.nvim_get_current_win()
wait(function() return vim.api.nvim_buf_line_count(b) == 20 end, 'reopen')
vim.api.nvim_set_current_win(code); vim.cmd('enew')
assert(not vim.api.nvim_buf_is_valid(b) and #vim.api.nvim_list_wins() == 1)
assert(vim.api.nvim_buf_get_name(0) == '', 'cleanup must not overwrite the newly selected file')
for _, buf in ipairs(vim.api.nvim_list_bufs()) do pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
vim.fn.delete(root, 'rf')
print('PASS: attributed commit, numbered merge parent, counted ancestors, root boundary, diff/width actions, external pane cleanup')
