local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.issue_fixture').new()
local github, model = require('git.features.github'), require('git.features.issue_model')
local ctx = vim.deepcopy(f.ctx)
local value = f.run(function() return model.load(github.resolve(ctx)) end)
assert(value.issue.title == 'Issue title' and value.viewer == 'viewer' and #value.conversation.entries == 3)
assert(not package.loaded['git.features.pr_model'], 'Issue loaded the PR revision model')
assert(value.conversation.entries[2].kind == 'event' and value.conversation.entries[3].id == 11)
local resolved = f.run(function() return github.resolve({ root = f.root, resource_kind = 'issue', number = 7 }) end)
assert(resolved.repo == 'org/repo' and resolved.number == 7, 'Issue depended on a branch PR')
for _, url in ipairs({ 'https://ghe.example.test/org/repo/pull/7', 'https://ghe.example.test/org/repo/issues/7oops' }) do
  f.run(function() return github.resolve({ root = f.root, resource_kind = 'issue', url = url }) end, 'Issue URL')
end
f.issue.pull_request = {}; f.run(function() return github.issue(ctx) end, 'pull request'); f.issue.pull_request = nil
local original_url = f.issue.html_url
f.issue.html_url = 'https://ghe.example.test/other/repo/issues/7'
f.run(function() return github.issue(ctx) end, 'identity changed'); f.issue.html_url = original_url
f.run(function() return github.resolve({ root = f.root, host = ctx.host, repo = ctx.repo, resource_kind = 'issue', number = -2 }) end, 'Invalid Issue number')
local expected = vim.deepcopy(value.issue)
f.issue.body = 'Remote body from another user'
f.run(function() return model.write(ctx, expected, 'New title', expected.body) end)
assert(f.issue.title == 'New title' and f.issue.body == 'Remote body from another user')
assert(f.writes[#f.writes].payload.body == nil, 'Title save overwrote an unedited remote body')
f.run(function() return model.write(ctx, expected, expected.title, 'Local body') end, 'changed on GitHub')
expected = f.run(function() return github.issue(ctx) end)
f.permissions.viewerCanUpdate = false
local count = #f.writes
f.run(function() return model.write(ctx, expected, 'Denied', expected.body) end, 'permission')
assert(#f.writes == count); f.permissions.viewerCanUpdate = true
f.run(function() return model.lifecycle(ctx, expected, 'not_planned') end)
assert(f.issue.state == 'closed' and f.issue.state_reason == 'not_planned')
f.run(function() return model.lifecycle(ctx, expected, 'completed') end, 'state changed')
expected = vim.deepcopy(f.issue)
f.run(function() return model.lifecycle(ctx, expected) end)
assert(f.issue.state == 'open' and f.writes[#f.writes].payload.state_reason == nil)
local metadata = require('git.features.pr_metadata')
f.issue.labels[#f.issue.labels + 1] = { name = 'concurrent' }
f.run(function() return metadata.change(ctx, 'labels', 'help wanted', false) end)
assert(#f.issue.labels == 3 and f.writes[#f.writes].payload.labels[1] == 'help wanted')
f.run(function() return metadata.change(ctx, 'labels', 'help wanted', false) end, 'Metadata changed')
f.run(function() return metadata.change(ctx, 'labels', 'help wanted', true) end)
assert(#f.issue.labels == 2 and f.writes[#f.writes].path:find('help%20wanted', 1, true))
f.run(function() return metadata.change(ctx, 'assignees', 'bob', false) end)
assert(#f.issue.assignees == 2)
f.permissions.viewerCanLabel = false
count = #f.writes; f.run(function() return metadata.change(ctx, 'labels', 'bug', true) end, 'permission'); assert(#f.writes == count)
f.run(function() return metadata.load(ctx, 'reviewers') end, 'no review requests')
local list = f.run(function() return model.list(ctx, { state = 'closed', labels = 'help wanted', assignee = 'bob' }) end)
assert(#list == 1 and list[1].number == 7)
local args = table.concat(f.calls[#f.calls], ' ')
assert(args:find('--state closed', 1, true) and args:find('--label help wanted', 1, true) and args:find('--assignee bob', 1, true))
local created = f.run(function() return model.create(ctx, 'New Issue\n\n# Markdown\nBody') end)
assert(created.number == 55 and f.writes[#f.writes].payload.body == '# Markdown\nBody')
ctx = vim.deepcopy(f.ctx)
f.comment_pages = { { f.comments[1] }, { f.comments[2], f.comments[1] } }
f.pages = { first = { nodes = { f.timeline[1], vim.NIL, f.timeline[2] }, pageInfo = { hasNextPage = true, endCursor = 'next' } },
  next = { nodes = { f.timeline[3], f.timeline[1], { __typename = 'UnknownEvent', id = 'UNKNOWN', actor = vim.NIL } },
    pageInfo = { hasNextPage = false, endCursor = vim.NIL } } }
value = f.run(function() return model.load(ctx) end)
assert(#value.conversation.entries == 4 and value.conversation.entries[3].id == 11, 'Timeline order/duplicate exclusion failed')
f.timeline_fail_cursor = 'next'
value = f.run(function() return model.load(ctx) end)
assert(#value.conversation.entries == 2 and #value.conversation.errors == 1, 'Timeline failure hid REST comments')
f.pages, f.timeline_fail_cursor, f.comment_pages = nil, nil, nil
f.fail = 'repos/org/repo/issues/7/comments?per_page=100'
value = f.run(function() return model.load(ctx) end)
assert(#value.conversation.entries == 1 and value.conversation.entries[1].kind == 'event' and #value.conversation.errors == 1)
f.fail = nil; f.comments, f.timeline, f.issue.body = {}, {}, vim.NIL
value = f.run(function() return model.load(ctx) end)
assert(value.issue.body == '' and #value.conversation.entries == 0)
f.cleanup()
print('PASS: Issue-only reads, explicit context, PR exclusion, field conflict/permission guards, state reasons, individual metadata, listing/creation, pagination and partial failures')
