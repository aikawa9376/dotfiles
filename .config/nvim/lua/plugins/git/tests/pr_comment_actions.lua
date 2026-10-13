local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local ui = require('helpers.pr_ui').new(f)
local api = require('git.features.pr_comment_actions')
local ctx = { root = f.root, host = 'ghe.example.test', repo = 'org/repo', number = 7, url = f.pr.url }
local item = { id = 77, kind = 'comment', body = 'Published body', user = { login = f.viewer },
  updated_at = '2026-10-13T00:00:00Z', created_at = '2026-10-12T00:00:00Z', reactions = { ['+1'] = 1 } }
f.discussion = { item }
local reactions = { { id = 9, content = '+1', user = { login = 'other' } } }
local writes = {}
local inline = f.comments[1][1]
inline.user.login = f.viewer
local review = { id = 500, kind = 'review', user = { login = f.viewer }, body = 'Review summary' }
local base = 'repos/org/repo/issues/comments/77'
f.api_response = function(path, method, payload)
  if path == 'repos/org/repo/pulls/comments/101' then
    if method == 'GET' then return { data = vim.deepcopy(inline) } end
    writes[#writes + 1] = { path, method, payload }
    if method == 'PATCH' then inline.body = payload.body end
    return { data = inline }
  elseif path == 'repos/org/repo/pulls/7/reviews/500' then
    if method == 'PUT' then review.body = payload.body; writes[#writes + 1] = { path, method, payload } end
    return { data = review }
  end
  if path == base .. '/reactions' then
    if method == 'GET' then return { data = { vim.deepcopy(reactions) } } end
    writes[#writes + 1] = { path, method, payload }
    reactions[#reactions + 1] = { id = 10, content = payload.content, user = { login = f.viewer } }
    item.reactions[payload.content] = (item.reactions[payload.content] or 0) + 1
    return { data = reactions[#reactions] }
  elseif path == base .. '/reactions/10' then
    writes[#writes + 1] = { path, method }
    table.remove(reactions); item.reactions['+1'] = item.reactions['+1'] - 1
    return { raw = '' }
  elseif path == base then
    if method == 'GET' then return { data = vim.deepcopy(item) } end
    writes[#writes + 1] = { path, method, payload }
    if method == 'PATCH' then item.body = payload.body; return { data = item } end
    if method == 'DELETE' then f.discussion = {}; return { raw = '' } end
  end
end
local function run(fn)
  local done, value, success
  require('git.features.async').run(f.root, fn, function(ok, result) done, success, value = true, ok, result end)
  assert(vim.wait(5000, function() return done end, 10)); return success, value
end
ui.open(); require('git.features.pr').show_conversation(ui.buf)
assert(ui.row('👍 1'))
local title = ui.row('PR title'); vim.api.nvim_buf_set_lines(ui.buf, title - 1, title, false, { 'Unsaved title' })
ui.key('gA', ui.row('Published body'))
ui.wait(function() return vim.b.git_action_menu_kind == 'pr-comment-actions' end)
local function key(value)
  local map = vim.fn.maparg(value, 'n', false, true); assert(map.callback, value); map.callback()
end
key('1')
ui.wait(function() return #reactions == 2 and not require('git.features.async').busy(f.root) end)
assert(writes[#writes][2] == 'POST' and writes[#writes][3].content == '+1')
ui.wait(function() return pcall(ui.row, '👍 2') end)
assert(ui.row('Unsaved title') and vim.bo[ui.buf].modified)
assert(run(function() return api.toggle_reaction(ctx, item, '+1') end))
assert(#reactions == 1 and reactions[1].user.login == 'other' and writes[#writes][1] == base .. '/reactions/10')
assert(not run(function() return api.toggle_reaction(ctx, item, 'invalid') end))
-- A changed author/body cannot be mutated by an old edit draft.
local original = vim.deepcopy(item); item.body = 'Someone changed it'
local before = #writes
local ok, err = run(function() return api.edit(ctx, original, 'Lost edit') end)
assert(not ok and err:find('Comment changed') and #writes == before)
item.body = original.body; item.user.login = 'other'
ok, err = run(function() return api.remove(ctx, original) end)
assert(not ok and err:find('Only your own') and #writes == before)
item.user.login = f.viewer
local view = require('git.features.pr')
local old = view.model(ui.buf); view.refresh(ui.buf, false, true)
ui.wait(function() return view.model(ui.buf) ~= old end); view.show_conversation(ui.buf)
ui.key('gA', ui.row('Published body')); ui.wait(function() return vim.b.git_action_menu_kind == 'pr-comment-actions' end)
key('e'); local input = vim.api.nvim_get_current_buf()
assert(vim.bo.buftype == 'acwrite' and vim.api.nvim_get_current_line() == 'Published body')
ui.body({ 'Edited published comment' }); ui.send(input)
assert(item.body == 'Edited published comment' and writes[#writes][2] == 'PATCH' and ui.row('Unsaved title'))
-- Inline comments use the distinct endpoint, not issues/comments.
assert(api.endpoint(ctx, { id = 101 }) == 'repos/org/repo/pulls/comments/101')
ui.key('gk', ui.row('M file name.txt')); ui.key('gk')
assert(vim.api.nvim_win_get_config(0).relative ~= '', 'Second gk must focus the popup')
local preview = vim.api.nvim_get_current_buf()
for row, line in ipairs(vim.api.nvim_buf_get_lines(preview, 0, -1, false)) do
  if line == 'Please explain' then vim.api.nvim_win_set_cursor(0, { row, 0 }); break end
end
key('gA'); ui.wait(function() return vim.b.git_action_menu_kind == 'pr-comment-actions' end)
assert(not vim.api.nvim_buf_is_valid(preview), 'Popup action must return to the PR source before opening a panel')
key('e'); input = vim.api.nvim_get_current_buf()
local history = vim.b[input].git_pr_context
local history_win = vim.fn.bufwinid(history); vim.api.nvim_set_current_win(history_win)
vim.api.nvim_win_set_cursor(history_win, { vim.api.nvim_buf_line_count(history), 0 }); key('gA')
ui.wait(function() return vim.b.git_action_menu_kind == 'pr-comment-actions' end)
assert(vim.api.nvim_win_get_config(0).relative ~= '', 'History actions need a float, not a split inside a float')
key('q'); vim.api.nvim_set_current_win(vim.fn.bufwinid(input)); ui.body({ 'Edited inline comment' }); ui.send(input)
assert(inline.body == 'Edited inline comment' and writes[#writes][1] == 'repos/org/repo/pulls/comments/101')
assert(run(function() return api.edit(ctx, review, 'Edited review summary') end))
assert(review.body == 'Edited review summary' and writes[#writes][2] == 'PUT')
assert(not run(function() return api.remove(ctx, review) end), 'Submitted review deletion is unavailable')
local removed = vim.deepcopy(item)
assert(run(function() return api.remove(ctx, removed) end))
assert(writes[#writes][2] == 'DELETE' and #f.discussion == 0)
vim.api.nvim_buf_delete(ui.buf, { force = true }); f.cleanup()
print('PASS: published comment UI, reaction counts/own toggle, stale/ownership guards, PATCH/DELETE routes and draft preservation')
