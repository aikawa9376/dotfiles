local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
local function git(args, date)
  local argv = { 'git', '-C', root, '-c', 'user.name=Test Author', '-c', 'user.email=test@example.invalid' }
  vim.list_extend(argv, args)
  local r = vim.system(argv, { text = true, env = date and { GIT_AUTHOR_DATE = date, GIT_COMMITTER_DATE = date } or nil }):wait()
  assert(r.code == 0, r.stderr); return vim.trim(r.stdout or '')
end
git({ 'init', '-q' })
vim.fn.writefile({ 'alpha', 'old', 'omega', 'tail' }, root .. '/old name.txt')
git({ 'add', '.' }); git({ 'commit', '-qm', 'initial\n\nInitial body' }, '2020-01-01T12:00:00+0900')
local first = git({ 'rev-parse', 'HEAD' })
git({ 'mv', 'old name.txt', 'new name.txt' })
vim.fn.writefile({ 'alpha', 'inserted', 'new', 'omega', 'tail' }, root .. '/new name.txt')
git({ 'add', '.' }); git({ 'commit', '-qm', 'change\n\nChanged body' }, '2025-01-01T12:00:00+0900')
local second = git({ 'rev-parse', 'HEAD' })
vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/new name.txt'))
local original, code_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
vim.wo.wrap, vim.wo.foldenable, vim.wo.list = true, true, true
vim.api.nvim_buf_set_lines(original, 4, 5, false, { 'unsaved' })
vim.api.nvim_win_set_cursor(0, { 3, 2 })
local old_map_called = false
vim.keymap.set('n', 'gk', function() old_map_called = true end, { buffer = original })
local api = require('git.features.blame')
api.setup(vim.api.nvim_create_augroup('BlameTest', { clear = true }))
local initial_view = vim.fn.winsaveview()
local b = api.open()
assert(vim.api.nvim_get_current_win() == code_win and #vim.api.nvim_list_wins() == 1, 'loading must not change visible layout')
assert(vim.deep_equal(vim.fn.winsaveview(), initial_view))
assert(vim.wait(3000, function() return vim.fn.bufwinid(b) ~= -1 end, 10))
local panel = vim.api.nvim_get_current_win()
local panel_name = vim.api.nvim_buf_get_name(b)
assert(panel_name == 'git-blame://' .. root .. '//worktree/new name.txt')
local function wait(fn, label) assert(vim.wait(3000, fn, 10), label) end
local function text(buf) return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end
local function press(key) local m = vim.fn.maparg(key, 'n', false, true); assert(m.callback, key)() end
wait(function() return vim.api.nvim_buf_line_count(b) == 5 end, 'initial blame')
local original_columns = vim.o.columns
vim.o.columns = 54
press('g?')
local guide = vim.api.nvim_buf_get_lines(0, 0, -1, false)
assert(guide[1] == 'Git blame' and vim.wo.wrap and vim.api.nvim_win_get_width(0) <= 50)
assert(vim.tbl_contains(guide, '<C-o> / <C-i>  back / forward (code and blame together)'))
press('q')
assert(vim.api.nvim_get_current_buf() == b)
vim.o.columns = original_columns
assert(vim.wo[panel].winbar == '')
assert(vim.wo[code_win].winbar:find('change', 1, true), 'code winbar should show commit subject')
assert(vim.fn.exists(':Git') ~= 2, 'test must not depend on Fugitive')
assert(text(b):find('2020%-01%-01') and text(b):find('2025%-01%-01'))
local function uncommitted_label()
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(b, vim.api.nvim_create_namespace('git_blame_panel'), 0, -1, { details = true })) do
    if mark[4].virt_text and mark[4].virt_text[1][1] == 'Not committed ' then return mark end
  end
end
local label = assert(uncommitted_label())
assert(label[4].virt_text_pos == 'right_align')
assert(not vim.api.nvim_buf_get_lines(b, label[2], label[2] + 1, false)[1]:find('%d'), 'uncommitted row must not show a date/hash')
local selected_hl = vim.api.nvim_get_hl(0, { name = 'GitBlameSelected' })
assert(selected_hl.bg == 0x002b36 and not selected_hl.underline and not selected_hl.fg)
assert(vim.api.nvim_get_hl(0, { name = 'GitBlameUnselected' }).bg == 0x073642)
local selected_marks = vim.api.nvim_buf_get_extmarks(b, vim.api.nvim_create_namespace('git_blame_selected'), 0, -1, { details = true })
assert(#selected_marks > 0 and selected_marks[1][4].hl_eol, 'selection must cover the whole row')
assert(#selected_marks == 5)
for _, mark in ipairs(selected_marks) do
  local expected = (mark[2] == 1 or mark[2] == 2) and 'GitBlameSelected' or 'GitBlameUnselected'
  assert(mark[4].hl_group == expected, 'whole current commit must use Normal, other commits NormalNC')
end
assert(vim.api.nvim_get_hl(0, { name = 'GitBlameUnselected' }).bg ~= selected_hl.bg)
local marks = vim.api.nvim_buf_get_extmarks(b, vim.api.nvim_create_namespace('git_blame_panel'), 0, -1, { details = true })
local rendered = vim.api.nvim_buf_get_lines(b, 0, -1, false)
local max_width = 0
for _, line in ipairs(rendered) do
  assert(not line:match('%s$'), 'trailing whitespace in annotation')
  max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
end
assert(rendered[2]:match('^┍ ') and rendered[3] == '┕', 'group metadata must appear only once, with leftmost edge')
assert(vim.api.nvim_win_get_width(panel) == max_width + 1, 'panel must fit its content plus one padding column')
assert(not vim.wo[panel].list and vim.wo[code_win].list, 'list option must be disabled only in blame')
local edge_color, hash_color, continuation_color
for _, mark in ipairs(marks) do
  if mark[2] == 1 and mark[3] == 0 then edge_color = mark[4].hl_group end
  if mark[2] == 1 and mark[3] == 4 then hash_color = mark[4].hl_group end
  if mark[2] == 2 and mark[3] == 0 then continuation_color = mark[4].hl_group end
end
assert(edge_color == hash_color and hash_color == continuation_color and hash_color:match('^GitBlameHash'))
assert(vim.api.nvim_get_hl(0, { name = hash_color }).fg ~= nil)
local mode = vim.g.fugitive_blame_gradient_mode; press('c'); assert(vim.g.fugitive_blame_gradient_mode ~= mode)
vim.api.nvim_win_set_cursor(panel, { 3, 0 })
press('gk')
local function float_text(kind)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local config = vim.api.nvim_win_get_config(w)
    if config.relative ~= '' and ((kind == 'info' and not config.bufpos) or (kind == nil and config.zindex == 60)) then
      return text(vim.api.nvim_win_get_buf(w)), config
    end
  end
end
assert(float_text():find('Changed body', 1, true))
assert(float_text():sub(-#'Changed body') == 'Changed body', 'gk has trailing blank lines')
assert(float_text():find('change\n\nChanged body', 1, true), 'intentional paragraph spacing must be preserved')
assert(select(2, float_text()).bufpos[1] == 2, 'gk must be anchored at the selected code row')
vim.api.nvim_win_set_cursor(panel, { 1, 0 })
vim.api.nvim_exec_autocmds('CursorMoved', { buffer = b })
wait(function() return (float_text() or ''):find('Initial body', 1, true) end, 'message follows cursor')
assert(select(2, float_text()).bufpos[1] == 0, 'gk anchor must follow movement within the view')
press('gk'); assert(float_text() == nil)
vim.api.nvim_win_set_cursor(panel, { 3, 0 }); press('~')
wait(function() return vim.api.nvim_buf_line_count(b) == 4 end, 'parent blame across rename')
local historic = vim.api.nvim_win_get_buf(code_win)
assert(float_text('info'):find(first, 1, true), 'history info must show the viewed revision')
local info_config = select(2, float_text('info'))
assert(info_config.row == 0 and info_config.col + info_config.width + 2 == vim.api.nvim_win_get_width(code_win))
press('gk'); assert(float_text() and float_text('info'), 'message and history info should coexist')
press('gk'); assert(not float_text() and float_text('info'), 'gk must not close pinned history info')
assert(text(historic) == 'alpha\nold\nomega\ntail')
assert(vim.api.nvim_win_get_cursor(code_win)[1] == 2, 'mapped old line')
assert(text(b):find(first:sub(1, 8), 1, true))
assert(vim.api.nvim_win_get_buf(code_win) ~= original and not vim.bo[historic].modifiable)
vim.cmd('execute "normal \\<C-o>"')
assert(vim.api.nvim_win_get_buf(code_win) == original and vim.bo[original].modified)
assert(float_text('info') == nil, 'working tree return must close history info')
assert(vim.api.nvim_win_get_cursor(panel)[1] == 3)
assert(vim.api.nvim_buf_line_count(b) == 5)
vim.api.nvim_set_current_win(code_win); vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-i>', true, false, true), 'xt', false)
assert(vim.api.nvim_win_get_buf(code_win) == historic)
press('<C-o>'); assert(vim.api.nvim_win_get_buf(code_win) == original)
vim.api.nvim_set_current_win(panel)
press('<C-p>'); assert(float_text():find('diff --git', 1, true)); press('<C-p>')
vim.api.nvim_buf_set_lines(original, 4, 5, false, { 'tail' })
vim.api.nvim_exec_autocmds('TextChanged', { buffer = original })
wait(function() return not uncommitted_label() end, 'live source edit refresh')
press('q')
assert(not vim.api.nvim_buf_is_valid(b) and not vim.api.nvim_buf_is_valid(historic))
assert(vim.api.nvim_win_get_buf(code_win) == original and vim.bo[original].modified)
assert(vim.wo[code_win].wrap and vim.wo[code_win].foldenable and not vim.wo[code_win].scrollbind)
assert(vim.wo[code_win].winbar == '' and vim.go.winbar == '', 'blame winbar leaked into ordinary windows')
vim.api.nvim_set_current_win(code_win); press('gk'); assert(old_map_called)
assert(vim.api.nvim_win_get_cursor(code_win)[1] == 3)
-- Heatmap remains available on the original unsaved buffer.
assert(api.set_heatmap_enabled(original, true))
wait(function() return #vim.api.nvim_buf_get_extmarks(original, vim.api.nvim_create_namespace('fugitive_blame_heatmap'), 0, -1, {}) == 5 end, 'heatmap')
api.set_heatmap_enabled(original, false)
-- Close while blame is still running: late results must not create windows.
b = api.open(); assert(vim.api.nvim_buf_get_name(b) == panel_name, 'reopen must keep stable blame name'); vim.api.nvim_buf_delete(b, { force = true })
vim.wait(150, function() return false end, 10)
assert(not vim.api.nvim_buf_is_valid(b) and #vim.api.nvim_list_wins() == 1)
-- The code-side source may itself be a wipe-on-hide custom blob.
vim.api.nvim_buf_delete(original, { force = true })
local blob = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(blob, 'git-commit-blob://test/' .. second .. '/new name.txt')
vim.api.nvim_buf_set_lines(blob, 0, -1, false, { 'alpha', 'inserted', 'new', 'omega', 'tail' })
vim.bo[blob].bufhidden = 'wipe'
vim.bo[blob].modifiable = false
vim.b[blob].lazyagent_note_source = { kind = 'fugitive', root = root, path = 'new name.txt', revision = second }
vim.api.nvim_set_current_buf(blob)
vim.api.nvim_win_set_cursor(0, { 3, 0 })
b = api.open()
wait(function() return vim.api.nvim_buf_line_count(b) == 5 end, 'blob blame')
press('~'); wait(function() return vim.api.nvim_buf_line_count(b) == 4 end, 'blob parent')
assert(vim.api.nvim_buf_is_loaded(blob), 'origin blob was wiped during history navigation')
press('<C-o>'); press('q')
assert(vim.api.nvim_get_current_buf() == blob and vim.bo[blob].bufhidden == 'wipe')
-- Commit opening retains the attributed file and exact changed line.
require('git.features.commit').setup(vim.api.nvim_create_augroup('BlameCommitTest', { clear = true }))
b = api.open()
wait(function() return vim.api.nvim_buf_line_count(b) == 5 end, 'commit entry')
local return_panel = vim.api.nvim_get_current_win()
local return_tab = vim.api.nvim_get_current_tabpage()
local panel_view = vim.fn.winsaveview()
local code_view = vim.api.nvim_win_call(code_win, vim.fn.winsaveview)
press('<CR>')
assert(vim.bo.filetype == 'fugitivecommit' and vim.b.fugitive_commit == second)
assert(vim.api.nvim_get_current_line() == '+new', 'commit should focus the attributed diff line')
assert(vim.api.nvim_get_current_tabpage() ~= return_tab)
local commit_buf = vim.api.nvim_get_current_buf()
-- Re-enter the deleted commit buffer through the actual jump list.
press('<CR>')
vim.cmd('execute "normal! \\<C-o>"')
wait(function() return vim.api.nvim_get_current_buf() == commit_buf end, 'blob Ctrl-o return')
local float_buf = vim.api.nvim_create_buf(false, true)
local float = vim.api.nvim_open_win(float_buf, false, { relative = 'editor', row = 1, col = 1, width = 10, height = 1 })
press('q')
assert(vim.api.nvim_get_current_win() == return_panel, 'q must return to blame even with another float')
assert(vim.api.nvim_win_get_buf(return_panel) == b)
assert(vim.deep_equal(vim.fn.winsaveview(), panel_view), 'blame view changed')
assert(vim.deep_equal(vim.api.nvim_win_call(code_win, vim.fn.winsaveview), code_view), 'code view changed')
if vim.api.nvim_win_is_valid(float) then vim.api.nvim_win_close(float, true) end
press('<CR>'); vim.api.nvim_win_set_cursor(0, { 1, 0 }); press('~'); press('q')
assert(vim.api.nvim_get_current_win() == return_panel, 'parent navigation lost return target')
press('~'); wait(function() return vim.api.nvim_buf_line_count(b) == 4 end, 'parent before reopening commit')
press('<C-o>')
assert(vim.api.nvim_buf_line_count(b) == 5)
press('<CR>'); press('q')
assert(vim.api.nvim_get_current_win() == return_panel, 'blame history Ctrl-o lost return target')
assert(vim.deep_equal(vim.fn.winsaveview(), panel_view))
press('<CR>')
for _ = 1, 5 do
  if vim.api.nvim_get_current_win() == return_panel then break end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-o>', true, false, true), 'xt', false)
  vim.wait(30, function() return vim.api.nvim_get_current_win() == return_panel end, 5)
end
assert(vim.api.nvim_get_current_win() == return_panel, 'commit Ctrl-o must restore the pair, not a lone blame buffer')
assert(vim.api.nvim_get_current_tabpage() == return_tab)
assert(vim.deep_equal(vim.fn.winsaveview(), panel_view))
assert(vim.deep_equal(vim.api.nvim_win_call(code_win, vim.fn.winsaveview), code_view))
-- The same native jump return must work from a split and a historical frame.
press('~'); wait(function() return vim.api.nvim_buf_line_count(b) == 4 end, 'historical inspection')
local historical_code = vim.api.nvim_win_get_buf(code_win)
local historical_view = vim.api.nvim_win_call(code_win, vim.fn.winsaveview)
local historical_panel_view = vim.fn.winsaveview()
for _, key in ipairs({ 'o', '<CR>' }) do
  press(key)
  for _ = 1, 8 do
    if vim.api.nvim_get_current_win() == return_panel then break end
    vim.cmd('execute "normal! \\<C-o>"')
    vim.wait(30, function() return vim.api.nvim_get_current_win() == return_panel end, 5)
  end
  assert(vim.api.nvim_get_current_win() == return_panel, 'native jump did not return to historical blame')
  assert(vim.api.nvim_win_get_buf(code_win) == historical_code)
  assert(vim.deep_equal(vim.fn.winsaveview(), historical_panel_view))
  assert(vim.deep_equal(vim.api.nvim_win_call(code_win, vim.fn.winsaveview), historical_view))
end
press('<C-o>')
assert(vim.api.nvim_buf_line_count(b) == 5, 'blame history must survive inspection')
press('q')
assert(vim.fn.exists(':GitBlameLegacy') == 0)
for _, buf in ipairs(vim.api.nvim_list_bufs()) do pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
vim.fn.writefile({ 'untracked' }, root .. '/untracked.txt')
vim.cmd('tabedit ' .. root .. '/untracked.txt')
local buffers, windows = #vim.api.nvim_list_bufs(), #vim.api.nvim_list_wins()
local notices, old_notify = {}, vim.notify
vim.notify = function(message) notices[#notices + 1] = message end
assert(api.open() == nil)
vim.notify = old_notify
assert(#vim.api.nvim_list_bufs() == buffers and #vim.api.nvim_list_wins() == windows, 'untracked blame must not create even a transient buffer/window')
assert(#notices == 1 and notices[1]:find('Untracked', 1, true))
vim.api.nvim_buf_delete(0, { force = true })
vim.fn.delete(root, 'rf')
print('PASS: Git-only blame, date modes, following floats, rename/old-line mapping, paired history, drafts/options/maps, cleanup, heatmap')
