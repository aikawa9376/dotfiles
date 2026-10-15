local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local ui = require('helpers.pr_ui').new(f)
local view, api, async = require('git.features.pr'), require('git.features.pr_timeline'), require('git.features.async')
f.pr.state = 'MERGED'
f.discussion = {
  { id = 1, node_id = 'COMMENT1', user = { login = 'reviewer' }, body = 'Please fix this', created_at = '2026-10-13T01:00:00Z' },
  { id = 2, node_id = 'COMMENT2', user = { login = f.viewer }, body = 'Fixed and pushed', created_at = '2026-10-13T03:00:00Z' },
}
f.reviews = {
  { id = 1, node_id = 'REVIEW1', user = { login = 'reviewer' }, state = 'APPROVED', body = 'Looks good', submitted_at = '2026-10-13T02:00:00Z' },
  { id = 4, node_id = 'PRIVATE', user = { login = f.viewer }, state = 'PENDING', body = 'Private', comments = {}, commit_id = f.head },
}
local force = { __typename = 'HeadRefForcePushedEvent', id = 'FORCE1', actor = { login = 'author' },
  createdAt = '2026-10-13T02:30:00Z', beforeCommit = { oid = f.base }, afterCommit = { oid = f.head } }
local commit_url = f.pr.url .. '/commits/' .. f.head
f.timeline_pages = {
  {
    { __typename = 'IssueComment', id = 'COMMENT1' },
    -- Different node-ID generations join by their unchanged public permalink.
    { __typename = 'PullRequestReview', id = 'NEW_REVIEW1', url = f.pr.url .. '#pullrequestreview-1', state = 'APPROVED' },
    { __typename = 'PullRequestCommit', id = 'COMMIT1', url = commit_url, commit = {
      oid = f.head, messageHeadline = 'Fix after review', committedDate = '2020-01-01T00:00:00Z',
      author = { name = 'Author', user = { login = 'author' } },
    } }, force,
  },
  { vim.NIL, force, { __typename = 'IssueComment', id = 'COMMENT2' },
    { __typename = 'PullRequestReview', id = 'PRIVATE', state = 'PENDING' },
    { __typename = 'MergedEvent', id = 'MERGED1', actor = { login = 'merger' }, createdAt = '2026-10-13T04:00:00Z',
      commit = { oid = f.head, url = 'https://ghe.example.test/org/repo/commit/' .. f.head } },
  },
}
local function keys()
  return vim.tbl_map(function(entry) return entry.key end, view.model(ui.buf).conversation.entries)
end
ui.open()
assert(vim.deep_equal(keys(), { 'comment:1', 'review:1', 'commit:COMMIT1', 'event:FORCE1', 'comment:2', 'event:MERGED1' }))
assert(#view.model(ui.buf).threads == 3 and #view.model(ui.buf).commits == 1, 'Timeline must not change local diff/commit models')
local pages = {}
for _, call in ipairs(f.calls) do if call.argv[2] == 'api' and vim.tbl_contains(call.argv, 'graphql') then
  local payload = vim.json.decode(call.opts.stdin)
  if payload.query:find('timelineItems', 1, true) then
    assert(payload.variables.owner == 'org' and payload.variables.name == 'repo' and payload.variables.number == 7)
    assert(payload.query:find('HeadRefForcePushedEvent', 1, true) and not payload.query:find('itemTypes:', 1, true))
    pages[#pages + 1] = payload.variables.cursor or 'first'
  end
end end
assert(vim.deep_equal(pages, { 'first', '2' }))
local title = ui.row('PR title'); vim.api.nvim_buf_set_lines(ui.buf, title - 1, title, false, { 'Unsaved timeline title' })
vim.api.nvim_buf_set_lines(ui.buf, title + 1, title + 1, false, { 'More body' })
local reads = #f.calls
ui.key('>', ui.row('Conversation ('))
local commit_row = ui.row('committed ' .. f.head:sub(1, 7))
local force_row = ui.row('force-pushed ' .. f.base:sub(1, 7) .. ' → ' .. f.head:sub(1, 7))
assert(ui.row('Looks good') < commit_row and commit_row < force_row and force_row < ui.row('Fixed and pushed'))
assert(ui.row('2020-01-01 00:00:00 UTC (commit date)'), 'Commit date must not claim to be a push timestamp')
assert(view.conversation_at(ui.buf, force_row).key == 'event:FORCE1')
assert(view.entry_at(ui.buf, force_row) == nil and view.commit_at(ui.buf, force_row) == nil and #f.calls == reads)
local opened, original = nil, vim.ui.open; vim.ui.open = function(url) opened = url end
ui.key('gx', commit_row); assert(opened == commit_url)
ui.key('<CR>', force_row); assert(opened == f.pr.url and vim.api.nvim_get_current_buf() == ui.buf)
ui.key('gA', force_row); assert(#f.calls == reads and vim.api.nvim_get_current_buf() == ui.buf)
vim.ui.open = original
local ns, merged = vim.api.nvim_create_namespace('git_pr_status'), ui.row('merged ' .. f.head:sub(1, 7))
local positive, warning = false, false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(ui.buf, ns, 0, -1, { details = true })) do
  positive = positive or (mark[2] == merged - 1 and mark[4].hl_group == 'GitPrPositive')
  warning = warning or (mark[2] == force_row - 1 and mark[4].hl_group == 'DiagnosticWarn')
end
assert(positive and warning)
ui.key('gcp', 1)
local input = vim.api.nvim_get_current_buf()
local context = vim.b[input].git_pr_context
local history = table.concat(vim.api.nvim_buf_get_lines(context, 0, -1, false), '\n')
assert(history:find('force-pushed', 1, true) and history:find('committed', 1, true) and not history:find('Private', 1, true))
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(context, vim.api.nvim_create_namespace('git_pr_history'), 0, -1, { details = true })) do
  local line = vim.api.nvim_buf_get_lines(context, mark[2], mark[2] + 1, false)[1]
  if line:find('merged ', 1, true) then
    assert(mark[4].hl_group ~= 'DiagnosticWarn', 'Comment header colors must not overwrite timeline event colors')
  end
end
ui.close_draft(input)
local function refresh()
  local old = view.model(ui.buf); view.refresh(ui.buf, false, true)
  ui.wait(function() return view.model(ui.buf) ~= old and not async.busy(f.root) end)
end
refresh(); assert(ui.row('force-pushed') and ui.row('Unsaved timeline title') and vim.bo[ui.buf].modified)
-- Separate timeline failures must retain REST comments/reviews and file diffs.
f.timeline_error = true; refresh()
assert(ui.row('PR timeline unavailable: Timeline rejected') and not pcall(ui.row, 'force-pushed'))
assert(vim.deep_equal(keys(), { 'comment:1', 'review:1', 'comment:2' }) and #view.model(ui.buf).entries == 4)
f.timeline_error = nil; f.timeline_head = f.base; refresh()
assert(ui.row('PR head changed while reading its timeline') and not pcall(ui.row, 'force-pushed'))
f.timeline_head = nil; f.timeline_page_info = { hasNextPage = true, endCursor = '1' }; refresh()
assert(ui.row('repeated timeline pagination cursor') and not pcall(ui.row, 'force-pushed'))
f.timeline_page_info = nil; f.discussion_error = true; refresh()
assert(ui.row('PR comments unavailable:') and ui.row('force-pushed') and ui.row('Looks good'))
local unavailable = api.entry(view.model(ui.buf).ctx, { __typename = 'HeadRefForcePushedEvent', id = 'OLD',
  actor = vim.NIL, beforeCommit = vim.NIL, afterCommit = vim.NIL })
assert(unavailable.label == 'force-pushed — → —')
assert(api.entry(view.model(ui.buf).ctx, { __typename = 'UnknownEvent', id = 'UNKNOWN' }).label == 'unknown')
vim.api.nvim_buf_delete(ui.buf, { force = true }); f.cleanup()
print('PASS: paginated authoritative timeline order, node/permalink identities, old commit dates, duplicate/private exclusion, semantic events/browser/actions, composer history, drafts and isolated timeline failures')
