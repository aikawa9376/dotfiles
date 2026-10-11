-- Rebuild a pending review on the current head. Keep a durable copy before
-- deleting anything remotely, and reconcile remote state after uncertain writes.
local M = {}
local github = require('git.features.github')
local changes = require('git.features.commit_model')
local uv = vim.uv
local function location(ctx, viewer)
  local dir = vim.fn.stdpath('state') .. '/git-pr-review-migrations'
  return dir, dir .. '/' .. vim.fn.sha256(ctx.host .. '/' .. ctx.repo .. '/' .. ctx.number .. '/' .. viewer) .. '.json'
end
local function read(path)
  if vim.fn.filereadable(path) == 0 then return nil end
  local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), '\n'))
  assert(ok and type(data) == 'table', 'Could not read the preserved review migration: ' .. path)
  return data
end
function M.load(ctx, viewer)
  local _, path = location(ctx, viewer)
  return read(path)
end
local function write(path, data)
  local tmp = path .. '.' .. tostring(uv.hrtime())
  local body = vim.json.encode(data)
  local fd = assert(uv.fs_open(tmp, 'wx', 384))
  local ok, err = pcall(function()
    assert(uv.fs_write(fd, body, 0) == #body)
    assert(uv.fs_fsync(fd))
  end)
  uv.fs_close(fd)
  if not ok then uv.fs_unlink(tmp); error(err, 0) end
  assert(uv.fs_rename(tmp, path))
end
local function locked(ctx, viewer, fn)
  local dir, path = location(ctx, viewer)
  vim.fn.mkdir(dir, 'p', 448)
  local lock = path .. '.lock'
  local fd = uv.fs_open(lock, 'wx', 384)
  if not fd then
    local owner = read(lock)
    if owner and type(owner.pid) == 'number' then
      local alive, _, code = uv.kill(owner.pid, 0)
      if not alive and code ~= 'EPERM' then uv.fs_unlink(lock); fd = uv.fs_open(lock, 'wx', 384) end
    end
  end
  assert(fd, 'Another review migration is running; retry after it finishes')
  uv.fs_write(fd, vim.json.encode({ pid = uv.os_getpid() }), 0); uv.fs_close(fd)
  local ok, result = pcall(fn, path)
  uv.fs_unlink(lock)
  if not ok then error(result, 0) end
  return result
end
local function git(model, args)
  return changes.git(model.root, args)
end
local function blob(model, hash, path)
  if type(hash) ~= 'string' or not hash:match('^%x+$') then return nil end
  return git(model, { 'show', hash .. ':' .. path })
end
local function lines(text) return changes.lines(text) end
-- Only unchanged ranges move automatically. Insertions within a multi-line
-- range and any replaced/deleted target line require explicit reattachment.
function M.map_lines(old, new, first, last)
  local old_lines, new_lines = lines(old), lines(new)
  if first < 1 or last < first or last > #old_lines then return nil end
  if old == new then return first, last end
  local offset = 0
  for _, hunk in ipairs(vim.diff(old, new, { result_type = 'indices', algorithm = 'histogram' })) do
    local start, count, added = hunk[1], hunk[2], hunk[4]
    if count == 0 then
      if first <= start and start < last then return nil end
      if start < first then offset = offset + added end
    elseif start <= last and start + count - 1 >= first then return nil
    elseif start + count - 1 < first then offset = offset + added - count end
  end
  local a, b = first + offset, last + offset
  -- Neighbouring context must also survive and identify one location. This
  -- refuses ambiguous repeated blocks even if the diff algorithm chose one.
  local before, after = math.min(2, first - 1), math.min(2, #old_lines - last)
  local snippet = vim.list_slice(old_lines, first - before, last + after)
  local matches = {}
  for at = 1, #new_lines - #snippet + 1 do
    if vim.deep_equal(snippet, vim.list_slice(new_lines, at, at + #snippet - 1)) then matches[#matches + 1] = at + before end
  end
  if #matches ~= 1 or matches[1] ~= a or b > #new_lines then return nil end
  return a, b
end
local function hunk_source(comment, first, last, side)
  local patch = vim.split(github.scalar(comment.diff_hunk) or '', '\n', { plain = true })
  local coordinates = require('git.features.pr_model').coordinates(patch)
  local found = {}
  for row, coordinate in pairs(coordinates) do
    local number = coordinate[side == 'LEFT' and 'left' or 'right']
    if number then found[number] = patch[row]:sub(2) end
  end
  for number = first, last do if found[number] == nil then return nil end end
  local a, b = first, last
  for _ = 1, 2 do if found[a - 1] ~= nil then a = a - 1 end; if found[b + 1] ~= nil then b = b + 1 end end
  local snippet = {}
  for number = a, b do snippet[#snippet + 1] = found[number] end
  return snippet, first - a
end
local function from_hunk(comment, text, first, last, side)
  local snippet, before = hunk_source(comment, first, last, side)
  if not snippet then return nil end
  local content, matches = lines(text), {}
  for at = 1, #content - #snippet + 1 do
    if vim.deep_equal(snippet, vim.list_slice(content, at, at + #snippet - 1)) then matches[#matches + 1] = at + before end
  end
  if #matches == 1 then return matches[1], matches[1] + last - first end
end
local function entry_for(model, path, revision)
  for _, entry in ipairs(model.entries) do if entry.path == path or entry.old_path == path then return entry end end
  if revision and revision:match('^%x+$') then
    local diff = git(model, { 'diff', '--name-status', '-z', '--find-renames', '--no-ext-diff', revision, model.hash, '--' })
    local fields, i = vim.split(diff or '', '\0', { plain = true, trimempty = true }), 1
    while i <= #fields do
      local status, previous = fields[i], fields[i + 1]
      if status:sub(1, 1) == 'R' then
        if previous == path then for _, entry in ipairs(model.entries) do if entry.path == fields[i + 2] then return entry end end end
        i = i + 3
      else i = i + 2 end
    end
  end
end
function M.valid_target(model, target)
  local entry = entry_for(model, target.path)
  if not entry or entry.path ~= target.path then return false end
  if not target.line then return true end
  if not vim.tbl_contains({ 'LEFT', 'RIGHT' }, target.side) then return false end
  local patch = changes.patch(model, entry)
  if not patch then return false end
  local available = {}
  for _, coordinate in pairs(require('git.features.pr_model').coordinates(patch)) do
    local number = coordinate[target.side == 'LEFT' and 'left' or 'right']
    if number then available[number] = true end
  end
  for at = target.start_line or target.line, target.line do if not available[at] then return false end end
  return true
end
local function anchor(model, pending, comment)
  if github.scalar(comment.in_reply_to_id) then return nil, 'Reply draft: choose a new thread explicitly' end
  local revision = github.scalar(comment.original_commit_id) or github.scalar(comment.commit_id) or pending.commit_id
  local entry = entry_for(model, comment.path, revision)
  if not entry then return nil, 'File removed or rename cannot be identified' end
  local finish = github.scalar(comment.original_line) or github.scalar(comment.line)
  if not finish then
    if comment.subject_type == 'file' or comment.subject_type == 'FILE' then return { path = entry.path } end
    return nil, 'Original line unavailable; choose the target again'
  end
  local first = github.scalar(comment.original_start_line) or github.scalar(comment.start_line) or finish
  local side = comment.side or 'RIGHT'
  local old_revision = revision
  if side == 'LEFT' and revision and revision:match('^%x+$') then
    local base = git(model, { 'merge-base', revision, model.pr.baseRefOid })
    old_revision = base and vim.trim(base)
  end
  local path = side == 'LEFT' and (entry.old_path or entry.path) or entry.path
  local new = blob(model, side == 'LEFT' and model.base or model.hash, path)
  if not new then return nil, 'Target file no longer exists on this diff side' end
  local old = blob(model, old_revision, comment.path)
  if old and github.scalar(comment.diff_hunk) then
    local snippet, before = hunk_source(comment, first, finish, side)
    if snippet and not vim.deep_equal(snippet, vim.list_slice(lines(old), first - before, first - before + #snippet - 1)) then old = nil end
  end
  local a, b
  if old then a, b = M.map_lines(old, new, first, finish) end
  if not old then a, b = from_hunk(comment, new, first, finish, side) end
  if not a then return nil, 'Target code changed, was removed, or has ambiguous matching context' end
  local target = { path = entry.path, side = side, line = b,
    start_line = a ~= b and a or nil, start_side = a ~= b and side or nil }
  if not M.valid_target(model, target) then return nil, 'Target is no longer part of the PR diff' end
  return target
end
local function plan(model, state)
  local pending = assert(state.pending, 'No pending review to migrate')
  local result = { version = 1, source = vim.deepcopy(pending), viewer = state.viewer,
    hash = model.hash, base = model.pr.baseRefOid, phase = 'planned', items = {},
    token = vim.fn.sha256(tostring(uv.hrtime()) .. tostring(uv.os_getpid())):sub(1, 24) }
  for _, comment in ipairs(pending.comments) do
    local target, reason = anchor(model, pending, comment)
    result.items[#result.items + 1] = { comment = vim.deepcopy(comment), target = target, reason = reason }
  end
  return result
end
local marker, reconcile
local function retarget(model, state, saved)
  local api = require('git.features.pr_review_model')
  local live = state.pending
  if live and live.id == saved.source.id then
    assert(api.same_review(saved.source, live, true), 'Original review changed externally; preserved migration needs inspection')
  elseif live then
    assert((live.id == saved.replacement_id or live.body == marker(saved)) and live.commit_id == saved.hash,
      'A different pending review exists; preserved migration will not adopt it')
    assert(live.body == marker(saved) or live.body == (saved.summary or saved.source.body),
      'Replacement summary changed externally; preserved migration needs inspection')
    reconcile(saved, live, true)
  else
    for _, review in ipairs(state.reviews) do
      assert(review.id ~= saved.source.id and review.id ~= saved.replacement_id,
        'A migration review was submitted externally; preserved drafts need inspection')
    end
  end
  -- Use every preserved draft, including threads not yet copied remotely.
  local payload = { id = saved.source.id, commit_id = saved.hash,
    body = saved.summary or saved.source.body, comments = {} }
  for _, item in ipairs(saved.items) do
    local comment = vim.deepcopy(item.comment)
    if item.target then
      local at = item.target
      comment.path, comment.side = at.path, at.side
      comment.line, comment.original_line = at.line, at.line
      comment.start_line, comment.original_start_line = at.start_line, at.start_line
      comment.commit_id, comment.original_commit_id = saved.hash, saved.hash
      comment.subject_type = at.line and 'line' or 'file'
      comment.diff_hunk, comment.in_reply_to_id = nil, nil
    end
    payload.comments[#payload.comments + 1] = comment
  end
  local result = plan(model, { viewer = state.viewer, pending = payload })
  result.summary, result.source = payload.body, vim.deepcopy(live or saved.source)
  if not live then result.phase = 'creating' end
  return result
end
local function prepare(ctx, model, state, path)
  local saved = read(path)
  if saved and (saved.hash ~= model.hash or saved.base ~= model.pr.baseRefOid)
    and (saved.phase ~= 'planned' or require('git.features.pr_review_model').same_review(saved.source, state.pending, true)) then
    local result = retarget(model, state, saved)
    write(path, result)
    return result
  end
  if saved and saved.phase ~= 'planned' then return saved end
  if saved and saved.hash == model.hash and saved.base == model.pr.baseRefOid
    and require('git.features.pr_review_model').same_review(saved.source, state.pending) then return saved end
  local result = plan(model, state)
  write(path, result)
  return result
end
marker = function(result)
  return (result.summary or result.source.body) .. '\n\n<!-- nvim-review-migration:' .. result.token .. ' -->'
end
reconcile = function(result, pending, original)
  local used, matched = {}, {}
  for i, item in ipairs(result.items) do
    for _, comment in ipairs(pending.comments) do
      local target = item.target
      local line, start = github.scalar(comment.line), github.scalar(comment.start_line)
      if original and comment.original_commit_id == result.hash then
        line, start = github.scalar(comment.original_line), github.scalar(comment.original_start_line)
      end
      if target and not used[comment.id] and comment.body == item.comment.body and comment.path == target.path
        and line == target.line
        and (not target.line or (comment.side == target.side and start == target.start_line)) then
        used[comment.id], matched[i] = true, comment.id
        break
      end
    end
  end
  for _, comment in ipairs(pending.comments) do assert(used[comment.id], 'Replacement review changed externally; preserved migration needs inspection in gr u') end
  return matched
end
function M.apply(ctx, model, state)
  local api = require('git.features.pr_review_model')
  return locked(ctx, state.viewer, function(path)
    local result = prepare(ctx, model, state, path)
    assert(result.hash == model.hash and result.base == model.pr.baseRefOid,
      'PR changed during migration recovery; preserved drafts are available in gr u')
    if M.remaining(result) > 0 then
      error(('Pending review targets an older PR head; %d draft(s) need reattachment via gr u / gC m. All drafts are preserved.'):format(M.remaining(result)), 0)
    end
    api.check_head(ctx, model.hash, model.pr.baseRefOid)
    if result.phase == 'planned' then
      assert(api.same_review(result.source, state.pending), 'Pending review changed; reopen migration before continuing')
      result.phase = 'deleting'; write(path, result)
    end
    local live = api.load(ctx)
    assert(live.viewer == result.viewer, 'GitHub account changed during migration')
    if result.phase == 'deleting' then
      if live.pending and live.pending.id == result.source.id then
        assert(api.same_review(result.source, live.pending), 'Pending review changed; its drafts and migration are preserved')
        api.discard(ctx, live.pending, true)
      else
        for _, review in ipairs(live.reviews) do
          assert(review.id ~= result.source.id, 'Original review was submitted externally; migration stopped without creating another review')
        end
        assert(not live.pending, 'A different pending review exists; migration recovery will not replace it')
      end
      result.phase = 'creating'; write(path, result)
    end
    live = api.load(ctx)
    if result.phase == 'creating' then
      if not live.pending then
        api.check_head(ctx, model.hash, model.pr.baseRefOid)
        local review = github.api(ctx, ('repos/%s/pulls/%d/reviews'):format(ctx.repo, ctx.number),
          { commit_id = model.hash, body = marker(result) })
        result.replacement_id = review.id
      else
        assert(live.pending.commit_id == model.hash and live.pending.body == marker(result),
          'A different pending review exists; preserved migration will not adopt it')
        result.replacement_id = live.pending.id
      end
      result.phase = 'copying'; write(path, result)
    end
    local function replacement()
      api.check_head(ctx, model.hash, model.pr.baseRefOid)
      local pending = api.load(ctx).pending
      assert(pending and pending.id == result.replacement_id and pending.commit_id == model.hash,
        'Replacement review changed; preserved migration needs recovery in gr u')
      assert(pending.body == marker(result) or ((result.phase == 'finishing' or result.phase == 'done')
        and pending.body == (result.summary or result.source.body)), 'Replacement review summary changed externally; preserved migration needs inspection')
      return pending
    end
    if result.phase == 'copying' then
      for i, item in ipairs(result.items) do
        local pending = replacement()
        local matched = reconcile(result, pending)
        if not matched[i] then api.add_thread(ctx, pending, item.target, item.comment.body) end
        -- Re-read on retry rather than trusting a possibly lost mutation response.
      end
      result.phase = 'finishing'; write(path, result)
    end
    local pending = replacement()
    local matched = reconcile(result, pending)
    for i in ipairs(result.items) do assert(matched[i], 'Review migration is incomplete; retry via gr u') end
    local summary = result.summary or result.source.body
    if pending.body ~= summary then api.summary(ctx, pending.id, pending.body, summary) end
    pending = replacement()
    assert(pending.body == summary, 'Review summary migration is incomplete; retry via gr u')
    result.phase = 'done'; write(path, result)
    assert(uv.fs_unlink(path))
    return pending
  end)
end
function M.prepare(ctx, model, state)
  return locked(ctx, state.viewer, function(path) return prepare(ctx, model, state, path) end)
end
function M.attach(ctx, model, state, id, target)
  assert(M.valid_target(model, target), 'Choose a valid current PR diff target')
  return locked(ctx, state.viewer, function(path)
    local result = prepare(ctx, model, state, path)
    assert(result.phase == 'planned' or (result.phase == 'creating' and not state.pending),
      'Finish migration recovery before changing anchors')
    local item
    for _, candidate in ipairs(result.items) do if candidate.comment.id == id then item = candidate end end
    assert(item, 'Draft changed; reopen migration before reattaching')
    item.target, item.reason = vim.deepcopy(target), nil
    write(path, result)
    return result
  end)
end
function M.remaining(result)
  local count = 0
  for _, item in ipairs(result.items) do if not item.target then count = count + 1 end end
  return count
end
function M.clear_planned(ctx, viewer, id)
  return locked(ctx, viewer, function(path)
    local saved = read(path)
    if saved and saved.phase == 'planned' and saved.source.id == id then assert(uv.fs_unlink(path)) end
  end)
end
function M.model(ctx, hash, base)
  local pr = require('git.features.pr_review_model').check_head(ctx, hash, base)
  local merge_base, head = require('git.features.pr_model').fetch(ctx, pr)
  return assert(changes.changes({ ctx = ctx, root = ctx.root, pr = pr, base = merge_base, hash = head }))
end
return M
