-- GitHub file Viewed state; independent of comments, approvals and local reads.
local M = {}
local github = require('git.features.github')
local states = { VIEWED = true, UNVIEWED = true, DISMISSED = true }
local function checked(response)
  if response.errors and #response.errors > 0 then error(response.errors[1].message, 0) end
  return assert(github.scalar(response.data), 'GitHub did not return file viewed status')
end
function M.load(ctx)
  local owner, name = ctx.repo:match('^([^/]+)/([^/]+)$')
  local result, cursor, seen = { by_path = {} }, nil, {}
  repeat
    local data = checked(github.api(ctx, 'graphql', {
      query = [[query($owner:String!,$name:String!,$number:Int!,$cursor:String){
        viewer{login}
        repository(owner:$owner,name:$name){pullRequest(number:$number){id headRefOid baseRefOid
          files(first:100,after:$cursor){nodes{path viewerViewedState}pageInfo{hasNextPage endCursor}}
        }}
      }]],
      variables = { owner = owner, name = name, number = ctx.number, cursor = cursor },
    }))
    local repo = github.scalar(data.repository)
    local pr = repo and github.scalar(repo.pullRequest)
    local files = pr and github.scalar(pr.files)
    local viewer = data.viewer and github.scalar(data.viewer.login)
    assert(pr and pr.id and pr.headRefOid and pr.baseRefOid and viewer and files
      and type(files.nodes) == 'table' and type(files.pageInfo) == 'table', 'GitHub returned incomplete file viewed status')
    if result.id then
      assert(result.id == pr.id and result.head == pr.headRefOid and result.base == pr.baseRefOid and result.viewer == viewer,
        'PR changed while loading file viewed status; refresh to retry')
    end
    result.id, result.head, result.base, result.viewer = pr.id, pr.headRefOid, pr.baseRefOid, viewer
    for _, file in ipairs(files.nodes) do
      assert(type(file.path) == 'string' and states[file.viewerViewedState] and not result.by_path[file.path],
        'GitHub returned invalid file viewed status')
      result.by_path[file.path] = file.viewerViewedState
    end
    local page = files.pageInfo
    assert(type(page.hasNextPage) == 'boolean', 'GitHub returned incomplete file pagination')
    if not page.hasNextPage then break end
    cursor = github.scalar(page.endCursor)
    assert(cursor and not seen[cursor], 'GitHub returned an invalid file cursor')
    seen[cursor] = true
  until false
  return result
end
function M.apply(model, status)
  assert(status.head == model.hash and status.base == model.pr.baseRefOid,
    'PR changed while loading file viewed status; refresh to retry')
  assert(not model.review or not model.review.viewer or model.review.viewer == status.viewer,
    'Viewer changed while loading file viewed status; refresh to retry')
  for _, entry in ipairs(model.entries) do
    assert(states[status.by_path[entry.path]], 'GitHub did not return viewed status for ' .. entry.path)
  end
  model.viewed, model.viewed_error = status, nil
  for _, entry in ipairs(model.entries) do entry.viewed_state = status.by_path[entry.path] end
end
function M.unviewed(entry)
  return entry.viewed_state == 'UNVIEWED' or entry.viewed_state == 'DISMISSED'
end
function M.set(ctx, snapshot, path)
  local state = snapshot.by_path[path]
  assert(states[state], 'File viewed status unavailable; refresh to retry')
  local desired = state == 'VIEWED' and 'UNVIEWED' or 'VIEWED'
  local current = M.load(ctx)
  local function same(status)
    assert(status.id == snapshot.id and status.head == snapshot.head and status.base == snapshot.base
      and status.viewer == snapshot.viewer, 'PR or viewer changed; refresh before marking files')
  end
  same(current)
  if current.by_path[path] == desired then return current end
  assert(current.by_path[path] == state, 'File viewed status changed; refresh to retry')
  local action = desired == 'VIEWED' and 'markFileAsViewed' or 'unmarkFileAsViewed'
  local input_type = desired == 'VIEWED' and 'MarkFileAsViewedInput!' or 'UnmarkFileAsViewedInput!'
  local data = checked(github.api(ctx, 'graphql', {
    query = ('mutation($input:%s){%s(input:$input){pullRequest{id headRefOid baseRefOid}}}'):format(input_type, action),
    variables = { input = { pullRequestId = current.id, path = path } },
  }))
  local pr = data[action] and github.scalar(data[action].pullRequest)
  assert(pr and pr.id == current.id and pr.headRefOid == current.head and pr.baseRefOid == current.base,
    'GitHub did not confirm this PR revision; refresh before retrying')
  local confirmed = M.load(ctx)
  same(confirmed)
  assert(confirmed.by_path[path] == desired, 'GitHub did not confirm file viewed status; refresh before retrying')
  return confirmed
end
return M
