local M = {}
local github = require('git.features.github')
local async = require('git.features.async')
function M.load(ctx)
  ctx = vim.deepcopy(ctx)
  local pr = github.pr(ctx)
  assert(type(pr.headRefOid) == 'string' and pr.headRefOid:match('^%x+$'), 'GitHub did not return a valid PR head SHA')
  local reads = async.gather({
    function() return github.json(ctx, { 'api', '--hostname', ctx.host, '--paginate', '--slurp',
      ('repos/%s/pulls/%d/comments?per_page=100'):format(ctx.repo, ctx.number) }) end,
    function() return require('git.features.pr_thread_status').load(ctx) end,
    function() return github.api(ctx, 'user').login end,
    function()
      if type(pr.baseRefOid) ~= 'string' or not pr.baseRefOid:match('^%x+$') then return end
      local base = async.git(ctx.root, { 'merge-base', pr.baseRefOid, pr.headRefOid })
      if not base then return end
      base = vim.trim(base)
      local model = require('git.features.commit_model').changes({ root = ctx.root, base = base, hash = pr.headRefOid })
      return model
    end,
  })
  local result = { ctx = ctx, head = pr.headRefOid, threads = {}, entries = {}, errors = {}, viewer = reads[3].ok and reads[3].value or nil }
  if reads[1].ok then result.threads = require('git.features.pr_model').threads(ctx, nil, pr.headRefOid, reads[1].value)
  else result.errors[#result.errors + 1] = 'PR comments unavailable: ' .. tostring(reads[1].value) end
  if reads[2].ok then
    local status = reads[2].value
    require('git.features.pr_model').apply_thread_status(result.threads, status, pr.headRefOid)
    result.anchors_valid = status.head == pr.headRefOid
    if not result.anchors_valid then result.errors[#result.errors + 1] = 'PR head changed while reading comment anchors' end
    result.threads = vim.tbl_filter(function(thread)
      local remote = status.by_id[thread.id]
      if remote and remote.pending then return false end
      thread.projectable = result.anchors_valid and remote and remote.isOutdated == false and remote.subjectType == 'LINE'
        and remote.path == thread.path and thread.line ~= nil and (thread.side == 'LEFT' or thread.side == 'RIGHT') or false
      return true
    end, result.threads)
  else result.errors[#result.errors + 1] = 'PR comment anchors unavailable: ' .. tostring(reads[2].value) end
  if reads[4].ok and reads[4].value then
    result.base = reads[4].value.base
    for _, entry in ipairs(reads[4].value.entries) do result.entries[entry.path] = entry end
  end
  return result
end
function M.source(snapshot, path, side)
  local entry = snapshot.entries[path]
  -- A merged/advanced base can already contain the PR head. Without a
  -- matching local PR diff entry, its old LEFT coordinates are unverified.
  if side == 'LEFT' and not entry then return end
  if entry and (entry.binary or side == 'LEFT' and entry.status == 'A' or side == 'RIGHT' and entry.status == 'D') then return end
  local ref = side == 'LEFT' and snapshot.base or snapshot.head
  if not ref then return end
  local target = side == 'LEFT' and entry and (entry.old_path or path) or path
  local bytes = async.git(snapshot.ctx.root, { 'show', '--no-ext-diff', ref .. ':' .. target })
  if not bytes or #bytes > 1024 * 1024 or bytes:find('\0', 1, true) then return end
  bytes = bytes:gsub('\r\n', '\n'):gsub('\n$', '')
  return vim.split(bytes, '\n', { plain = true })
end
return M
