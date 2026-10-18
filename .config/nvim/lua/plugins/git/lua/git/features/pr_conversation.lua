-- PR-wide comments/public summaries interleaved with server timeline activity.
local M = {}
local github = require('git.features.github')
function M.load(ctx)
  local pages = github.json(ctx, { 'api', '--hostname', ctx.host, '--paginate', '--slurp',
    ('repos/%s/issues/%d/comments?per_page=100'):format(ctx.repo, ctx.number) })
  local comments = {}
  for _, page in ipairs(pages) do vim.list_extend(comments, page) end
  return comments
end
function M.build(ctx, comments, reviews, errors, timeline)
  local result, indexed = { entries = {}, errors = errors or {} }, {}
  local function add(kind, source)
    local id = github.scalar(source.id)
    if not id then return end
    local key = kind .. ':' .. tostring(id)
    local date = github.scalar(kind == 'review' and source.submitted_at or source.created_at) or ''
    local updated = github.scalar(source.updated_at) or date
    local entry = { key = key, id = id, kind = kind, user = source.user, created_at = date, updated_at = updated,
      node_id = github.scalar(source.node_id),
      body = github.scalar(source.body) or '', review_state = kind == 'review' and source.state or nil,
      reactions = github.scalar(source.reactions),
      url = github.scalar(source.html_url) or ctx.url .. (kind == 'review' and '#pullrequestreview-' or '#issuecomment-') .. id }
    if not indexed[key] or updated >= indexed[key].updated_at then indexed[key] = entry end
  end
  for _, comment in ipairs(comments or {}) do add('comment', comment) end
  for _, review in ipairs(reviews or {}) do
    local body = github.scalar(review.body)
    if review.state ~= 'PENDING' and ((body and vim.trim(body) ~= '') or review.state == 'APPROVED'
      or review.state == 'CHANGES_REQUESTED' or review.state == 'DISMISSED') then add('review', review) end
  end
  for _, entry in pairs(indexed) do result.entries[#result.entries + 1] = entry end
  table.sort(result.entries, function(a, b)
    if a.created_at ~= b.created_at then return a.created_at < b.created_at end
    if a.kind ~= b.kind then return a.kind < b.kind end
    local x, y = tonumber(a.id), tonumber(b.id)
    if x and y and x ~= y then return x < y end
    return a.key < b.key
  end)
  return timeline and require('git.features.pr_timeline').apply(ctx, result, timeline) or result
end
-- Append immutable inline history to the main PR renderer. Return semantic row
-- associations so body text resembling file/commit/header rows cannot misroute.
function M.append(lines, highlights, conversation, viewer, markdown, opts)
  local rows, first, ranges = {}, nil, {}
  for _, err in ipairs(conversation.errors) do
    lines[#lines + 1] = err:gsub('[\r\n]', ' ')
    highlights[#highlights + 1] = { row = #lines, start = 0, finish = #lines[#lines], group = 'DiagnosticWarn' }
  end
  if #conversation.entries == 0 and #conversation.errors == 0 then lines[#lines + 1] = opts and opts.empty or 'No PR comments or review summaries.' end
  for index, entry in ipairs(conversation.entries) do
    if index > 1 then lines[#lines + 1] = '' end
    if require('git.features.pr_timeline').is_event(entry) then
      local line, at = '', #lines + 1
      for _, chunk in ipairs(require('git.features.pr_timeline').chunks(entry, viewer)) do
        local value = chunk[1]:gsub('[\r\n\t]', ' ')
        highlights[#highlights + 1] = { row = at, start = #line, finish = #line + #value, group = chunk[2] }
        line = line .. value
      end
      lines[at], rows[at], first = line, entry, first or at
    else
      local author = entry.user and github.scalar(entry.user.login) or 'unknown'
      local own = author == viewer
      local label = '@' .. author .. (own and ' · you' or '')
      local kind = entry.review_state and ('Review ' .. entry.review_state) or 'Comment'
      local date = entry.created_at:gsub('T', ' '):gsub('Z$', ' UTC')
      lines[#lines + 1] = label .. ' · ' .. date .. ' · ' .. kind
      local header = #lines
      first = first or header
      local group = own and 'GitPrCommentSelf' or 'DiagnosticWarn'
      highlights[#highlights + 1] = { row = header, start = 0, finish = #label, group = group }
      local kind_group = ({ APPROVED = 'GitPrPositive', CHANGES_REQUESTED = 'DiagnosticWarn', DISMISSED = 'Comment' })[entry.review_state] or 'GitPrHeaderLabel'
      highlights[#highlights + 1] = { row = header, start = #lines[header] - #kind, finish = #lines[header], group = kind_group }
      local body = vim.split(entry.body:gsub('\r\n', '\n'), '\n', { plain = true })
      while #body > 0 and body[#body]:match('^%s*$') do table.remove(body) end
      if #body == 0 and entry.kind == 'comment' then body = { '(empty comment)' } end
      local body_start = #lines
      for _, line in ipairs(body) do
        lines[#lines + 1] = line
        if own then highlights[#highlights + 1] = { row = #lines, start = 0, finish = #line, group = 'GitPrCommentSelf', priority = markdown and 90 or 200 } end
      end
      if #lines > body_start then ranges[#ranges + 1] = { body_start, #lines } end
      local reactions = require('git.features.pr_reactions').format(entry.reactions)
      if reactions ~= '' then
        lines[#lines + 1] = reactions
        highlights[#highlights + 1] = { row = #lines, start = 0, finish = #reactions, group = 'Comment' }
      end
      for row = header, #lines do rows[row] = entry end
    end
  end
  return rows, first, ranges
end
return M
