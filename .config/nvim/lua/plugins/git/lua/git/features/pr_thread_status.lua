-- Resolution is GitHub thread state, independent of local read receipts.
local M = {}
local github = require('git.features.github')
function M.load(ctx)
  local owner, name = ctx.repo:match('^([^/]+)/([^/]+)$')
  local result = { total = 0, unresolved = 0, by_id = {} }
  local cursor, seen = nil, {}
  repeat
    local response = github.api(ctx, 'graphql', {
      query = [[query($owner:String!,$name:String!,$number:Int!,$cursor:String){
        repository(owner:$owner,name:$name){pullRequest(number:$number){headRefOid
          reviewThreads(first:100,after:$cursor){
            nodes{id isResolved viewerCanResolve viewerCanUnresolve isOutdated path line startLine diffSide subjectType
              comments(first:1){nodes{fullDatabaseId pullRequestReview{state}}}}
            pageInfo{hasNextPage endCursor}
          }
        }}
      }]],
      variables = { owner = owner, name = name, number = ctx.number, cursor = cursor },
    })
    if response.errors and #response.errors > 0 then error(response.errors[1].message, 0) end
    local repo = response.data and github.scalar(response.data.repository)
    local pr = repo and github.scalar(repo.pullRequest)
    local connection = pr and pr.reviewThreads
    assert(connection and type(connection.nodes) == 'table' and type(connection.pageInfo) == 'table',
      'GitHub did not return review thread status')
    local head = github.scalar(pr.headRefOid)
    assert(not result.head or not head or result.head == head, 'PR changed while loading review threads; refresh to retry')
    result.head = head or result.head
    for _, thread in ipairs(connection.nodes) do
      local comment = thread.comments and thread.comments.nodes and thread.comments.nodes[1]
      assert(comment and type(thread.isResolved) == 'boolean', 'GitHub returned incomplete review thread status')
      local review = github.scalar(comment.pullRequestReview)
      thread.pending = review and review.state == 'PENDING' or false
      local id = tonumber(github.scalar(comment.fullDatabaseId))
      if id then result.by_id[id] = thread end
      if not review or review.state ~= 'PENDING' then
        result.total = result.total + 1
        if not thread.isResolved then result.unresolved = result.unresolved + 1 end
      end
    end
    local page = connection.pageInfo
    if not page.hasNextPage then break end
    cursor = github.scalar(page.endCursor)
    assert(cursor and not seen[cursor], 'GitHub returned an invalid review thread cursor')
    seen[cursor] = true
  until false
  return result
end
function M.label(thread)
  if thread.pending then return '📝 pending', 'DiagnosticWarn' end
  if thread.resolved == true then return '✅ resolved', 'GitPrPositive' end
  if thread.resolved == false then return '💬 unresolved', 'DiagnosticInfo' end
  return '💬 status unavailable', 'Comment'
end
function M.context(ctx, threads)
  local lines = {}
  for _, thread in ipairs(threads) do
    local label = M.label(thread)
    lines[#lines + 1] = ('PR #%d · %s · %s'):format(ctx.number,
      require('git.features.pr_comment_location').format(thread, 'file / outdated'), label)
  end
  return lines
end
function M.set(ctx, thread, resolved)
  assert(not thread.pending and thread.node_id and type(thread.resolved) == 'boolean',
    'Only published threads with available resolution status can be resolved')
  -- Resolve the root again: a stale picker must never target another thread or
  -- reverse a resolution performed by another client in the meantime.
  local current = M.load(ctx).by_id[thread.id]
  assert(current and not current.pending and current.id == thread.node_id,
    'Review thread changed or disappeared; refresh to retry')
  if current.isResolved == resolved then return current end
  assert(current.isResolved == thread.resolved, 'Review thread changed; refresh to retry')
  local permission
  if resolved then permission = current.viewerCanResolve else permission = current.viewerCanUnresolve end
  assert(permission == true, 'You do not have permission to ' .. (resolved and 'resolve' or 'unresolve') .. ' this thread')
  local action = resolved and 'resolveReviewThread' or 'unresolveReviewThread'
  local input_type = resolved and 'ResolveReviewThreadInput!' or 'UnresolveReviewThreadInput!'
  local response = github.api(ctx, 'graphql', {
    query = ('mutation($input:%s){%s(input:$input){thread{id isResolved}}}'):format(input_type, action),
    variables = { input = { threadId = current.id } },
  })
  if response.errors and #response.errors > 0 then error(response.errors[1].message, 0) end
  local result = response.data and response.data[action] and response.data[action].thread
  assert(result and result.id == current.id and result.isResolved == resolved,
    'GitHub did not confirm thread resolution; refresh before retrying')
  return result
end
function M.toggle(ctx, threads)
  local choices = vim.tbl_filter(function(thread) return not thread.pending end, threads)
  if #choices == 0 then vim.notify('No published review threads here'); return end
  local function apply(thread)
    if not thread then return end
    local snapshot = vim.deepcopy(thread)
    require('git.features.github_actions').run(ctx, function(current)
      return M.set(current, snapshot, not snapshot.resolved)
    end, function()
      vim.notify(snapshot.resolved and 'Review thread reopened' or 'Review thread resolved')
    end, true)
  end
  if #choices == 1 then return apply(choices[1]) end
  vim.ui.select(choices, { prompt = 'Resolve / reopen review thread', format_item = function(thread)
    local label = M.label(thread)
    return label .. ' · ' .. require('git.features.pr_comment_location').format(thread, 'file / outdated')
      .. ' · ' .. (thread.comments[1].body or ''):gsub('[\r\n]', ' ')
  end }, apply)
end
return M
