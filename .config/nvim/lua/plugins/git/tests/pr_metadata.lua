local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local ui, api = require('helpers.pr_ui').new(f), require('git.features.pr_metadata')
local ctx = { root = f.root, host = 'ghe.example.test', repo = 'org/repo', number = 7, url = f.pr.url }
local requested = { users = { { login = 'reviewer' } }, teams = {} }
local writes = {}
f.pr.labels, f.pr.assignees = { { name = 'old' } }, {}
f.api_response = function(path, method, payload)
  if method ~= 'GET' then writes[#writes + 1] = { path, method, payload } end
  if path == 'repos/org/repo/labels' then return { data = { { { name = 'old' }, { name = '日本語 / bug' } } } }
  elseif path == 'repos/org/repo/assignees' then return { data = { { { login = f.viewer } } } }
  elseif path == 'repos/org/repo/collaborators' then return { data = { { { login = f.viewer }, { login = f.pr.author.login }, { login = 'reviewer' } } } }
  elseif path == 'orgs/org/teams' then return { data = { { { slug = 'team' } } } }
  elseif path == 'repos/org/repo/issues/7/labels' then
    f.pr.labels[#f.pr.labels + 1] = { name = payload.labels[1] }; return { data = f.pr.labels }
  elseif path:match('^repos/org/repo/issues/7/labels/') then
    local value = vim.uri_decode(path:match('/labels/(.+)$'))
    f.pr.labels = vim.tbl_filter(function(label) return label.name ~= value end, f.pr.labels)
    return { data = f.pr.labels }
  elseif path == 'repos/org/repo/issues/7/assignees' then
    f.pr.assignees = method == 'DELETE' and {} or { { login = payload.assignees[1] } }; return { data = {} }
  elseif path == 'repos/org/repo/pulls/7/requested_reviewers' then
    if method == 'POST' then
      if payload.team_reviewers then requested.teams = { { slug = payload.team_reviewers[1] } }
      else requested.users[#requested.users + 1] = { login = payload.reviewers[1] } end
    elseif method == 'DELETE' then requested.teams = {} end
    return { data = vim.deepcopy(requested) }
  elseif path == 'repos/org/repo/pulls/7' and method == 'PATCH' and payload.state then
    f.pr.state = payload.state:upper(); return { data = {} }
  end
end
local function run(fn)
  local done, ok, value
  require('git.features.async').run(f.root, fn, function(success, result) done, ok, value = true, success, result end)
  assert(vim.wait(5000, function() return done end, 10)); return ok, value
end
assert(run(function() return api.change(ctx, 'labels', '日本語 / bug', false) end))
assert(#f.pr.labels == 2 and f.pr.labels[1].name == 'old')
assert(run(function() return api.change(ctx, 'labels', '日本語 / bug', true) end))
assert(#f.pr.labels == 1 and not writes[#writes][1]:find(' ', 1, true))
local count = #writes
assert(not run(function() return api.change(ctx, 'labels', 'old', false) end) and #writes == count)
assert(run(function() return api.change(ctx, 'assignees', f.viewer, false) end))
assert(writes[#writes][3].assignees[1] == f.viewer)
local ok, snapshot = run(function() return api.load(ctx, 'reviewers') end)
assert(ok and not vim.tbl_contains(snapshot.candidates, f.pr.author.login) and vim.tbl_contains(snapshot.candidates, 'team:team'))
assert(run(function() return api.change(ctx, 'reviewers', 'team:team', false) end))
assert(writes[#writes][3].team_reviewers[1] == 'team')
assert(run(function() return api.change(ctx, 'reviewers', 'team:team', true) end))
ui.open()
local select = vim.ui.select
local choices
vim.ui.select = function(items, _, cb) choices = items; cb(items[1]) end
ui.key('gE', ui.row('Labels:'))
ui.wait(function() return choices ~= nil end); assert(choices[2].name == 'old' and choices[2].present)
vim.ui.select = select
ui.key('gE', 1); assert(vim.b.git_action_menu_kind == 'pr-metadata')
vim.fn.maparg('q', 'n', false, true).callback()
local async = require('git.features.async')
require('git.features.github_actions').lifecycle(ctx, 'OPEN')
ui.wait(function() return f.pr.state == 'CLOSED' and not async.busy(f.root) end)
require('git.features.github_actions').lifecycle(ctx, 'CLOSED')
ui.wait(function() return f.pr.state == 'OPEN' and not async.busy(f.root) end)
f.pr.state = 'MERGED'; count = #writes
require('git.features.github_actions').lifecycle(ctx)
ui.wait(function() return not async.busy(f.root) end); assert(#writes == count)
vim.api.nvim_buf_delete(ui.buf, { force = true }); f.cleanup()
print('PASS: searchable header selectors, individual memberships, Unicode labels, teams/author exclusion, stale selection guards and PR close/reopen')
