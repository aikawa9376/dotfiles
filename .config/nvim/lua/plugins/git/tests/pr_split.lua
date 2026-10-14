-- Real PR entrypoints/native splits, immutable Git blobs and mocked GitHub writes.
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
-- Two distant edits leave full-file rows that GitHub cannot accept as diff anchors.
local separated = {}; for i = 1, 30 do separated[i] = 'line ' .. i end
f.git({ 'checkout', '-q', 'main' }); vim.fn.writefile(separated, f.root .. '/separated.txt')
f.git({ 'add', '.' }); f.git({ 'commit', '-qm', 'base with distant lines' })
f.base = f.git({ 'rev-parse', 'HEAD' })
f.git({ 'checkout', '-q', 'topic' }); f.git({ 'rebase', 'main' })
separated[2], separated[28] = 'changed 2', 'changed 28'
vim.fn.writefile(separated, f.root .. '/separated.txt'); f.git({ 'add', '.' }); f.git({ 'commit', '-qm', 'distant edits' })
f.head = f.git({ 'rev-parse', 'HEAD' }); f.git({ 'update-ref', 'refs/pull/7/head', f.head })
f.pr.baseRefOid, f.pr.headRefOid = f.base, f.head
local ui = require('helpers.pr_ui').new(f)
local api = vim.api
local split = require('git.features.pr_split')
local async = require('git.features.async')
local original_select = vim.ui.select
vim.ui.select = function(items, _, callback)
  for _, item in ipairs(items) do if item.id == 101 then callback(item); return end end
  callback(items[1])
end
local pending = { id = 88, node_id = 'REVIEW88', commit_id = f.head, state = 'PENDING', body = '',
  user = { login = f.viewer }, comments = {
    { id = 601, body = 'Private range', user = { login = f.viewer }, path = 'file name.txt',
      line = 3, start_line = 2, side = 'RIGHT', commit_id = f.head, original_commit_id = f.head, subject_type = 'line' },
  } }
f.reviews = { pending }
f.api_response = function(path, method)
  if path == 'repos/org/repo/pulls/comments/201' and method == 'GET' then return { data = f.comments[1][3] } end
end
f.comments[2][#f.comments[2] + 1] = { id = 302, path = 'file name.txt', side = 'RIGHT', line = vim.NIL,
  subject_type = 'file', body = 'Whole file', user = { login = 'reviewer' } }
ui.open()
local source = api.nvim_get_current_win()
local title = ui.row('PR title')
api.nvim_buf_set_lines(ui.buf, title - 1, title, false, { 'Unsaved PR title' })
local function key(value)
  local map = vim.fn.maparg(value, 'n', false, true); assert(map.callback, value); return map.callback()
end
local function pane(p, row)
  api.nvim_set_current_win(p.win)
  if row then api.nvim_win_set_cursor(p.win, { row, 0 }) end
end
local function opened(path, mapping)
  ui.key(mapping or 'd', ui.row(path))
  local tab = api.nvim_get_current_tabpage()
  local s = assert(split._states[tab], 'PR context was not handed to the split')
  ui.wait(function() return s.coordinates and not s.loading end)
  assert(split._states[tab] == s and s.source == source)
  assert(vim.wo[s.panes[1].win].diff and vim.wo[s.panes[2].win].diff)
  assert(s.model.ctx.host == 'ghe.example.test' and s.model.ctx.repo == 'org/repo' and s.model.ctx.number == 7)
  return s, s.panes[1], s.panes[2]
end
local function fresh(s, fn)
  local old = s.model
  fn()
  ui.wait(function() return s.model ~= old and not s.loading and not async.busy(f.root) end)
end
local s, left, right = opened('M file name.txt')
assert(vim.deep_equal(api.nvim_buf_get_lines(left.buf, 0, -1, false), { 'one', 'two', 'three' }))
assert(vim.deep_equal(api.nvim_buf_get_lines(right.buf, 0, -1, false), { 'one', 'TWO', 'three', 'four' }))
assert(#left.rows[2] == 1 and left.rows[2][1].id == 201)
assert(#right.rows[2] == 1 and right.rows[2][1].id == 101 and right.rows[3][1].pending)
assert(not right.rows[1] and not right.rows[4], 'File/outdated comments were clamped onto code')
local target = assert(split.target(right, 2, 3))
assert(target.path == 'file name.txt' and target.side == 'RIGHT' and target.start_line == 2 and target.line == 3)
assert(split.target(left, 2, 2).side == 'LEFT')
pane(left, 1); key(']t')
assert(api.nvim_get_current_win() == left.win and vim.b[left.buf].git_pr_preview)
key(']t')
assert(api.nvim_get_current_win() == right.win and vim.b[right.buf].git_pr_preview)
key('gk')
assert(api.nvim_get_current_buf() == vim.b[right.buf].git_pr_preview, 'Second preview key did not focus')
key('[t')
assert(api.nvim_get_current_win() == left.win, 'Popup navigation lost the logical LEFT side')
-- Reading a preview creates no draft. Reply explicitly posts through the source PR.
pane(right, 2); key('gk'); key('gk'); key('gc')
local input = api.nvim_get_current_buf()
assert(vim.bo[input].buftype == 'acwrite')
ui.body({ 'Split reply' }); ui.send(input)
ui.wait(function() return not s.loading and not async.busy(f.root) end)
local sent
for _, call in ipairs(f.calls) do
  if call.opts.stdin and vim.tbl_contains(call.argv, 'repos/org/repo/pulls/7/comments/101/replies') then sent = vim.json.decode(call.opts.stdin) end
end
assert(sent and sent.body == 'Split reply')
assert(ui.row('Unsaved PR title') and vim.bo[ui.buf].modified, 'Reply/refresh lost source metadata edits')
pane(left, 2)
fresh(s, function() key('gR') end)
assert(f.resolved[201] and left.rows[2][1].resolved, 'Resolution did not refresh split markers')
-- A range draft uses code coordinates and preserves the saved review identity.
pane(right, 2); vim.cmd('normal! V'); api.nvim_win_set_cursor(0, { 3, 0 })
vim.fn.maparg('gcr', 'x', false, true).callback()
input = api.nvim_get_current_buf(); assert(vim.bo[input].filetype == 'markdown')
ui.body({ 'Split range draft' }); ui.send(input)
ui.wait(function() return not s.loading and not async.busy(f.root) end)
local draft = pending.comments[#pending.comments]
assert(draft.body == 'Split range draft' and draft.path == 'file name.txt' and draft.side == 'RIGHT'
  and draft.start_line == 2 and draft.line == 3 and pending.id == 88)
-- gA shares the native comment action menu; gr shares the native review menu.
pane(left, 2); key('gA'); ui.wait(function() return vim.b.git_action_menu_kind == 'pr-comment-actions' end); key('q')
pane(right, 2); key('gr'); ui.wait(function() return vim.b.git_action_menu_kind == 'pr-review' end); key('q')
-- File-level/outdated threads are explicitly available without fabricated anchors.
local select_thread = vim.ui.select
vim.ui.select = function(items, _, callback)
  local found
  for _, thread in ipairs(items) do if thread.id == 302 then found = thread end end
  assert(found, 'File comment missing from all-threads list'); callback(found)
end
pane(right, 1); key('gct'); input = api.nvim_get_current_buf()
assert(vim.bo[input].buftype == 'acwrite'); ui.close_draft(input); vim.ui.select = select_thread
-- Decorations belong only to captured windows, even when another window shares a blob.
pane(right, 1); vim.cmd('rightbelow vsplit'); local foreign = api.nvim_get_current_win()
assert(api.nvim_win_get_buf(foreign) == right.buf and not split._windows[foreign])
vim.cmd('diffoff')
local calls = #f.calls; key('gc')
assert(#f.calls == calls and api.nvim_get_current_win() == foreign, 'Foreign window acquired PR actions')
pane(right); key('q')
assert(not split._states[s.tab] and api.nvim_win_is_valid(foreign), 'q destroyed a foreign window')
assert(not api.nvim_win_is_valid(left.win) and not api.nvim_win_is_valid(right.win))
assert(api.nvim_get_current_win() == source and ui.row('Unsaved PR title'))
api.nvim_win_close(foreign, true)
-- Horizontal, added/deleted, renamed and no-comment files retain the explicit association.
s, left, right = opened('added.txt', 'dh')
assert(left.missing and next(left.rows) == nil)
assert(not split.target(left, 1, 1) and split.target(right, 1, 1).path == 'added.txt')
local lp, rp = api.nvim_win_get_position(left.win), api.nvim_win_get_position(right.win)
assert(lp[1] < rp[1] and lp[2] == rp[2], 'dh did not create horizontal panes')
pane(right); key('q')
s, left, right = opened('deleted.txt'); assert(right.missing and next(right.rows) == nil)
assert(split.target(left, 1, 1).side == 'LEFT' and not split.target(right, 1, 1)); pane(left); key('q')
s, left, right = opened('new.txt'); assert(api.nvim_buf_get_lines(left.buf, 0, -1, false)[1] == 'rename this')
assert(next(left.rows) == nil and next(right.rows) == nil); pane(right); key('q')
s, left, right = opened('separated.txt')
assert(split.target(right, 2, 3) and split.target(left, 28, 28))
assert(not split.target(right, 15, 15) and not split.target(right, 2, 28), 'Full-file lines outside a hunk were accepted')
pane(right, 15); calls = #f.calls; key('gcr')
assert(#f.calls == calls and api.nvim_get_current_buf() == right.buf)
key('q')
-- A base branch advance invalidates the association even if merge-base stays fixed.
s, left, right = opened('M file name.txt')
f.git({ 'checkout', '-q', 'main' }); f.git({ 'commit', '--allow-empty', '-qm', 'base advance' })
f.pr.baseRefOid = f.git({ 'rev-parse', 'HEAD' }); f.git({ 'checkout', '-q', 'topic' })
pane(right); fresh(s, function() key('R') end)
assert(s.stale and s.model.base == s.base, 'Base SHA change was ignored because merge-base stayed the same')
key('q'); f.pr.baseRefOid = f.base; f.git({ 'update-ref', 'refs/heads/main', f.base })
-- A push after opening cannot publish fresh anchors on old immutable panes.
s, left, right = opened('M file name.txt')
f.git({ 'commit', '--allow-empty', '-qm', 'advanced head' })
local advanced = f.git({ 'rev-parse', 'HEAD' })
f.git({ 'update-ref', 'refs/pull/7/head', advanced }); f.pr.headRefOid = advanced
pane(right); fresh(s, function() key('R') end)
assert(s.stale and next(left.rows) == nil and next(right.rows) == nil)
assert(vim.wo[right.win].winbar:find('reopen', 1, true))
calls = #f.calls; key('gcr'); assert(#f.calls == calls and api.nvim_get_current_buf() == right.buf)
assert(not split.target(right, 2, 2)); key('q')
f.pr.headRefOid = f.head; f.git({ 'update-ref', 'refs/pull/7/head', f.head })
local function refresh_source()
  local view = require('git.features.pr')
  local old = view.model(ui.buf)
  view.refresh(ui.buf, false, true)
  ui.wait(function() return view.model(ui.buf) ~= old and not async.busy(f.root) end)
end
-- Missing/failed GraphQL anchors keep readable histories but no guessed badges.
f.thread_status_error = true
refresh_source(); s, left, right = opened('M file name.txt')
assert(next(left.rows) == nil and not right.rows[2] and right.rows[3][1].pending)
pane(right); key('q'); f.thread_status_error = false; refresh_source()
-- Replacing a pane or changing its content cancels ownership and restores keys/options.
s, left, right = opened('M file name.txt')
pane(right); local unrelated = api.nvim_create_buf(true, false); api.nvim_win_set_buf(right.win, unrelated)
ui.wait(function() return split._states[s.tab] == nil end)
assert(vim.wo[right.win].winbar == '' and not split._windows[left.win])
assert(api.nvim_buf_call(left.buf, function() return vim.fn.maparg('gc', 'n', false, true).buffer end) ~= 1)
vim.cmd('tabclose')
s, left, right = opened('M file name.txt')
vim.bo[right.buf].modifiable, vim.bo[right.buf].readonly = true, false
api.nvim_buf_set_lines(right.buf, 1, 2, false, { 'changed outside PR' })
assert(not split._valid(right) and not split.target(right, 2, 2))
api.nvim_exec_autocmds('TextChanged', { buffer = right.buf })
ui.wait(function() return split._states[s.tab] == nil end); vim.cmd('tabclose')
-- Closing a split while asynchronous refresh runs rejects late callbacks.
s, left, right = opened('M file name.txt'); f.delay = 100
pane(right); key('R'); assert(s.loading); key('q')
ui.wait(function() return not async.busy(f.root) end)
assert(not split._states[s.tab] and not split._windows[left.win] and not split._windows[right.win])
api.nvim_buf_delete(ui.buf, { force = true }); vim.ui.select = original_select; f.cleanup()
print('PASS: native PR split comments/drafts, writes, geometry, immutable targets, ownership and cancellation')
