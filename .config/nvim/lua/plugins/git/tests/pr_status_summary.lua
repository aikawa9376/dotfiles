local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local ui = require('helpers.pr_ui').new(f)
local view = require('git.features.pr')
local ns = vim.api.nvim_create_namespace('git_pr_status')
dofile(plugin .. '/../../config/colorScheme.lua')
vim.api.nvim_exec_autocmds('ColorScheme', { pattern = 'git-test' })
assert(vim.api.nvim_get_hl(0, { name = 'GitPrPositive' }).fg == tonumber('98be65', 16))
assert(vim.api.nvim_get_hl(0, { name = 'GitPrHeaderLabel' }).fg == tonumber('7bb8c1', 16))
local function colored(text, group)
  local row = ui.row(text)
  local line = vim.api.nvim_buf_get_lines(ui.buf, row - 1, row, false)[1]
  local start, finish = line:find(text, 1, true)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(ui.buf, ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    if mark[4].end_col and mark[4].hl_group == group and mark[3] <= start - 1 and mark[4].end_col >= finish then return true end
  end
  return false
end
local function thread(id, resolved, state)
  return { id = 'THREAD' .. id, isResolved = resolved, comments = { nodes = {
    { fullDatabaseId = tostring(id), pullRequestReview = { state = state or 'COMMENTED' } },
  } } }
end
-- Thread pagination includes outdated public conversations; replies and private
-- draft threads must not inflate the count of unresolved conversations.
f.thread_pages = { { thread(101, false), thread(201, false) }, { thread(301, true), thread(901, false, 'PENDING') } }
ui.open()
ui.key('>', ui.row('CI:'))
assert(ui.row('2 unresolved') and not pcall(ui.row, 'Your last review:'))
assert(colored('CI', 'GitPrHeaderLabel') and colored('Review', 'GitPrHeaderLabel'))
assert(colored('✗ 1/2', 'DiagnosticError') and colored('review required', 'DiagnosticWarn'))
assert(not colored('CI: ✗ 1/2', 'DiagnosticError'), 'Only the status value should change color')
local model = view.model(ui.buf)
assert(model.thread_status.total == 3 and model.threads[3].resolved and model.threads[1].node_id == 'THREAD101')
local cursors = {}
for _, call in ipairs(f.calls) do if vim.tbl_contains(call.argv, 'graphql') then
  local payload = vim.json.decode(call.opts.stdin)
  if payload.query:find('reviewThreads', 1, true) then
  assert(payload.query:find('fullDatabaseId', 1, true))
  assert(payload.variables.owner == 'org' and payload.variables.name == 'repo' and payload.variables.number == 7)
  cursors[#cursors + 1] = payload.variables.cursor or 'first'
  end
end end
assert(vim.deep_equal(cursors, { 'first', '2' }))
for _, item in ipairs(model.threads) do require('git.features.pr_read_state').mark(model.ctx, f.viewer, item.comments) end
assert(ui.row('2 unresolved'), 'Reading a conversation must not resolve it')
-- Latest submission is chosen by submission time, independently of REST order,
-- another user's reviews, and the presence of our newer pending review.
f.reviews = {
  { id = 700, state = 'COMMENTED', submitted_at = '2026-10-09T00:00:00Z', commit_id = f.head, user = { login = f.viewer } },
  { id = 501, state = 'APPROVED', submitted_at = '2026-10-10T00:00:00Z', commit_id = f.head, user = { login = f.viewer } },
  { id = 999, state = 'CHANGES_REQUESTED', submitted_at = '2026-10-11T00:00:00Z', commit_id = f.head, user = { login = 'other' } },
  { id = 888, state = 'PENDING', commit_id = f.head, body = '', comments = {}, user = { login = f.viewer } },
}
f.pr.reviewDecision, f.pr.mergeStateStatus = 'APPROVED', 'CLEAN'
f.pr.statusCheckRollup = { { name = 'test', status = 'COMPLETED', conclusion = 'SUCCESS' }, { context = 'external', state = 'SUCCESS' } }
f.thread_pages = { { thread(101, true), thread(201, true), thread(301, true) } }
ui.refresh()
assert(ui.row('Your review: PENDING') and ui.row('@viewer ✓') and not pcall(ui.row, 'Your last review:'))
assert(view.model(ui.buf).review.submitted.id == 501)
assert(not pcall(ui.row, 'Merge: CLEAN'), 'Clean merge state repeats the mergeable summary')
for _, text in ipairs({ '✓', '✓ 2', 'approved', 'mergeable', 'test: SUCCESS', 'external: SUCCESS', '0 unresolved' }) do
  assert(colored(text, 'GitPrPositive'), 'Missing positive status highlight: ' .. text)
end
assert(not colored('CI: ✓ 2', 'GitPrPositive') and not colored('Review: approved', 'GitPrPositive'))
f.reviews[4] = nil; f.reviews[2].commit_id = f.base
ui.refresh()
assert(not pcall(ui.row, 'Your review:') and not pcall(ui.row, 'Your last review:'))
assert(view.model(ui.buf).review.submitted.commit_id == f.base)
-- Dismissed or later change-request reviews never retain approval coloring.
f.reviews[2].state = 'DISMISSED'; ui.refresh()
assert(ui.row('@viewer ⊘') and colored('⊘', 'Comment') and not colored('⊘', 'GitPrPositive'))
f.reviews[#f.reviews + 1] = { id = 600, state = 'CHANGES_REQUESTED', submitted_at = '2026-10-11T00:00:00Z',
  commit_id = f.head, user = { login = f.viewer } }
f.pr.reviewDecision, f.pr.mergeable, f.pr.mergeStateStatus = 'CHANGES_REQUESTED', 'CONFLICTING', 'DIRTY'
f.pr.statusCheckRollup[1].conclusion = 'FAILURE'; ui.refresh()
assert(ui.row('@viewer ✗') and colored('✗', 'DiagnosticError'))
assert(colored('✗ 1/2', 'DiagnosticError') and colored('changes requested', 'DiagnosticError') and colored('conflicts', 'DiagnosticError'))
assert(not colored('CI: ✗ 1/2', 'GitPrPositive') and not colored('Review: changes requested', 'GitPrPositive'))
assert(not colored('conflicts', 'GitPrPositive') and not colored('DIRTY', 'GitPrPositive'))
assert(colored('external: SUCCESS', 'GitPrPositive'), 'Successful check should remain green in a mixed CI result')
-- Failure is explicit and isolated; it must not silently report zero unresolved.
f.thread_status_error = true; f.reviews = {}; ui.refresh()
assert(ui.row('unresolved: unavailable') and ui.row('Thread status unavailable: Thread status rejected'))
assert(not pcall(ui.row, '0 unresolved') and not pcall(ui.row, 'Your last review:'))
assert(#view.model(ui.buf).entries == 4 and #view.model(ui.buf).threads == 3)
f.thread_status_error = false; f.thread_pages = { {} }; f.comments = { {} }; ui.refresh()
assert(ui.row('0 unresolved') and view.model(ui.buf).thread_status.total == 0)
-- Dashes and punctuation remain normal; pending checks color only their value.
f.pr.statusCheckRollup, f.pr.reviewDecision, f.pr.mergeable = vim.NIL, vim.NIL, 'UNKNOWN'
ui.refresh()
assert(ui.row('CI: — · Review: — · checking') and colored('—', 'Normal') and colored('checking', 'DiagnosticWarn'))
local summary_row = ui.row('CI: —')
local summary_line = vim.api.nvim_buf_get_lines(ui.buf, summary_row - 1, summary_row, false)[1]
local dash_count, colon_count = 0, 0
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(ui.buf, ns, { summary_row - 1, 0 }, { summary_row - 1, -1 }, { details = true })) do
  local text = summary_line:sub(mark[3] + 1, mark[4].end_col)
  if text == '—' then dash_count = dash_count + 1; assert(mark[4].hl_group == 'Normal') end
  if text == ': ' then colon_count = colon_count + 1; assert(mark[4].hl_group == 'Normal') end
end
assert(dash_count == 2 and colon_count == 2, 'Both absent statuses and their colons should be normal')
-- Completed merges take precedence over an unknown/stale mergeability value.
f.pr.state, f.pr.reviewDecision = 'MERGED', 'APPROVED'
for _, mergeable in ipairs({ 'UNKNOWN', 'CONFLICTING', 'MERGEABLE' }) do
  f.pr.mergeable = mergeable; ui.refresh()
  assert(ui.row('CI: — · Review: approved · merged') and colored('merged', 'GitPrPositive'))
  assert(not pcall(ui.row, 'checking') and not pcall(ui.row, 'conflicts') and not pcall(ui.row, 'mergeable'))
end
f.pr.state, f.pr.reviewDecision, f.pr.mergeable = 'OPEN', vim.NIL, 'UNKNOWN'
f.pr.statusCheckRollup = { { name = 'queued', status = 'QUEUED', conclusion = vim.NIL },
  { name = 'passed', status = 'COMPLETED', conclusion = 'SUCCESS' } }
ui.refresh()
assert(ui.row('CI: ◷ 1/2') and colored('◷ 1/2', 'DiagnosticWarn') and not colored('CI: ◷ 1/2', 'DiagnosticWarn'))
vim.api.nvim_buf_delete(ui.buf, { force = true }); f.cleanup()
print('PASS: paginated resolution vs read receipts/drafts, latest own submitted review, compact reviewer icons, aggregate status colors, merged precedence and isolated read failures')
