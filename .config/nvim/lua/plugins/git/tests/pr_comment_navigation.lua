local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local ui = require('helpers.pr_ui').new(f)
local view = require('git.features.pr')
local long = {}; for i = 1, 30 do long[i] = 'Reply line ' .. i end
f.comments[1][2].body = table.concat(long, '\n') .. '\n\n  \n'
ui.open()
local title = ui.row('PR title')
vim.api.nvim_buf_set_lines(ui.buf, title - 1, title, false, { 'Unsaved title' })
vim.api.nvim_buf_set_lines(ui.buf, title + 1, title + 1, false, { 'Unsaved description' })
local function press(keys) vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'xt', false) end
local function jump(keys, text)
  ui.source(); press(keys)
  ui.wait(function() return vim.api.nvim_get_current_line():find(text, 1, true) and vim.b[ui.buf].git_pr_preview ~= nil end)
end
local function preview()
  local buf = assert(vim.b[ui.buf].git_pr_preview)
  assert(not vim.bo[buf].modifiable and vim.bo[buf].readonly and vim.bo[buf].buftype == 'nofile')
  local win = assert(vim.fn.bufwinid(buf))
  assert(win ~= -1)
  assert(vim.api.nvim_win_get_cursor(win)[1] == vim.api.nvim_buf_line_count(buf), 'Preview did not start at the latest comment')
  assert(not vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1]:match('^%s*$'), 'Preview ends in a blank padding row')
  local title = table.concat(vim.tbl_map(function(chunk) return chunk[1] end, vim.api.nvim_win_get_config(win).title))
  assert(title:find('gc reply', 1, true) and title:find('gk focus', 1, true) and title:find(']C/[C move', 1, true))
  local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
  assert(not content:find('gc replies · gk focuses', 1, true) and not content:find('────────────────', 1, true),
    'Preview still displays its instructions / separator inside the conversation')
  return buf, win
end
vim.api.nvim_win_set_cursor(0, { 1, 0 })
jump(']C', '-two')
assert(vim.api.nvim_get_current_buf() == ui.buf, 'Automatic preview stole focus')
local buf = preview()
assert(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'):find('Removed line', 1, true))
local unread = require('git.features.pr_read_state').unread(view.model(ui.buf).ctx, f.viewer, view.model(ui.buf).threads)
assert(not unread[201] and unread[101], 'Navigation marked an unseen conversation read')
jump(']C', '+TWO')
local pbuf, pwin = preview()
assert(vim.api.nvim_buf_get_lines(pbuf, -2, -1, false)[1] == 'Reply line 30')
assert(vim.api.nvim_win_call(pwin, function() return vim.fn.line('w0') end) > 1, 'Long conversation was not scrolled down')
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  assert(not vim.api.nvim_buf_get_name(b):find('git-pr-compose://', 1, true), 'Navigation opened an input buffer')
end
press('gk'); assert(vim.api.nvim_get_current_buf() == pbuf, 'Repeated gk did not focus the preview')
press('gc')
local input = vim.api.nvim_get_current_buf()
assert(vim.bo[input].buftype == 'acwrite' and not vim.api.nvim_buf_is_valid(pbuf))
assert(vim.api.nvim_win_get_height(0) == 5 and vim.api.nvim_win_get_width(0) <= 80, 'Input is not compact')
assert(vim.api.nvim_win_get_cursor(0)[1] == 1)
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(input, 0, -1, false), { '' }), 'Read-only labels leaked into the draft')
local context = assert(vim.b[input].git_pr_context)
assert(vim.bo[context].readonly and not vim.bo[context].modifiable)
assert(not pcall(vim.api.nvim_buf_set_lines, context, 0, 1, false, { 'tampered' }))
local target = false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(context, vim.api.nvim_create_namespace('git_pr_history'), 0, -1, { details = true })) do
  target = target or mark[4].hl_group == 'GitPrCommentContext'
end
assert(target, 'Context labels lack colors')
local title = table.concat(vim.tbl_map(function(chunk) return chunk[1] end, vim.api.nvim_win_get_config(0).title))
assert(title:find('<C-s>/:w send', 1, true) and title:find('Tab', 1, true), 'Input title lost operation shortcuts')
assert(not table.concat(vim.api.nvim_buf_get_lines(context, 0, -1, false), '\n'):find('<C-s>', 1, true), 'Instructions remain inside the conversation')
ui.body(long); assert(vim.api.nvim_win_get_height(0) == 5, 'Long input expanded the textarea')
ui.close_draft(input); assert(not vim.api.nvim_buf_is_valid(context))
jump(']C', 'new.txt'); preview()
jump('[C', '+TWO'); preview()
jump('[C', '-two'); preview()
ui.source(); local first = vim.fn.line('.'); press('[C'); assert(vim.fn.line('.') == first, 'Previous comment wrapped')
ui.key('<', ui.row('Changes ('))
vim.api.nvim_win_set_cursor(0, { 1, 0 })
jump('2]C', '+TWO'); preview()
assert(ui.row('Unsaved title') and ui.row('Unsaved description') and vim.bo[ui.buf].modified)
assert(f.pr.title == 'PR title', 'Comment navigation submitted metadata')
jump(']C', 'new.txt')
local last = vim.fn.line('.'); press(']C'); assert(vim.fn.line('.') == last, 'Next comment wrapped')
-- A normal gk opens a cursor-relative conversation without expanding a file.
ui.key('<', ui.row('M file name.txt'))
ui.source(); vim.api.nvim_win_set_cursor(0, { ui.row('M file name.txt'), 0 }); press('gk')
pbuf, pwin = preview()
assert(vim.api.nvim_win_get_config(pwin).relative == 'win', 'Preview is not anchored near the cursor')
assert(not pcall(ui.row, '+TWO'), 'Manual preview unexpectedly expanded the file')
press('j'); vim.api.nvim_exec_autocmds('CursorMoved', { buffer = ui.buf })
assert(not vim.api.nvim_buf_is_valid(pbuf), 'Moving away left a stale preview')
vim.api.nvim_buf_delete(ui.buf, { force = true })
-- A delayed comment expansion must not show a preview in a replacement buffer.
ui.open()
local original, requested = vim.system, false
vim.system = function(argv, opts, callback)
  if callback and argv[1] == 'git' and vim.tbl_contains(argv, 'diff') then
    requested = true
    return original(argv, opts, function(result) vim.defer_fn(function() callback(result) end, 50) end)
  end
  return original(argv, opts, callback)
end
vim.api.nvim_win_set_cursor(0, { 1, 0 }); press(']C'); ui.wait(function() return requested end)
local scratch = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, scratch)
ui.wait(function()
  for _, entry in ipairs(view.model(ui.buf).entries) do if entry.path == 'file name.txt' then return entry.patch ~= nil end end
end)
assert(vim.api.nvim_get_current_buf() == scratch and vim.b[ui.buf].git_pr_preview == nil)
vim.system = original
vim.api.nvim_buf_delete(ui.buf, { force = true }); f.cleanup()
print('PASS: counted bidirectional comment jumps, lazy expansion, latest cursor preview, gk focus, gc reply, compact immutable context, draft preservation and delayed-view guards')
