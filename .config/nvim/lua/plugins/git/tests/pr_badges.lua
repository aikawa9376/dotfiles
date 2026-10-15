local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local ui = require('helpers.pr_ui').new(f)
local view, reads = require('git.features.pr'), require('git.features.pr_read_state')
local function refresh()
  local previous = view.model(ui.buf)
  view.refresh(ui.buf, false, true)
  ui.wait(function() return view.model(ui.buf) ~= previous and not require('git.features.async').busy(f.root) end)
end
local date = '2026-10-15T01:00:00Z'
local function comment(id, parent, author, stale)
  return { id = id, in_reply_to_id = parent, body = 'Shared body', user = { login = author or 'reviewer' },
    path = 'file name.txt', side = 'RIGHT', line = stale and vim.NIL or 2,
    created_at = date, updated_at = date }
end
f.comments = { { comment(101), comment(102, 101, f.viewer) },
  { comment(201, nil, nil, true), comment(202, 201, nil, true), comment(203, 201, f.viewer, true) } }
f.thread_anchors = { [201] = { isOutdated = true } }
f.resolved = { [101] = true, [201] = true }
-- Same numeric ID and fingerprint in all three API namespaces must stay
-- independent, including after reloading the receipt module.
f.discussion = { { id = 101, body = 'Shared body', user = { login = 'reviewer' }, created_at = date, updated_at = date },
  { id = 102, body = 'My own PR comment', user = { login = f.viewer }, created_at = date, updated_at = date } }
f.reviews = { { id = 101, body = 'Shared body', user = { login = 'reviewer' }, state = 'APPROVED', submitted_at = date } }
ui.open()
local function chunks(row)
  local result = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(ui.buf, vim.api.nvim_create_namespace('git_pr_status'),
    { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    for _, chunk in ipairs(mark[4].virt_text or {}) do result[chunk[1]] = true end
  end
  return result
end
local function file(count, new)
  local badge = chunks(ui.row('M file name.txt'))
  assert(badge[' 💬 ' .. count], 'Wrong stable file comment count: ' .. vim.inspect(badge))
  assert((badge[' 🆕'] == true) == new)
end
local function conversation(new)
  assert((chunks(ui.row('Conversation ('))[' 🆕'] == true) == new, 'Wrong PR Conversation unread state')
end
file('2/5', true); conversation(true)
local model = view.model(ui.buf)
assert(model.threads[1].outdated == false and model.threads[2].outdated == true)
ui.key('o', ui.row('M file name.txt')); ui.wait(function() return pcall(ui.row, '+TWO') end)
file('2/5', true)
assert(chunks(ui.row('+TWO'))[' 💬 2'] and chunks(ui.row('+TWO'))[' 🆕'])
assert(not chunks(ui.row('-two'))[' 💬 3'], 'An outdated thread was projected onto today\'s diff')
local calls = #f.calls
ui.key('gc', ui.row('+TWO')); local input = vim.api.nvim_get_current_buf(); ui.close_draft(input)
assert(#f.calls == calls and chunks(ui.row('+TWO'))[' 💬 2'] and not chunks(ui.row('+TWO'))[' 🆕'])
file('2/5', true); conversation(true)
ui.key('gk', ui.row('M file name.txt'))
file('2/5', false); conversation(true)
require('git.features.pr_comment_preview').close(ui.buf)
local entries = model.conversation.entries
local issue, review
for _, entry in ipairs(entries) do
  if entry.kind == 'comment' and entry.id == 101 then issue = entry end
  if entry.kind == 'review' then review = entry end
end
reads.mark(model.ctx, f.viewer, { issue })
package.loaded['git.features.pr_read_state'] = nil
reads = require('git.features.pr_read_state')
assert(not reads.unread_entries(model.ctx, f.viewer, entries)[issue.key])
assert(reads.unread_entries(model.ctx, f.viewer, entries)[review.key], 'Issue receipt hid a same-ID review')
assert(not reads.unread(model.ctx, f.viewer, model.threads)[101])
conversation(true)
local title = ui.row('PR title')
vim.api.nvim_buf_set_lines(ui.buf, title - 1, title, false, { 'Unsaved title' })
vim.api.nvim_buf_set_lines(ui.buf, title + 1, title + 1, false, { 'New description line' })
calls = #f.calls
ui.key('>', ui.row('Conversation (')); conversation(false)
assert(#f.calls == calls and vim.bo[ui.buf].modified and ui.row('Unsaved title'))
ui.key('<', ui.row('Conversation (')); conversation(false)
file('2/5', false)
-- Refreshing a collapsed Conversation shows new comments; opening its composer
-- reads only that displayed history, without touching file counters or drafts.
f.discussion[#f.discussion + 1] = { id = 103, body = 'New PR comment', user = { login = 'reviewer' }, created_at = date }
refresh(); conversation(true); file('2/5', false)
calls = #f.calls
ui.key('gcp', 1); input = vim.api.nvim_get_current_buf()
assert(vim.b[input].git_pr_history and #f.calls == calls)
conversation(false); file('2/5', false); ui.close_draft(input)
assert(vim.bo[ui.buf].modified and ui.row('Unsaved title') and ui.row('New description line'))
f.discussion[#f.discussion + 1] = { id = 104, body = 'Only my own new comment', user = { login = f.viewer }, created_at = date }
refresh(); conversation(false)
f.discussion[1].body = 'Edited PR comment'
refresh(); conversation(true)
model = view.model(ui.buf)
reads.mark(model.ctx, f.viewer, model.conversation.entries); conversation(false)
f.reviews[1].state = 'CHANGES_REQUESTED'
refresh(); conversation(true)
model = view.model(ui.buf)
reads.mark(model.ctx, f.viewer, model.conversation.entries); conversation(false)
f.timeline_pages = { { { __typename = 'ClosedEvent', id = 'CLOSED1', actor = { login = 'reviewer' }, createdAt = date } } }
refresh(); conversation(true)
-- New replies on obsolete threads affect the total and file indicator, while
-- a read current thread keeps its fixed count and no new icon.
f.comments[2][#f.comments[2] + 1] = comment(204, 201, nil, true)
refresh(); file('2/6', true)
assert(chunks(ui.row('+TWO'))[' 💬 2'] and not chunks(ui.row('+TWO'))[' 🆕'])
ui.key('<', ui.row('M file name.txt')); file('2/6', true)
-- Unknown outdated metadata cannot honestly provide a current/total ratio.
f.thread_status_error = true; refresh(); file('6', true)
-- Viewer fallback still repaints Conversation receipts if review reads fail.
f.review_read_error = true; refresh(); conversation(true)
model = view.model(ui.buf)
assert(not model.review and model.viewed.viewer == f.viewer)
reads.mark(model.ctx, f.viewer, model.conversation.entries); conversation(false)
assert(vim.bo[ui.buf].modified and ui.row('Unsaved title'))
local all = {}
for _, thread in ipairs(model.threads) do vim.list_extend(all, thread.comments) end
reads.mark(model.ctx, f.viewer, all)
f.review_read_error, f.thread_status_error = nil, nil
vim.api.nvim_buf_delete(ui.buf, { force = true })
ui.open(); file('2/6', false); conversation(false)
vim.api.nvim_buf_delete(ui.buf, { force = true }); f.cleanup()
print('PASS: stable current/total and per-position comment counts, independent new icons, Conversation read paths, same-ID receipt isolation, refresh/edits/own comments, metadata fallback and drafts')
