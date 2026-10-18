-- Issue-only reads and writes. No local revisions, PR endpoints or reviews.
local M = {}
local github = require('git.features.github')
local conversation = require('git.features.pr_conversation')
local permission_fields = { update = 'viewerCanUpdate', close = 'viewerCanClose', reopen = 'viewerCanReopen',
  labels = 'viewerCanLabel', assignees = 'viewerCanAssign' }
function M.permissions(ctx)
  local owner, name = ctx.repo:match('^([^/]+)/([^/]+)$')
  local response = github.api(ctx, 'graphql', { query = [[query($owner:String!, $name:String!, $number:Int!) {
    repository(owner:$owner, name:$name) { issue(number:$number) {
      id number url title body state stateReason updatedAt
      viewerCanUpdate viewerCanClose viewerCanReopen viewerCanLabel viewerCanAssign
    } }
  }]], variables = { owner = owner, name = name, number = ctx.number } })
  assert(not response.errors, 'Issue permissions are unavailable')
  local repo = response.data and github.scalar(response.data.repository)
  local issue = repo and github.scalar(repo.issue)
  local identity = type(issue) == 'table' and github.issue_url_context(issue.url)
  assert(identity and identity.host:lower() == ctx.host:lower() and identity.repo:lower() == ctx.repo:lower()
    and identity.number == ctx.number and issue.number == ctx.number, 'Issue permissions identify another resource')
  return issue
end
function M.permit(ctx, operation)
  local fresh = M.permissions(ctx)
  assert(fresh[assert(permission_fields[operation], 'Invalid Issue operation')] == true,
    'You do not have permission to change this Issue')
  return fresh
end
function M.load(ctx)
  local issue = github.issue(ctx)
  local timeline = require('git.features.issue_timeline')
  local results = require('git.features.async').gather({
    function() return conversation.load(ctx) end,
    function() return github.api(ctx, 'user').login end,
    function() return timeline.load(ctx) end,
  })
  local errors = {}
  if not results[1].ok then errors[#errors + 1] = 'Comments unavailable: ' .. tostring(results[1].value) end
  if not results[3].ok then errors[#errors + 1] = 'Issue activity unavailable: ' .. tostring(results[3].value) end
  local history = conversation.build(ctx, results[1].ok and results[1].value or {}, {}, errors)
  if results[3].ok then timeline.apply(ctx, history, results[3].value) end
  return { ctx = vim.deepcopy(ctx), root = ctx.root, issue = issue, conversation = history,
    viewer = results[2].ok and results[2].value or nil,
    viewer_error = not results[2].ok and tostring(results[2].value) or nil }
end
function M.write(ctx, expected, title, body)
  assert(vim.trim(title) ~= '', 'Issue title cannot be empty')
  local payload = {}
  if title ~= expected.title then payload.title = title end
  if body ~= expected.body then payload.body = body end
  if not next(payload) then return expected end
  local fresh = github.issue(ctx)
  local permission = M.permit(ctx, 'update')
  for key in pairs(payload) do
    assert(fresh[key] == expected[key] and permission[key] == expected[key],
      'Issue ' .. key .. ' changed on GitHub; reopen it. Your draft is preserved.')
  end
  return github.api(ctx, ('repos/%s/issues/%d'):format(ctx.repo, ctx.number), payload, 'PATCH')
end
function M.comment(ctx, body)
  assert(vim.trim(body) ~= '', 'Comment cannot be empty')
  github.issue(ctx)
  return github.api(ctx, ('repos/%s/issues/%d/comments'):format(ctx.repo, ctx.number), { body = body })
end
function M.lifecycle(ctx, expected, reason)
  local fresh = github.issue(ctx)
  assert(fresh.state == expected.state and github.scalar(fresh.state_reason) == github.scalar(expected.state_reason),
    'Issue state changed; reopen the action menu')
  local closing = fresh.state == 'open'
  local permission = M.permit(ctx, closing and 'close' or 'reopen')
  assert(permission.state:lower() == fresh.state
    and (github.scalar(permission.stateReason) or ''):lower() == (github.scalar(fresh.state_reason) or ''):lower(),
    'Issue state changed; reopen the action menu')
  local payload = { state = closing and 'closed' or 'open' }
  if closing then
    assert(reason == 'completed' or reason == 'not_planned', 'Choose a close reason')
    payload.state_reason = reason
  end
  -- Reopening never sends a reason that could overwrite the server's choice.
  return github.api(ctx, ('repos/%s/issues/%d'):format(ctx.repo, ctx.number), payload, 'PATCH')
end
function M.list(ctx, filters)
  filters = require('git.features.issue_options').normalize(filters)
  -- gh queries Issues directly, caps pagination and omits full bodies/comments.
  local args = { 'issue', 'list', '--repo', github.repo_arg(ctx), '--state', filters.state,
    '--limit', tostring(filters.limit), '--json', 'number,title,url' }
  for _, option in ipairs({ { 'labels', '--label' }, { 'assignee', '--assignee' } }) do
    local value = filters[option[1]]
    if value and value ~= '' then vim.list_extend(args, { option[2], value }) end
  end
  local result = {}
  for _, issue in ipairs(github.json(ctx, args)) do
    if not github.scalar(issue.pull_request) and #result < filters.limit then
      issue.html_url = issue.url or issue.html_url
      result[#result + 1] = issue
    end
  end
  return result
end

function M.create(ctx, text)
  local lines = vim.split(text, '\n', { plain = true })
  assert(lines[1] and vim.trim(lines[1]) ~= '', 'Issue title cannot be empty')
  assert(#lines == 1 or lines[2] == '', 'Keep a blank line between the title and body')
  local issue = github.api(ctx, 'repos/' .. ctx.repo .. '/issues', {
    title = lines[1], body = table.concat(vim.list_slice(lines, 3), '\n'),
  })
  local identity = type(issue) == 'table' and github.issue_url_context(issue.html_url)
  assert(identity and identity.repo:lower() == ctx.repo:lower() and identity.host:lower() == ctx.host:lower()
    and not github.scalar(issue.pull_request), 'Unexpected created Issue identity; check GitHub before retrying')
  ctx.number, ctx.url = identity.number, identity.url
  return issue
end
return M
