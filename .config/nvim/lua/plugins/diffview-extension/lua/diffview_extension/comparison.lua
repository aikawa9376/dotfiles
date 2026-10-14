-- Describe actual revisions; raw range labels alone can hide merge bases.
local M = {}
M.empty_tree = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'
local function clean(text) return tostring(text or ''):gsub('[\r\n\t]', ' ') end
local function revision(rev)
  if not rev then return { kind = 'unknown', label = '?' } end
  if type(rev.commit) == 'string' and rev.commit ~= '' then
    return { kind = 'commit', commit = rev.commit, label = rev.commit == M.empty_tree and 'empty tree' or rev.commit:sub(1, 7) }
  end
  if rev.type == 1 or rev.type == 'LOCAL' then return { kind = 'worktree', label = 'working tree' } end
  if rev.type == 3 or rev.type == 'STAGE' then
    return { kind = 'index', stage = rev.stage or 0, label = ({ [0] = 'index', 'base', 'ours', 'theirs' })[rev.stage or 0] or 'index' }
  end
  return { kind = 'snapshot', label = 'snapshot' }
end
function M.describe(view)
  local ctx = view and view.adapter and view.adapter.ctx
  if not ctx or not (ctx.toplevel or ctx.root) then return end
  local item = view.panel and view.panel.cur_item
  local history = item and item[1] and item[1].commit
  local entry = view.cur_entry or (item and item[2])
  local revs = entry and entry.revs
  local selected_staged = entry and entry.kind == 'staged' and revs ~= nil
  local left = revision(selected_staged and revs.a or view.left or (revs and revs.a))
  local right = revision(selected_staged and revs.b or view.right or (revs and revs.b))
  local raw = clean(view.rev_arg)
  local mode = history and 'history' or view.get_file_data and 'snapshot'
    or (right.kind == 'worktree' or left.kind == 'worktree') and 'worktree'
    or (right.kind == 'index' or left.kind == 'index') and 'index'
    or right.kind == 'commit' and (left.kind == 'unknown' and 'commit' or 'range') or 'snapshot'
  if history and history.hash and history.hash ~= 'LOCAL' then
    if right.kind ~= 'worktree' then right = revision({ commit = history.hash }) end
  end
  local a, b = raw:match('^(.-)%.%.%.(.*)$')
  local merge_base = a ~= nil
  if not a then a, b = raw:match('^(.-)%.%.(.*)$') end
  if a then
    if left.kind == 'commit' then left.label = merge_base and 'merge-base' or (a ~= '' and a or 'HEAD') end
    if right.kind == 'commit' then right.label = b ~= '' and b or 'HEAD' end
  elseif raw ~= '' then
    if right.kind ~= 'commit' and left.kind == 'commit' then left.label = raw
    elseif raw:match('%^!$') then mode = 'commit' end
  elseif left.kind == 'commit' and (selected_staged and revs.a.track_head or view.left and view.left.track_head) then left.label = 'HEAD' end
  local result = { root = ctx.toplevel or ctx.root, left = left, right = right, mode = mode,
    raw = raw, merge_base = merge_base, history = history and clean(history.subject) or nil,
    custom = view.get_file_data ~= nil, tabpage = view.tabpage,
    conflicts = view.files and view.files.conflicting and #view.files.conflicting or 0 }
  result.key = vim.json.encode({ result.root, left, right, mode, raw, result.history, result.custom, result.conflicts })
  return result
end
function M.prefix(context, metadata, counts)
  local left, right = context.left, context.right
  local tip = right.commit and metadata[right.commit]
  local hash = tip and tip.short or (right.commit and right.commit:sub(1, 7)) or ''
  if context.mode == 'commit' then return hash end
  if context.mode == 'history' then
    if right.kind == 'worktree' then return 'History · ' .. left.label .. ' → working tree' end
    return 'History · ' .. hash
  end
  local text
  if context.mode == 'range' and context.raw ~= '' then text = context.raw
  else text = left.label .. ' → ' .. right.label end
  if context.custom then text = 'Snapshot · ' .. text end
  if context.conflicts > 0 then text = text .. ' · conflicts: ' .. context.conflicts end
  if counts then
    text = text .. ' · ' .. (counts.left > 0 and ('-%d/+%d commits'):format(counts.left, counts.right)
      or ('%d commit%s'):format(counts.right, counts.right == 1 and '' or 's'))
  end
  return text
end
local function truncate(text, width)
  if width < 1 then return '' end
  if vim.fn.strdisplaywidth(text) <= width then return text end
  local length = vim.fn.strchars(text)
  while length > 0 and vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, length) .. '…') > width do length = length - 1 end
  return vim.fn.strcharpart(text, 0, length) .. '…'
end
local function compact_prefix(context, metadata, budget)
  local without_counts = M.prefix(context, metadata)
  if vim.fn.strdisplaywidth(without_counts) <= budget then return without_counts end
  local function short(side)
    if side.kind == 'commit' then
      if side.label == 'HEAD' or side.commit == M.empty_tree then return side.label end
      return metadata[side.commit] and metadata[side.commit].short or side.commit:sub(1, 7)
    end
    return side.kind == 'worktree' and 'WT' or side.label
  end
  local left, right = short(context.left), short(context.right)
  if context.mode == 'range' then
    if context.raw ~= '' and vim.fn.strdisplaywidth(context.raw) <= budget then return context.raw end
    local separator = context.merge_base and '…' or ' → '
    local available = math.max(2, budget - vim.fn.strdisplaywidth(separator))
    local left_width = math.floor(available / 2)
    return truncate(left, left_width) .. separator .. truncate(right, available - left_width)
  end
  if context.custom then return truncate('Snapshot ' .. right, budget) end
  return truncate(left .. ' → ' .. right, budget)
end
function M.format(context, metadata, counts, width)
  metadata = metadata or {}
  local prefix = M.prefix(context, metadata, counts)
  local commit = context.right.commit or context.left.commit
  local subject = context.history or (metadata[commit] and metadata[commit].subject)
  width = width or 120
  if subject and subject ~= '' then
    -- Keep the message visible even when long range labels/counts use the
    -- whole statusline budget. Full comparison details remain in the panel.
    local separator = context.mode == 'commit' and ' ' or ' · '
    local message_width = math.min(16, math.floor(width / 2), vim.fn.strdisplaywidth(clean(subject)))
    local budget = math.max(1, width - vim.fn.strdisplaywidth(separator) - message_width)
    if vim.fn.strdisplaywidth(prefix) > budget then prefix = compact_prefix(context, metadata, budget) end
    local remaining = width - vim.fn.strdisplaywidth(prefix) - vim.fn.strdisplaywidth(separator)
    return prefix .. separator .. truncate(clean(subject), remaining)
  end
  return truncate(prefix, width)
end
M.revision = revision
return M
