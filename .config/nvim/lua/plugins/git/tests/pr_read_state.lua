local script = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local plugin = vim.fs.dirname(vim.fs.dirname(script))
package.path = plugin .. '/lua/?.lua;' .. package.path
local reads = require('git.features.pr_read_state')
local ctx = { host = 'github.example.test', repo = 'Org/Repo', number = 7, root = '/tmp/source-worktree' }
local viewer = 'viewer'
local comments = {
  { id = 1, body = 'Same body', updated_at = '2026-10-15T00:00:00Z', user = { login = 'other' } },
  { id = 1, key = 'comment:1', kind = 'comment', body = 'Issue body', user = { login = 'other' } },
  { id = 1, key = 'review:1', kind = 'review', body = 'Review body', updated_at = '2026-10-15T01:00:00Z',
    review_state = 'APPROVED', user = { login = 'other' } },
}
local function receipt(comment)
  local owner = vim.fn.sha256(table.concat({ ctx.host, ctx.repo, ctx.number, viewer }, '/'))
  return vim.fn.stdpath('state') .. '/git-pr-comment-reads/' .. owner .. '/' .. vim.fn.sha256(comment.key or tostring(comment.id))
end
local legacy = {}
local old_fields = { '"body":"Legacy body"', '"updated_at":"2026-10-15T02:00:00Z"', '"review_state":"APPROVED"' }
for _, order in ipairs({ { 1, 2 }, { 2, 1 }, { 1, 2, 3 }, { 1, 3, 2 }, { 2, 1, 3 }, { 2, 3, 1 }, { 3, 1, 2 }, { 3, 2, 1 } }) do
  local id = 100 + #legacy
  local comment = { id = id, body = 'Legacy body', updated_at = '2026-10-15T02:00:00Z', user = { login = 'other' } }
  if #order == 3 then comment.kind, comment.key, comment.review_state = 'review', 'review:' .. id, 'APPROVED' end
  local fields = {}; for _, index in ipairs(order) do fields[#fields + 1] = old_fields[index] end
  legacy[#legacy + 1] = { comment = comment, saved = vim.fn.sha256('{' .. table.concat(fields, ',') .. '}') }
end
if vim.env.NVIM_GIT_READ_PHASE == 'write' then
  reads.mark(ctx, viewer, comments)
  for _, item in ipairs(legacy) do vim.fn.writefile({ item.saved }, receipt(item.comment)) end
  return
elseif vim.env.NVIM_GIT_READ_PHASE == 'read' then
  ctx.root = '/tmp/another-worktree'
  for _, comment in ipairs(comments) do
    local expected = 'v2:' .. vim.fn.sha256(vim.json.encode({ comment.body, comment.updated_at or vim.NIL, comment.review_state or vim.NIL }))
    assert(vim.fn.readfile(receipt(comment))[1] == expected, 'Receipt serialization is not positional/versioned')
    assert(not reads.unread_entries(ctx, viewer, { comment })[comment.key or comment.id], 'Read state did not survive a new Neovim process')
  end
  for _, item in ipairs(legacy) do
    local comment = item.comment
    assert(not reads.unread_entries(ctx, viewer, { comment })[comment.key or comment.id], 'A historical object order reset read state')
    local original = comment.body
    comment.body = 'Actually edited'
    assert(reads.unread_entries(ctx, viewer, { comment })[comment.key or comment.id], 'Legacy compatibility hid a real body edit')
    comment.body = original
  end
  local review = vim.deepcopy(comments[3]); review.review_state = 'DISMISSED'
  assert(reads.unread_entries(ctx, viewer, { review })[review.key], 'Stable receipts hid a changed review result')
  local edited = vim.deepcopy(comments[1]); edited.updated_at = '2026-10-16T00:00:00Z'
  assert(reads.unread(ctx, viewer, { { comments = { edited } } })[1], 'Stable receipts hid an updated comment')
  local fresh = vim.deepcopy(comments[1]); fresh.id = 2
  assert(reads.unread(ctx, viewer, { { comments = { fresh } } })[2], 'A new reply inherited another receipt')
  return
end
local function restart(phase)
  local result = vim.system({ vim.v.progpath, '--headless', '--clean', '-u', 'NONE', '-i', 'NONE', '-l', script }, {
    text = true, env = { NVIM_GIT_READ_PHASE = phase },
  }):wait()
  assert(result.code == 0, (result.stdout or '') .. (result.stderr or ''))
end
restart('write'); restart('read'); restart('read')
print('PASS: actual Neovim restart/worktree persistence, canonical receipts, all legacy object orders, typed identities and real edit/review/new-reply detection')
