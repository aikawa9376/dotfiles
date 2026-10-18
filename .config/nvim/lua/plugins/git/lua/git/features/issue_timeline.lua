-- Small Issue timeline, checked against GitHub's IssueTimelineItems schema.
-- https://docs.github.com/en/graphql/reference/issues
local M = {}
local github = require('git.features.github')
M.query = [[query($owner:String!, $name:String!, $number:Int!, $cursor:String) {
  repository(owner:$owner, name:$name) { issue(number:$number) {
    number timelineItems(first:100, after:$cursor, itemTypes:[ISSUE_COMMENT,CLOSED_EVENT,REOPENED_EVENT,
      LABELED_EVENT,UNLABELED_EVENT,ASSIGNED_EVENT,UNASSIGNED_EVENT]) {
      pageInfo { hasNextPage endCursor } nodes {
        __typename ... on Node { id }
        ... on IssueComment { url }
        ... on ClosedEvent { createdAt actor { login } }
        ... on ReopenedEvent { createdAt actor { login } }
        ... on LabeledEvent { createdAt actor { login } label { name } }
        ... on UnlabeledEvent { createdAt actor { login } label { name } }
        ... on AssignedEvent { createdAt actor { login } assignee { ... on Actor { login } } }
        ... on UnassignedEvent { createdAt actor { login } assignee { ... on Actor { login } } }
      }
    }
  } }
}]]
function M.load(ctx)
  local owner, name = ctx.repo:match('^([^/]+)/([^/]+)$')
  local items, cursor, seen = {}, nil, {}
  repeat
    local response = github.api(ctx, 'graphql', { query = M.query,
      variables = { owner = owner, name = name, number = ctx.number, cursor = cursor } })
    local repo = response.data and github.scalar(response.data.repository)
    local issue = repo and github.scalar(repo.issue)
    local connection = type(issue) == 'table' and github.scalar(issue.timelineItems)
    assert(type(issue) == 'table' and issue.number == ctx.number and type(connection) == 'table'
      and type(connection.nodes) == 'table' and type(connection.pageInfo) == 'table', 'Issue timeline unavailable')
    for _, err in ipairs(response.errors or {}) do
      items.errors = items.errors or {}; items.errors[#items.errors + 1] = err.message or 'Partial Issue timeline'
    end
    for _, node in ipairs(connection.nodes) do if type(node) == 'table' then items[#items + 1] = node end end
    local page, next_cursor = connection.pageInfo, github.scalar(connection.pageInfo.endCursor)
    assert(type(page.hasNextPage) == 'boolean', 'Invalid Issue timeline pagination')
    if page.hasNextPage then
      assert(type(next_cursor) == 'string' and not seen[next_cursor], 'Invalid or repeated Issue timeline cursor')
      seen[next_cursor], cursor = true, next_cursor
    else cursor = nil end
  until not cursor
  return items
end
function M.apply(ctx, conversation, nodes)
  -- The shared normalizer deduplicates REST comments by node/permalink identity
  -- and preserves canonical API ordering, including comments arriving mid-read.
  require('git.features.pr_timeline').apply(ctx, conversation, nodes)
  for _, err in ipairs(nodes.errors or {}) do conversation.errors[#conversation.errors + 1] = 'Issue activity: ' .. err end
  return conversation
end
return M
