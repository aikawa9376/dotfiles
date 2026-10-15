-- Server timeline order, not local commit author dates, places PR activity.
local M = {}
local github = require('git.features.github')
local events = require('git.features.pr_timeline_events')
local capabilities = {}
local function event_types(ctx)
  if capabilities[ctx.host] then return capabilities[ctx.host] end
  local ok, result = pcall(github.api, ctx, 'graphql', {
    query = 'query { timelineTypes:__type(name:"PullRequestTimelineItems") { possibleTypes { name fields { name } } } }', variables = {},
  })
  local data = ok and github.scalar(result.data)
  local types = data and github.scalar(data.timelineTypes)
  if type(types) ~= 'table' or type(types.possibleTypes) ~= 'table' then return events.fallback_types() end
  local fields = {}
  for _, item in ipairs(types.possibleTypes) do
    fields[item.name] = {}
    for _, field in ipairs(item.fields or {}) do fields[item.name][field.name] = true end
  end
  if not next(fields) then return events.fallback_types() end
  capabilities[ctx.host] = fields
  return fields
end
function M.query(types)
  return [[query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $name) { pullRequest(number: $number) {
    headRefOid timelineItems(first: 100, after: $cursor) {
      pageInfo { hasNextPage endCursor } nodes {
        __typename ... on Node { id }
        ... on IssueComment { id url }
        ... on PullRequestReview { id url state }
        ... on PullRequestCommit { id url commit { oid abbreviatedOid messageHeadline committedDate
          author { name user { login } } } }
        ]] .. events.fragments(types) .. [[
      }
    }
  } }
}]]
end
function M.load(ctx, hash)
  local owner, name = ctx.repo:match('^([^/]+)/([^/]+)$')
  local items, cursor, seen = {}, nil, {}
  local query = M.query(event_types(ctx))
  repeat
    local response = github.api(ctx, 'graphql', { query = query,
      variables = { owner = owner, name = name, number = ctx.number, cursor = cursor } })
    local repository = response.data and github.scalar(response.data.repository)
    local pr = repository and github.scalar(repository.pullRequest)
    local connection = type(pr) == 'table' and github.scalar(pr.timelineItems)
    if response.errors and not connection then error(response.errors[1].message or 'Timeline read failed', 0) end
    assert(type(pr) == 'table' and pr.headRefOid == hash, 'PR head changed while reading its timeline; refresh the PR')
    assert(type(connection) == 'table' and type(connection.nodes) == 'table' and type(connection.pageInfo) == 'table',
      'Invalid PR timeline response')
    assert(type(connection.pageInfo.hasNextPage) == 'boolean', 'Invalid timeline pagination state')
    for _, err in ipairs(response.errors or {}) do
      items.errors = items.errors or {}
      local message = err.message or 'Some timeline details are unavailable'
      if not vim.tbl_contains(items.errors, message) then items.errors[#items.errors + 1] = message end
    end
    for _, node in ipairs(connection.nodes) do if type(node) == 'table' then items[#items + 1] = node end end
    local next_cursor = github.scalar(connection.pageInfo.endCursor)
    if connection.pageInfo.hasNextPage then
      assert(type(next_cursor) == 'string' and not seen[next_cursor], 'Invalid or repeated timeline pagination cursor')
      seen[next_cursor], cursor = true, next_cursor
    else cursor = nil end
  until not cursor
  return items
end
local function short(commit)
  if type(commit) ~= 'table' then return '—' end
  local oid = github.scalar(commit.oid)
  return github.scalar(commit.abbreviatedOid) or (oid and oid:sub(1, 7)) or '—'
end
function M.entry(ctx, node)
  local kind = node.__typename
  if kind == 'PullRequestCommit' and type(node.commit) == 'table' then
    local commit, author = node.commit, github.scalar(node.commit.author)
    if not github.scalar(commit.oid) then return end
    local id = github.scalar(node.id) or commit.oid
    return { kind = 'commit', key = 'commit:' .. id, id = id, hash = commit.oid,
      short = short(commit), subject = github.scalar(commit.messageHeadline) or '', body = '',
      user = author and github.scalar(author.user), author_name = author and github.scalar(author.name),
      created_at = github.scalar(commit.committedDate) or '', updated_at = github.scalar(commit.committedDate) or '',
      url = github.scalar(node.url) or ('https://%s/%s/commit/%s'):format(ctx.host, ctx.repo, commit.oid) }
  else return events.entry(ctx, node) end
end
function M.apply(ctx, conversation, nodes)
  local indexed, by_key, used, ordered = {}, {}, {}, {}
  for _, entry in ipairs(conversation.entries) do
    if entry.node_id then indexed[entry.kind .. ':' .. entry.node_id] = entry end
    by_key[entry.key] = entry
  end
  for _, node in ipairs(nodes) do
    local kind = node.__typename == 'IssueComment' and 'comment' or node.__typename == 'PullRequestReview' and 'review'
    local entry = kind and indexed[kind .. ':' .. (github.scalar(node.id) or '')] or nil
    if kind and not entry then
      -- REST/GraphQL can return different generations of opaque node IDs.
      -- Public permalink anchors retain the same REST comment/review ID.
      local url = github.scalar(node.url) or ''
      local id = url:match(kind == 'comment' and '#issuecomment%-(%d+)$' or '#pullrequestreview%-(%d+)$')
      entry = id and by_key[kind .. ':' .. id] or nil
    end
    if not kind then entry = M.entry(ctx, node) end
    if entry and not used[entry.key] then
      used[entry.key] = true; ordered[#ordered + 1] = entry
    end
  end
  -- Reads can race with a newly submitted comment. Keep REST-only entries,
  -- already sorted by submission time, after the known server timeline.
  for _, entry in ipairs(conversation.entries) do if not used[entry.key] then ordered[#ordered + 1] = entry end end
  conversation.entries = ordered
  return conversation
end
function M.chunks(entry, viewer)
  local chunks = {}
  chunks[#chunks + 1] = { entry.kind == 'commit' and '● ' or entry.icon or '· ', entry.group or 'Comment' }
  local author = entry.user and github.scalar(entry.user.login)
  if author then chunks[#chunks + 1] = { '@' .. author .. ' ', author == viewer and 'GitPrCommentSelf' or 'Identifier' }
  elseif entry.author_name then chunks[#chunks + 1] = { entry.author_name .. ' ', 'Identifier' } end
  if entry.kind == 'commit' then
    chunks[#chunks + 1] = { 'committed ', 'Comment' }
    chunks[#chunks + 1] = { entry.short, require('git.features.commit_highlight').group('default') }
    chunks[#chunks + 1] = { ' ' .. entry.subject, 'Normal' }
  else vim.list_extend(chunks, entry.parts or { { entry.label, entry.group or 'Comment' } }) end
  if entry.created_at ~= '' then
    local date = entry.created_at:gsub('T', ' '):gsub('Z$', ' UTC')
    chunks[#chunks + 1] = { ' · ' .. date .. (entry.kind == 'commit' and ' (commit date)' or ''), 'Comment' }
  end
  return chunks
end
function M.is_event(entry) return entry and (entry.kind == 'event' or entry.kind == 'commit') end
return M
