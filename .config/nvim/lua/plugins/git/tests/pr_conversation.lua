local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local ui = require('helpers.pr_ui').new(f)
local view, history = require('git.features.pr'), require('git.features.pr_conversation')
local function comment(id, body, date, author)
  return { id = id, body = body, created_at = date, updated_at = date, user = { login = author or 'reviewer' },
    html_url = f.pr.url .. '#issuecomment-' .. id }
end
f.discussion_pages = {
  { comment(1, 'PR-wide question\n\nAdditional context', '2026-10-10T01:00:00Z') },
  { comment(2, 'My overall reply', '2026-10-10T03:00:00Z', f.viewer), comment(1, 'PR-wide question\n\nAdditional context', '2026-10-10T01:00:00Z') },
}
f.reviews = {
  { id = 1, state = 'APPROVED', body = 'Looks good overall', submitted_at = '2026-10-10T02:00:00Z', user = { login = 'approver' } },
  { id = 3, state = 'COMMENTED', body = '', submitted_at = '2026-10-10T04:00:00Z', user = { login = 'reviewer' } },
  { id = 4, state = 'PENDING', body = 'Private unsubmitted summary', comments = {}, commit_id = f.head, user = { login = f.viewer } },
  { id = 5, state = 'CHANGES_REQUESTED', body = '', submitted_at = '2026-10-10T05:00:00Z', user = { login = 'other' } },
}
local function text(buf) return table.concat(vim.api.nvim_buf_get_lines(buf or ui.buf, 0, -1, false), '\n') end
local function absent(value) assert(not text():find(value, 1, true), 'Unexpected conversation content: ' .. value) end
local function item_row(key)
  for row = 1, vim.api.nvim_buf_line_count(ui.buf) do
    local entry = view.conversation_at(ui.buf, row)
    if entry and entry.key == key then return row end
  end
  error('Missing conversation entry: ' .. key)
end
ui.open(); assert(ui.row('Conversation (4)'))
absent('PR-wide question'); absent('Private unsubmitted summary')
local model = view.model(ui.buf)
assert(#model.threads == 3 and #model.conversation.entries == 4, 'Inline comments were duplicated in Conversation')
assert(vim.deep_equal(vim.tbl_map(function(entry) return entry.key end, model.conversation.entries),
  { 'comment:1', 'review:1', 'comment:2', 'review:5' }), 'Pagination/type identities or chronological ordering failed')
local title = ui.row('PR title')
vim.api.nvim_buf_set_lines(ui.buf, title - 1, title, false, { 'Unsaved Conversation title' })
vim.api.nvim_buf_set_lines(ui.buf, title + 1, title + 1, false, { 'Body grew during review' })
local requests = #f.calls
ui.key('<CR>', ui.row('Conversation ('))
assert(ui.row('PR-wide question') and ui.row('Additional context') and ui.row('Looks good overall') and ui.row('My overall reply'))
assert(item_row('comment:1') < item_row('review:1') and item_row('review:1') < item_row('comment:2'))
assert(ui.row('Review CHANGES_REQUESTED') and not pcall(ui.row, 'Review COMMENTED'))
assert(#f.calls == requests and vim.bo[ui.buf].modified and ui.row('Body grew during review'))
assert(view.entry_at(ui.buf, ui.row('PR-wide question')) == nil and view.commit_at(ui.buf, ui.row('PR-wide question')) == nil)
local own, approved = false, false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(ui.buf, vim.api.nvim_create_namespace('git_pr_status'), 0, -1, { details = true })) do
  local line = vim.api.nvim_buf_get_lines(ui.buf, mark[2], mark[2] + 1, false)[1]
  own = own or (line == 'My overall reply' and mark[4].hl_group == 'GitPrCommentSelf')
  approved = approved or (line:find('Review APPROVED', 1, true) and mark[4].hl_group == 'GitPrPositive')
end
assert(own and approved, 'Conversation lost author/review-state colors')
local browser, open = nil, vim.ui.open; vim.ui.open = function(url) browser = url end
ui.key('gx', ui.row('Looks good overall')); assert(browser == f.pr.url .. '#pullrequestreview-1')
ui.key('gx', ui.row('PR-wide question')); assert(browser == f.pr.url .. '#issuecomment-1')
vim.ui.open = open
ui.key('gR', ui.row('PR-wide question')); assert(not f.resolved and #f.calls == requests, 'PR comment resolved an unrelated file thread')
-- Header/body rows share fold behavior; text is immutable and not parsed as
-- file/commit/section targets. Header/CI folds remain independent.
ui.key('o', ui.row('Looks good overall')); absent('Looks good overall')
ui.key('>', ui.row('Conversation (')); assert(ui.row('Looks good overall'))
ui.key('<', 1); assert(ui.row('Looks good overall'))
ui.key('>', 1); assert(ui.row('Looks good overall'))
view.refresh(ui.buf, false, true); ui.loaded()
assert(ui.row('Looks good overall') and ui.row('Unsaved Conversation title') and vim.bo[ui.buf].modified)
-- gc/Enter in Conversation writes one PR issue comment with immutable history,
-- while file gc continues to use review threads. No draft/inline duplication.
ui.key('gc', ui.row('Additional context'))
local input = vim.api.nvim_get_current_buf()
assert(vim.bo[input].buftype == 'acwrite' and vim.b[input].git_pr_history)
local context = vim.b[input].git_pr_context
assert(text(context):find('PR-wide question', 1, true) and text(context):find('Review APPROVED', 1, true))
assert(not text(context):find('Please explain', 1, true) and not text(context):find('Private unsubmitted summary', 1, true))
ui.body({ 'New PR-wide comment' }); ui.send(input)
assert(#f.discussion == 1 and f.discussion[1].body == 'New PR-wide comment' and #view.model(ui.buf).threads == 3)
-- Current fixture pages simulate the remote list catching up with a new post.
f.discussion_pages[2][#f.discussion_pages[2] + 1] = f.discussion[1]
view.refresh(ui.buf, false, true); ui.loaded()
assert(ui.row('New PR-wide comment') and ui.row('Unsaved Conversation title') and ui.row('Conversation (5)'))
ui.key('gcp', 1); input = vim.api.nvim_get_current_buf()
assert(vim.b[input].git_pr_history and text(vim.b[input].git_pr_context):find('New PR-wide comment', 1, true)); ui.close_draft(input)
ui.key('<', ui.row('Conversation (')); absent('PR-wide question')
ui.menu('N'); ui.key('p')
assert(vim.api.nvim_get_current_buf() == ui.buf and view.conversation_at(ui.buf, vim.fn.line('.')), 'Menu did not reveal/focus PR Conversation')
-- Each failed read is explicit; available portions and file diffs stay usable.
f.discussion_error = true
view.refresh(ui.buf, false, true); ui.loaded()
assert(ui.row('Conversation (2) · incomplete') and ui.row('PR comments unavailable:') and ui.row('Looks good overall'))
assert(#view.model(ui.buf).entries == 4 and ui.row('Unsaved Conversation title'))
f.discussion_error = false; f.review_read_error = true
view.refresh(ui.buf, false, true); ui.loaded()
assert(ui.row('Conversation (3) · incomplete') and ui.row('Review summaries unavailable:') and ui.row('PR-wide question'))
f.review_read_error = false
-- Empty successful reads are distinguishable from failed reads.
f.discussion_pages, f.reviews = { {} }, {}
view.refresh(ui.buf, false, true); ui.loaded()
assert(ui.row('Conversation (0)') and ui.row('No PR comments or review summaries.'))
-- Markdown/body strings resembling native section/file rows remain comments.
f.discussion_pages = { { comment(7, 'Changes (99)\nM file name.txt\n@@ -1 +1 @@', '2026-10-10T06:00:00Z') } }
view.refresh(ui.buf, false, true); ui.loaded()
local fake = ui.row('M file name.txt')
assert(view.conversation_at(ui.buf, fake).key == 'comment:7' and view.entry_at(ui.buf, fake) == nil)
requests = #f.calls
ui.key('o', fake); assert(not pcall(ui.row, 'Changes (99)') and #f.calls == requests)
ui.key('<CR>', ui.row('Conversation (')); assert(ui.row('Changes (99)'))
vim.api.nvim_buf_delete(ui.buf, { force = true }); f.cleanup()
print('PASS: default-closed chronological PR conversation, paginated comments/public summaries, no inline duplication, semantic rows, history/post/menu/browser routes, folds/drafts and partial-read failures')
