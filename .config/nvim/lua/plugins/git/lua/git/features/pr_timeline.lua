-- Server timeline order, not local commit author dates, places PR activity.
local M = {}
local github = require('git.features.github')
local query = [[query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $name) { pullRequest(number: $number) {
    headRefOid timelineItems(first: 100, after: $cursor, itemTypes: [ISSUE_COMMENT, PULL_REQUEST_REVIEW,
      PULL_REQUEST_COMMIT, HEAD_REF_FORCE_PUSHED_EVENT, MERGED_EVENT, CLOSED_EVENT, REOPENED_EVENT,
      READY_FOR_REVIEW_EVENT, CONVERT_TO_DRAFT_EVENT, HEAD_REF_DELETED_EVENT, HEAD_REF_RESTORED_EVENT]) {
      pageInfo { hasNextPage endCursor } nodes {
        __typename
        ... on IssueComment { id url }
        ... on PullRequestReview { id url state }
        ... on PullRequestCommit { id url commit { oid abbreviatedOid messageHeadline committedDate
          author { name user { login } } } }
        ... on HeadRefForcePushedEvent { id createdAt actor { login }
          beforeCommit { oid abbreviatedOid } afterCommit { oid abbreviatedOid } }
        ... on MergedEvent { id createdAt actor { login } commit { oid abbreviatedOid url } }
        ... on ClosedEvent { id createdAt actor { login } }
        ... on ReopenedEvent { id createdAt actor { login } }
        ... on ReadyForReviewEvent { id createdAt actor { login } }
        ... on ConvertToDraftEvent { id createdAt actor { login } }
        ... on HeadRefDeletedEvent { id createdAt actor { login } headRefName }
        ... on HeadRefRestoredEvent { id createdAt actor { login } }
      }
    }
  } }
}]]
function M.load(ctx, hash)
  local owner, name = ctx.repo:match('^([^/]+)/([^/]+)$')
  local items, cursor, seen = {}, nil, {}
  repeat
    local response = github.api(ctx, 'graphql', { query = query,
      variables = { owner = owner, name = name, number = ctx.number, cursor = cursor } })
    if response.errors then error(response.errors[1].message or 'Timeline read failed', 0) end
    local pr = response.data and response.data.repository and response.data.repository.pullRequest
    assert(type(pr) == 'table' and pr.headRefOid == hash, 'PR head changed while reading its timeline; refresh the PR')
    local connection = pr.timelineItems
    assert(type(connection) == 'table' and type(connection.nodes) == 'table' and type(connection.pageInfo) == 'table',
      'Invalid PR timeline response')
    assert(type(connection.pageInfo.hasNextPage) == 'boolean', 'Invalid timeline pagination state')
    for _, node in ipairs(connection.nodes) do if type(node) == 'table' then items[#items + 1] = node end end
    local next_cursor = github.scalar(connection.pageInfo.endCursor)
    if connection.pageInfo.hasNextPage then
      assert(type(next_cursor) == 'string' and not seen[next_cursor], 'Invalid or repeated timeline pagination cursor')
      seen[next_cursor], cursor = true, next_cursor
    else cursor = nil end
  until not cursor
  return items
end
local labels = { HeadRefForcePushedEvent = 'force-pushed', MergedEvent = 'merged', ClosedEvent = 'closed the PR',
  ReopenedEvent = 'reopened the PR', ReadyForReviewEvent = 'marked ready for review',
  ConvertToDraftEvent = 'converted to draft', HeadRefDeletedEvent = 'deleted the head branch',
  HeadRefRestoredEvent = 'restored the head branch' }
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
  elseif labels[kind] and github.scalar(node.id) then
    local detail = ''
    if kind == 'HeadRefForcePushedEvent' then detail = ' ' .. short(node.beforeCommit) .. ' → ' .. short(node.afterCommit)
    elseif kind == 'MergedEvent' and type(node.commit) == 'table' then detail = ' ' .. short(node.commit)
    elseif kind == 'HeadRefDeletedEvent' and github.scalar(node.headRefName) then detail = ' ' .. node.headRefName end
    return { kind = 'event', key = 'event:' .. node.id, id = node.id, event_type = kind,
      label = labels[kind] .. detail, body = '', user = github.scalar(node.actor),
      created_at = github.scalar(node.createdAt) or '', updated_at = github.scalar(node.createdAt) or '',
      url = kind == 'MergedEvent' and type(node.commit) == 'table' and github.scalar(node.commit.url) or ctx.url }
  end
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
  local chunks, kind = {}, entry.event_type
  local group = 'Comment'
  if kind == 'MergedEvent' or kind == 'ReopenedEvent' or kind == 'ReadyForReviewEvent' then group = 'GitPrPositive' end
  if kind == 'HeadRefForcePushedEvent' or kind == 'ConvertToDraftEvent' then group = 'DiagnosticWarn' end
  chunks[#chunks + 1] = { entry.kind == 'commit' and '● ' or kind == 'HeadRefForcePushedEvent' and '↻ ' or kind == 'MergedEvent' and '✓ ' or '· ', group }
  local author = entry.user and github.scalar(entry.user.login)
  if author then chunks[#chunks + 1] = { '@' .. author .. ' ', author == viewer and 'GitPrCommentSelf' or 'Identifier' }
  elseif entry.author_name then chunks[#chunks + 1] = { entry.author_name .. ' ', 'Identifier' } end
  if entry.kind == 'commit' then
    chunks[#chunks + 1] = { 'committed ', 'Comment' }
    chunks[#chunks + 1] = { entry.short, require('git.features.commit_highlight').group('default') }
    chunks[#chunks + 1] = { ' ' .. entry.subject, 'Normal' }
  else chunks[#chunks + 1] = { entry.label, group } end
  if entry.created_at ~= '' then
    local date = entry.created_at:gsub('T', ' '):gsub('Z$', ' UTC')
    chunks[#chunks + 1] = { ' · ' .. date .. (entry.kind == 'commit' and ' (commit date)' or ''), 'Comment' }
  end
  return chunks
end
function M.is_event(entry) return entry and (entry.kind == 'event' or entry.kind == 'commit') end
return M
