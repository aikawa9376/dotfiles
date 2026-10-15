local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local api, events = require('git.features.pr_timeline'), require('git.features.pr_timeline_events')
local schema = vim.json.decode(table.concat(vim.fn.readfile(plugin .. '/tests/fixtures/pr_timeline_schema.json'), '\n'))
local types = {}
for name, fields in pairs(schema) do
  types[name] = {}; for _, field in ipairs(fields) do types[name][field] = true end
end
local query = api.query(types)
assert(not query:find('itemTypes:', 1, true), 'Timeline still filters out GitHub activity')
local ctx = { url = 'https://github.example.test/org/repo/pull/7' }
for name, fields in pairs(types) do if fields.actor and fields.createdAt and fields.id then
  assert(query:find('... on ' .. name .. ' {', 1, true), 'Missing advertised event: ' .. name)
  assert(api.entry(ctx, { __typename = name, id = name, actor = vim.NIL }), 'Missing formatter for ' .. name)
end end
for _, kind in ipairs({ 'PullRequestReviewThread', 'PullRequestCommitCommentThread', 'PullRequestRevisionMarker' }) do
  assert(not api.entry(ctx, { __typename = kind, id = kind }), 'File comments / read markers leaked into Conversation')
end
local function event(kind, fields, expected, color)
  local node = vim.tbl_extend('force', { __typename = kind, id = kind, createdAt = '2026-10-15T00:00:00Z', actor = { login = 'github-actions' } }, fields)
  local entry = assert(api.entry(ctx, node))
  assert(entry.label:find(expected, 1, true), vim.inspect(entry))
  assert(entry.parts[1][2] == 'Normal', 'Event prose was given a whole-row category tint')
  if color then assert(entry.parts[2][2] == color) end
  local chunks = api.chunks(entry, 'viewer')
  assert(chunks[2][1] == '@github-actions ' and chunks[#chunks][2] == 'Comment')
  return entry
end
event('LabeledEvent', { label = { name = 'awaiting review' } }, 'added label awaiting review', 'GitPrTimelineLabel')
event('UnlabeledEvent', { label = { name = 'stale' } }, 'removed label stale', 'GitPrTimelineLabel')
event('ReviewRequestedEvent', { requestedReviewer = { slug = 'maintainers', organization = { login = 'org' } } },
  'requested a review from org/maintainers', 'GitPrTimelineReview')
event('AssignedEvent', { assignee = { login = 'assigned' } }, 'assigned @assigned', 'GitPrTimelineReview')
event('BaseRefChangedEvent', { previousRefName = 'main', currentRefName = 'develop' }, 'main → develop', 'GitPrTimelineBranch')
event('RenamedTitleEvent', { previousTitle = 'Old\ntitle', currentTitle = 'New title' }, 'Old title → New title', 'GitPrTimelineBranch')
event('ProjectV2ItemStatusChangedEvent', { project = { title = 'Release', url = 'https://github.example.test/orgs/org/projects/1' },
  previousStatus = 'Todo', status = 'In progress' }, 'Release: Todo → In progress', 'GitPrTimelineProject')
event('DeployedEvent', { deployment = { environment = 'preview', commit = { oid = 'abcdef1234' } } }, 'preview · abcdef1', 'GitPrTimelineDeployment')
for state, group in pairs({ SUCCESS = 'GitPrPositive', FAILURE = 'DiagnosticError', PENDING = 'DiagnosticWarn' }) do
  local entry = event('DeploymentEnvironmentChangedEvent', { deploymentStatus = {
    environment = 'production', state = state, logUrl = 'https://ci.example.test/log/1' } }, 'production · ' .. state, group)
  assert(entry.url == 'https://ci.example.test/log/1')
end
assert(event('DeploymentEnvironmentChangedEvent', { deploymentStatus = { state = 'SUCCESS', logUrl = 'javascript:bad()' } },
  'SUCCESS').url == ctx.url)
local ref = event('CrossReferencedEvent', { source = { number = 42, title = 'Follow-up', url = 'https://github.example.test/other/repo/pull/42',
  repository = { nameWithOwner = 'other/repo' } } }, 'other/repo#42 Follow-up', 'GitPrTimelineReference')
assert(ref.url == 'https://github.example.test/other/repo/pull/42')
event('ReviewDismissedEvent', { review = { author = { login = 'reviewer' } }, previousReviewState = 'APPROVED',
  dismissalMessage = 'Out of date' }, '@reviewer (APPROVED) · Out of date', 'DiagnosticWarn')
event('IssueFieldChangedEvent', { issueField = { name = 'Priority' }, previousValue = 'Low', newValue = 'High' }, 'Priority: Low → High', 'GitPrTimelineProject')
local future = api.entry(ctx, { __typename = 'FutureActivityEvent', id = 'FUTURE', actor = vim.NIL })
assert(future.label == 'future activity' and future.user == nil)
local limited = api.query({ LabeledEvent = { id = true, actor = true, createdAt = true } })
assert(not limited:find('label { name }', 1, true) and not limited:find('ProjectV2ItemStatusChangedEvent', 1, true))
-- Query/filter and category contracts use the real public QMK timeline fixture.
-- In particular github-actions' keyboard/keymap/stale labels used to disappear.
local fixture = vim.json.decode(table.concat(vim.fn.readfile(plugin .. '/tests/fixtures/pr_timeline_qmk.json'), '\n'))
local f = require('helpers.pr_fixture').new()
local ui = require('helpers.pr_ui').new(f)
local view = require('git.features.pr')
f.timeline_pages, f.discussion, f.reviews = { fixture.nodes }, {}, {}
for _, node in ipairs(fixture.nodes) do
  if node.__typename == 'IssueComment' then
    f.discussion[#f.discussion + 1] = { id = tonumber(node.url:match('issuecomment%-(%d+)')), node_id = node.id,
      body = 'Discussion ' .. node.id, user = { login = 'author' } }
  elseif node.__typename == 'PullRequestReview' then
    f.reviews[#f.reviews + 1] = { id = tonumber(node.url:match('pullrequestreview%-(%d+)')), node_id = node.id,
      body = '', state = node.state, user = { login = 'reviewer' } }
  end
end
ui.open()
local model = view.model(ui.buf)
assert(#model.conversation.entries == #fixture.nodes, 'A non-file QMK timeline item was lost')
for index, node in ipairs(fixture.nodes) do
  local entry = model.conversation.entries[index]
  if node.__typename:match('Event$') then assert(entry.key == 'event:' .. node.id) end
end
local count = #f.calls
ui.key('>', ui.row('Conversation ('))
assert(#f.calls == count and ui.row('added label keyboard') and ui.row('added label keymap'))
assert(ui.row('added label stale') and ui.row('removed label stale') and ui.row('added label awaiting review'))
assert(ui.row('requested a review from @zvecr') and ui.row('mentioned this PR in vial-kb/vial-qmk#1038'))
local colors = {}
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(ui.buf, vim.api.nvim_create_namespace('git_pr_status'), 0, -1, { details = true })) do
  if mark[4].hl_group then colors[mark[4].hl_group] = true end
end
assert(colors.GitPrTimelineLabel and colors.GitPrTimelineReview and colors.GitPrTimelineReference)
local open, target = vim.ui.open, nil
vim.ui.open = function(url) target = url end
ui.key('<CR>', ui.row('mentioned this PR in vial-kb/vial-qmk#1038'))
assert(target == 'https://github.com/vial-kb/vial-qmk/pull/1038')
vim.ui.open = open
ui.key('gcp', 1)
local input = vim.api.nvim_get_current_buf()
assert(table.concat(vim.api.nvim_buf_get_lines(vim.b[input].git_pr_context, 0, -1, false), '\n'):find('added label keyboard', 1, true))
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(input, 0, -1, false), { '' }))
ui.close_draft(input)
ui.refresh()
local schemas = 0
for _, call in ipairs(f.calls) do if call.opts.stdin then
  local payload = vim.json.decode(call.opts.stdin)
  if payload.query and payload.query:find('timelineTypes:', 1, true) then schemas = schemas + 1 end
end end
assert(schemas == 1, 'Event capabilities were fetched again on every refresh')
f.timeline_partial_errors = { { message = 'Some project details are unavailable' } }
ui.refresh()
assert(#view.model(ui.buf).conversation.entries == #fixture.nodes and ui.row('added label keyboard'))
assert(ui.row('PR timeline incomplete: Some project details are unavailable'))
-- A server that disables introspection can still serve the longstanding
-- timeline fields. It must not receive unsupported modern event fragments.
f.timeline_partial_errors = nil
f.timeline_pages = { { fixture.nodes[2] } }
f.api_response = function(path, _, payload)
  if path == 'graphql' and payload.query:find('timelineTypes:', 1, true) then
    return { data = { errors = { { message = 'Introspection is disabled' } } } }
  end
end
local done, success, loaded
require('git.features.async').run(f.root, function()
  return api.load(vim.tbl_extend('force', view.model(ui.buf).ctx, { host = 'legacy.example.test' }), f.head)
end, function(ok, value) done, success, loaded = true, ok, value end)
ui.wait(function() return done end)
assert(success and #loaded == 1, vim.inspect(loaded))
local request = vim.json.decode(f.calls[#f.calls].opts.stdin)
assert(request.query:find('LabeledEvent', 1, true) and not request.query:find('IssueFieldChangedEvent', 1, true))
vim.cmd('highlight clear GitPrTimelineLabel')
vim.api.nvim_exec_autocmds('ColorScheme', { pattern = 'test' })
assert(vim.api.nvim_get_hl(0, { name = 'GitPrTimelineLabel' }).link == 'Type', vim.inspect(vim.api.nvim_get_hl(0, { name = 'GitPrTimelineLabel' })))
vim.api.nvim_buf_delete(ui.buf, { force = true }); f.cleanup()
print('PASS: full public QMK timeline, bot labels, schema-driven event coverage, restrained category colors, deployments/references/review/team/project details, generic fallback, browser/history and cached capabilities')
