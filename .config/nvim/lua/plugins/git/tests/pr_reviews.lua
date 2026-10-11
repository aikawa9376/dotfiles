local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local ui = require('helpers.pr_ui').new(f)
local view = require('git.features.pr')
-- Another user's pending review must never be adopted, submitted or discarded.
f.reviews = { { id = 77, node_id = 'OTHER', commit_id = f.head, state = 'PENDING', body = '',
  comments = {}, user = { login = 'someone-else' } } }
ui.open()
assert(not pcall(ui.row, 'Your review:'), 'Empty viewer review should be hidden, including when another user has a pending review')
ui.menu('gr'); ui.key('s')
ui.wait(function() return vim.bo.filetype == 'gitactionmenu' and view.model(ui.buf).review.pending ~= nil end)
ui.key('q'); ui.loaded()
local pending = f.reviews[2]
assert(pending and pending.id ~= 77 and pending.state == 'PENDING')
assert(ui.row('Your review: PENDING') and ui.row('0 comments'), 'An empty pending review should remain visible')
local id = pending.id
local function starts()
  local count = 0
  for _, call in ipairs(f.calls) do if vim.tbl_contains(call.argv, 'repos/org/repo/pulls/7/reviews')
    and vim.tbl_contains(call.argv, 'POST') then count = count + 1 end end
  return count
end
local count = starts()
ui.menu('gr'); ui.key('s')
ui.wait(function() return vim.bo.filetype == 'gitactionmenu' end); ui.key('q'); ui.loaded()
assert(starts() == count and f.reviews[2].id == id, 'Resume created another review')
ui.key('>', ui.row('Changes (')); ui.wait(function() return pcall(ui.row, '+TWO') end)
ui.key('gC', ui.row('+TWO')); ui.key('r')
local buf = ui.body({ 'Private draft `literal` $(not executed)', 'More context' })
f.graphql_error = true
ui.failed(buf, 'GraphQL rejected thread')
assert(vim.bo[buf].modified and #pending.comments == 0)
f.graphql_error = false; ui.send(buf)
assert(#pending.comments == 1 and pending.comments[1].line == 2 and pending.comments[1].side == 'RIGHT')
assert(starts() == count)
ui.wait(function() return #view.model(ui.buf).review.pending.comments == 1 end)
assert(ui.row('Your review: PENDING'))
local marked = false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(ui.buf, vim.api.nvim_create_namespace('git_pr_status'),
  { ui.row('+TWO') - 1, 0 }, { ui.row('+TWO') - 1, -1 }, { details = true })) do
  for _, chunk in ipairs(mark[4].virt_text or {}) do if chunk[1]:find('[pending]', 1, true) then marked = true end end
end
assert(marked, 'Pending draft comment is not distinguished on the diff')
-- gc on a pending thread edits its draft rather than publicly replying to it.
vim.ui.select = function(items, _, callback)
  for _, item in ipairs(items) do if item.pending then callback(item); return end end
  callback(items[1])
end
ui.key('gc', ui.row('+TWO'))
assert(vim.bo.filetype == 'markdown')
buf = ui.body({ 'Edited private draft' }); ui.send(buf)
assert(pending.comments[1].body == 'Edited private draft' and pending.state == 'PENDING')
-- File-level review threads use GraphQL FILE scope without line coordinates.
ui.key('gC', ui.row('M file name.txt')); ui.key('r')
buf = ui.body({ 'File-level private draft' }); ui.send(buf)
assert(#pending.comments == 2 and pending.comments[2].line == vim.NIL)
local file_input
for _, call in ipairs(f.calls) do if vim.tbl_contains(call.argv, 'graphql') then
  local input = vim.json.decode(call.opts.stdin).variables.input
  if input then
    assert(input.pullRequestReviewId == pending.node_id)
    if input.body == 'File-level private draft' then file_input = input end
  end
end end
assert(file_input.subjectType == 'FILE' and file_input.line == nil)
-- Pending range comments use GraphQL's startLine/startSide field names.
ui.source(); vim.api.nvim_win_set_cursor(0, { ui.row('+TWO'), 0 }); vim.cmd('normal! Vj')
vim.fn.maparg('gC', 'x', false, true).callback(); ui.key('r')
buf = ui.body({ 'Private range draft' }); ui.send(buf)
local range_input
for _, call in ipairs(f.calls) do if vim.tbl_contains(call.argv, 'graphql') then
  local input = vim.json.decode(call.opts.stdin).variables.input
  if input and input.body == 'Private range draft' then range_input = input end
end end
assert(range_input.startLine == 2 and range_input.line == 3 and range_input.startSide == 'RIGHT')
local selector, confirm = vim.ui.select, vim.fn.confirm
vim.ui.select = function(items, _, callback)
  for _, item in ipairs(items) do if item.body == 'File-level private draft' then callback(item); return end end
  error('Missing deletable draft')
end
ui.menu('gr'); ui.key('c'); buf = vim.api.nvim_get_current_buf()
vim.fn.confirm = function() return 2 end
ui.key('gX'); assert(vim.api.nvim_buf_is_valid(buf) and #pending.comments == 3)
vim.fn.confirm = function() return 1 end
ui.key('gX'); ui.wait(function() return not vim.api.nvim_buf_is_valid(buf) end); ui.loaded()
assert(#pending.comments == 2 and f.reviews[1].id == 77)
vim.ui.select, vim.fn.confirm = selector, confirm
-- A summary can be saved without submitting, and survives reopening PR status.
ui.menu('gr'); ui.key('b'); buf = ui.body({ 'Summary draft' })
pending.body = 'Summary changed in Octo'
ui.failed(buf, 'summary changed on GitHub')
pending.body = ''; ui.send(buf)
assert(pending.body == 'Summary draft' and not f.last_event)
vim.api.nvim_buf_delete(ui.buf, { force = true }); ui.open()
assert(view.model(ui.buf).review.pending.id == id and #view.model(ui.buf).review.pending.comments == 2)
ui.menu('gr'); ui.key('c'); buf = ui.body({ 'Locally changed draft' })
pending.comments[1].body = 'Concurrently edited draft'
ui.failed(buf, 'comment changed on GitHub')
pending.comments[1].body = 'Edited private draft'; ui.close_draft(buf)
-- Immediate diff posting cannot accidentally publish an existing pending review.
ui.key('gC', ui.row('M file name.txt')); ui.key('c'); buf = ui.body({ 'Immediate while pending' })
ui.failed(buf, 'A pending review exists'); ui.close_draft(buf)
-- External draft edits during the submit composer are detected before sending.
ui.menu('gr'); ui.key('a'); buf = ui.body({ 'Approval summary' })
pending.comments[1].body = 'Edited in Octo'
ui.failed(buf, 'drafts changed on GitHub')
assert(pending.state == 'PENDING' and vim.bo[buf].modified)
pending.comments[1].body = 'Edited private draft'
f.pr.headRefOid = f.base
ui.failed(buf, 'PR head changed')
f.pr.headRefOid = f.head
f.comment_error = true
ui.failed(buf, 'server rejected write')
f.comment_error = false; ui.send(buf)
assert(f.last_event == 'APPROVE' and pending.state == 'APPROVED' and not view.model(ui.buf).review.pending)
assert(not pcall(ui.row, 'Your review:'), 'Submitted review should hide the pending-review status')
assert(f.reviews[1].id == 77 and f.reviews[1].state == 'PENDING')
-- No pending review is required for standalone approval/change-request reviews.
ui.menu('gr'); ui.key('r'); buf = vim.api.nvim_get_current_buf()
ui.failed(buf, 'needs a review summary')
buf = ui.body({ 'Please fix this' }); ui.send(buf)
assert(f.last_event == 'REQUEST_CHANGES')
ui.menu('gr'); ui.key('m'); buf = ui.body({ 'General review feedback' }); ui.send(buf)
assert(f.last_event == 'COMMENT')
-- Old-head reviews continue normally without automatic copying or deletion.
local old = { id = 900, node_id = 'OLD_REVIEW', state = 'PENDING', commit_id = f.base, body = 'Old summary',
  user = { login = f.viewer }, comments = { { id = 901, body = 'Retained draft', path = 'file name.txt',
    line = 2, side = 'RIGHT', user = { login = f.viewer } } } }
f.reviews[#f.reviews + 1] = old
ui.refresh(); assert(ui.row('review commit ' .. f.base:sub(1, 7)))
assert(not table.concat(vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false), '\n'):find('OUTDATED', 1, true))
count = starts()
ui.menu('gr'); ui.key('s')
ui.wait(function() return vim.bo.filetype == 'gitactionmenu' end); ui.key('q'); ui.loaded()
assert(starts() == count and old.id == 900 and old.commit_id == f.base)
ui.key('>', ui.row('Changes (')); ui.wait(function() return pcall(ui.row, '+TWO') end)
ui.key('gC', ui.row('+TWO')); ui.key('r'); buf = ui.body({ 'Added after push' }); ui.send(buf)
assert(old.id == 900 and #old.comments == 2 and old.comments[1].body == 'Retained draft')
ui.menu('gr'); ui.key('a'); buf = ui.body({ 'Continuing this review' }); ui.send(buf)
assert(old.id == 900 and old.state == 'APPROVED' and old.commit_id == f.base and starts() == count)
old.state = 'PENDING'; ui.refresh()
-- Submitted/replaced pending identities never get silently recreated on save.
ui.menu('gr'); ui.key('a'); buf = ui.body({ 'Keep this local draft' })
old.state = 'COMMENTED'
ui.failed(buf, 'Pending review changed'); ui.close_draft(buf)
old.state = 'PENDING'
confirm = vim.fn.confirm
vim.fn.confirm = function() return 2 end
ui.menu('gr'); ui.key('x'); assert(old.state == 'PENDING')
-- A review changed after confirmation is retained until it is inspected again.
vim.fn.confirm = function() old.comments[1].body = 'Edited during confirmation'; return 1 end
ui.menu('gr'); ui.key('x')
ui.wait(function() return f.notifications[#f.notifications]:find('before discarding', 1, true) ~= nil end)
assert(old.state == 'PENDING')
vim.fn.confirm = function() return 1 end
ui.menu('gr'); ui.key('x')
ui.wait(function() return not view.model(ui.buf).review.pending end)
vim.fn.confirm = confirm
assert(not pcall(ui.row, 'Your review:'), 'Discarded review should hide the pending-review status')
assert(#f.reviews > 0 and f.reviews[1].id == 77)
-- An async menu request cannot steal focus after its source buffer changes.
ui.source()
local win, model = vim.api.nvim_get_current_win(), view.model(ui.buf)
f.delay = 30
local task = require('git.features.pr_review').menu(model)
local scratch = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(win, scratch)
ui.wait(function() return task.completed end)
assert(vim.api.nvim_get_current_buf() == scratch and vim.bo.filetype ~= 'gitactionmenu')
vim.api.nvim_win_set_buf(win, ui.buf); f.delay = 2
-- Viewer-state read failure must not hide PR metadata/diffs.
f.review_read_error = true; ui.refresh()
assert(view.model(ui.buf).review_error and #view.model(ui.buf).entries == 4 and ui.row('Your review: unavailable'))
vim.api.nvim_buf_delete(ui.buf, { force = true }); f.cleanup()
print('PASS: native start/resume, viewer identity, private draft edits, summaries/reopen, approve/request/comment submission, external edits, old heads and explicit discard')
