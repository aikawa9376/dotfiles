-- GitHub owns pending reviews. Every write resolves the viewer and rechecks
-- the review identity and displayed head; local state is only a snapshot.
local M = {}
local github = require('git.features.github')
local function endpoint(ctx, suffix)
  return ('repos/%s/pulls/%d/%s'):format(ctx.repo, ctx.number, suffix)
end
local function pages(ctx, path)
  local result = github.json(ctx, { 'api', '--hostname', ctx.host, '--paginate', '--slurp', path .. '?per_page=100' })
  local items = {}
  for _, page in ipairs(result) do vim.list_extend(items, page) end
  return items
end
function M.load(ctx)
  local reads = require('git.features.async').gather({
    function() return github.api(ctx, 'user').login end,
    function() return pages(ctx, endpoint(ctx, 'reviews')) end,
  })
  for _, read in ipairs(reads) do if not read.ok then error(read.value, 0) end end
  local viewer, reviews = reads[1].value, reads[2].value
  assert(type(viewer) == 'string', 'Could not identify the GitHub viewer')
  local pending, submitted
  for _, review in ipairs(reviews) do
    if review.state == 'PENDING' and review.user and review.user.login == viewer then
      assert(not pending, 'Multiple pending reviews found for the viewer')
      pending = review
    elseif review.state ~= 'PENDING' and review.user and review.user.login == viewer then
      local date, previous = github.scalar(review.submitted_at) or '', submitted and github.scalar(submitted.submitted_at) or ''
      if not submitted or date > previous or (date == previous and review.id > submitted.id) then submitted = review end
    end
  end
  if pending then
    pending.body = github.scalar(pending.body) or ''
    pending.comments = pages(ctx, endpoint(ctx, 'reviews/' .. pending.id .. '/comments'))
  end
  return { viewer = viewer, pending = pending, submitted = submitted, reviews = reviews,
    migration = require('git.features.pr_review_migration').load(ctx, viewer) }
end
function M.check_head(ctx, hash, base)
  local pr = github.pr(ctx)
  if pr.headRefOid ~= hash then error('PR head changed; refresh PR status before sending. Your draft is preserved.', 0) end
  if base and pr.baseRefOid ~= base then error('PR base changed; refresh PR status before sending. Your draft is preserved.', 0) end
  return pr
end
local function current(ctx, id)
  local state = M.load(ctx)
  local pending = state.pending
  if not pending or pending.id ~= id then error('Pending review changed or was submitted; reopen the review menu. Your draft is preserved.', 0) end
  return pending, state
end
local function ready(state)
  if state.migration and state.migration.phase ~= 'planned' then
    error('Review migration needs recovery; use gr u before continuing. Your draft is preserved.', 0)
  end
end
function M.same_review(a, b, original)
  if not a or not b or a.id ~= b.id or a.commit_id ~= b.commit_id then return false end
  local function snapshot(review)
    local comments = {}
    for _, comment in ipairs(review.comments) do
      local line, start = github.scalar(comment.line), github.scalar(comment.start_line)
      if original and github.scalar(comment.original_line) then
        line, start = github.scalar(comment.original_line), github.scalar(comment.original_start_line)
      end
      comments[#comments + 1] = { comment.id, comment.body, comment.path, comment.side,
        line, start, github.scalar(comment.original_commit_id), github.scalar(comment.in_reply_to_id),
        github.scalar(comment.subject_type) }
    end
    table.sort(comments, function(x, y) return x[1] < y[1] end)
    return { review.body, comments }
  end
  return vim.deep_equal(snapshot(a), snapshot(b))
end
function M.add_thread(ctx, pending, target, body)
  local input = { pullRequestReviewId = pending.node_id, body = body, path = target.path,
    subjectType = target.line and 'LINE' or 'FILE', line = target.line, side = target.side,
    startLine = target.start_line, startSide = target.start_side }
  assert(type(input.pullRequestReviewId) == 'string', 'GitHub did not return a pending review node ID')
  local result = github.api(ctx, 'graphql', {
    query = 'mutation($input:AddPullRequestReviewThreadInput!){addPullRequestReviewThread(input:$input){thread{id}}}',
    variables = { input = input },
  })
  if result.errors and #result.errors > 0 then error(result.errors[1].message, 0) end
  assert(result.data and result.data.addPullRequestReviewThread and result.data.addPullRequestReviewThread.thread,
    'GitHub did not return the new review thread')
  return result
end
function M.migrate(ctx, hash, base, state)
  local migration = require('git.features.pr_review_migration')
  local model = migration.model(ctx, hash, base)
  local ok, result = pcall(migration.apply, ctx, model, state)
  if not ok then
    if migration.load(ctx, state.viewer) then
      error(tostring(result) .. '\nPreserved drafts are available in gr u; inspect / resume the migration there.', 0)
    end
    error(result, 0)
  end
  return result
end
function M.start(ctx, hash, base)
  M.check_head(ctx, hash, base)
  local state = M.load(ctx)
  local pending = state.pending
  ready(state)
  if pending then return pending end
  return github.api(ctx, endpoint(ctx, 'reviews'), { commit_id = hash })
end
function M.comment(ctx, hash, target, body, pending_id, base, capture_review)
  if not target then
    return github.api(ctx, ('repos/%s/issues/%d/comments'):format(ctx.repo, ctx.number), { body = body })
  end
  M.check_head(ctx, hash, base)
  if pending_id ~= false then
    local state = M.load(ctx)
    ready(state)
    local pending
    if pending_id then
      pending = state.pending
      assert(pending and pending.id == pending_id,
        'Pending review changed or was submitted; reopen the comment composer. Your draft is preserved.')
    else
      pending = M.start(ctx, hash, base)
    end
    if capture_review then capture_review(vim.deepcopy(pending)) end
    return M.add_thread(ctx, pending, target, body)
  end
  local state = M.load(ctx)
  ready(state)
  if state.pending then error('A pending review exists; add this comment to it or submit/discard it before posting a standalone diff comment.', 0) end
  return github.api(ctx, endpoint(ctx, 'comments'), vim.tbl_extend('force', target, { commit_id = hash, body = body,
    subject_type = target.line and 'line' or 'file' }))
end
local function check_comment(ctx, id, comment)
  local pending = current(ctx, id)
  local found
  for _, item in ipairs(pending.comments) do if item.id == comment.id then found = item; break end end
  if not found or found.body ~= comment.body then error('Review comment changed on GitHub; reopen it before changing it. Your draft is preserved.', 0) end
end
function M.edit(ctx, id, comment, body)
  check_comment(ctx, id, comment)
  return github.json(ctx, { 'api', '--hostname', ctx.host, '--method', 'PATCH',
    ('repos/%s/pulls/comments/%d'):format(ctx.repo, comment.id), '--input', '-' },
    { stdin = vim.json.encode({ body = body }) })
end
function M.remove(ctx, id, comment)
  check_comment(ctx, id, comment)
  return github.command(ctx, { 'api', '--hostname', ctx.host, '--method', 'DELETE',
    ('repos/%s/pulls/comments/%d'):format(ctx.repo, comment.id) })
end
function M.summary(ctx, id, original, body)
  local pending = current(ctx, id)
  if pending.body ~= original then error('Review summary changed on GitHub; reopen it before saving. Your draft is preserved.', 0) end
  return github.json(ctx, { 'api', '--hostname', ctx.host, '--method', 'PUT', endpoint(ctx, 'reviews/' .. id), '--input', '-' },
    { stdin = vim.json.encode({ body = body }) })
end
function M.submit(ctx, hash, expected, event, body, base)
  assert(vim.tbl_contains({ 'COMMENT', 'APPROVE', 'REQUEST_CHANGES' }, event), 'Invalid review event')
  M.check_head(ctx, hash, base)
  local state = M.load(ctx)
  ready(state)
  local pending = state.pending
  local id = expected and expected.id
  if (pending and pending.id or nil) ~= id then error('Pending review changed; reopen the review menu before submitting. Your draft is preserved.', 0) end
  if pending and not M.same_review(pending, expected) then error('Pending review drafts changed on GitHub; reopen the review menu before submitting. Your draft is preserved.', 0) end
  if event == 'REQUEST_CHANGES' and vim.trim(body) == '' then error('A change request needs a review summary', 0) end
  if event == 'COMMENT' and vim.trim(body) == '' and (not pending or #pending.comments == 0) then error('Write a review summary or add a draft comment first', 0) end
  if pending then
    local result = github.api(ctx, endpoint(ctx, 'reviews/' .. id .. '/events'), { event = event, body = body })
    if state.migration then
      -- Submission already succeeded. A local plan cleanup failure must not
      -- leave a composer suggesting that the remote event should be retried.
      pcall(require('git.features.pr_review_migration').clear_planned, ctx, state.viewer, id)
    end
    return result
  end
  return github.api(ctx, endpoint(ctx, 'reviews'), { commit_id = hash, event = event, body = body })
end
function M.discard(ctx, expected, preserve_migration)
  local pending, state = current(ctx, expected.id)
  if not M.same_review(pending, expected) then error('Pending review drafts changed on GitHub; reopen the review menu before discarding.', 0) end
  local result = github.json(ctx, { 'api', '--hostname', ctx.host, '--method', 'DELETE', endpoint(ctx, 'reviews/' .. expected.id) })
  if not preserve_migration then require('git.features.pr_review_migration').clear_planned(ctx, state.viewer, expected.id) end
  return result
end
return M
