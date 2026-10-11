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
        repository(owner:$owner,name:$name){pullRequest(number:$number){
          reviewThreads(first:100,after:$cursor){
            nodes{id isResolved comments(first:1){nodes{fullDatabaseId pullRequestReview{state}}}}
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
    for _, thread in ipairs(connection.nodes) do
      local comment = thread.comments and thread.comments.nodes and thread.comments.nodes[1]
      assert(comment and type(thread.isResolved) == 'boolean', 'GitHub returned incomplete review thread status')
      local review = github.scalar(comment.pullRequestReview)
      if not review or review.state ~= 'PENDING' then
        result.total = result.total + 1
        if not thread.isResolved then result.unresolved = result.unresolved + 1 end
        local id = tonumber(github.scalar(comment.fullDatabaseId))
        if id then result.by_id[id] = thread end
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
return M
