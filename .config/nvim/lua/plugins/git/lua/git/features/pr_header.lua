-- Octo-style details, with plain buffer text and explicit byte-column spans.
local M = {}
local github = require('git.features.github')
local function clean(value) return tostring(value):gsub('[\r\n]', ' ') end
local function list(value)
  value = github.scalar(value)
  return type(value) == 'table' and (value.nodes or value) or {}
end
local function names(value, field)
  local result = {}
  for _, item in ipairs(list(value)) do if github.scalar(item[field]) then result[#result + 1] = clean(item[field]) end end
  return #result > 0 and table.concat(result, ', ') or nil
end
local function outcome(state)
  if state == 'SUCCESS' or state == 'APPROVED' then return '✓', 'GitPrPositive', 4 end
  if vim.tbl_contains({ 'FAILURE', 'ERROR', 'TIMED_OUT', 'CANCELLED', 'ACTION_REQUIRED', 'STARTUP_FAILURE', 'STALE', 'CHANGES_REQUESTED' }, state) then
    return '✗', 'DiagnosticWarn', 1
  end
  if state == 'NEUTRAL' or state == 'SKIPPED' or state == 'COMMENTED' or state == 'DISMISSED' then return '·', 'Comment', 3 end
  return '◷', 'DiagnosticWarn', 2
end
function M.build(model, expanded, checks_expanded)
  local pr, ctx = model.pr, model.ctx
  local result = { lines = {}, highlights = {}, links = {}, ci_rows = {} }
  local function row(chunks, url)
    local text, at = '', #result.lines + 1
    for _, chunk in ipairs(chunks) do
      local value = clean(chunk[1])
      if chunk[2] and #value > 0 then result.highlights[#result.highlights + 1] = {
        row = at, start = #text, finish = #text + #value, group = chunk[2],
      } end
      text = text .. value
    end
    result.lines[at] = text
    if url then result.links[at] = url end
    return at
  end
  local function detail(label, value, group, url)
    if not github.scalar(value) then return end
    return row({ { label .. ': ', 'GitPrHeaderLabel' }, { value, group or 'Normal' } }, url)
  end
  local state = pr.isDraft and 'DRAFT' or pr.state or 'OPEN'
  row({ { 'Repo: ', 'GitPrHeaderLabel' }, { ctx.repo .. ' ', 'Normal' }, { ('[ PR #%d ] '):format(pr.number), 'Title' },
    { '[' .. state .. ']', (state == 'OPEN' or state == 'MERGED') and 'GitPrPositive' or 'DiagnosticWarn' } }, pr.url)
  result.links[1] = { start_col = #'Repo: ', end_col = #'Repo: ' + #ctx.repo,
    url = ('https://%s/%s'):format(ctx.host, ctx.repo) }
  if expanded then
    detail('Created by', pr.author and github.scalar(pr.author.login) and ('@' .. pr.author.login), 'Identifier')
    for _, entry in ipairs({ { 'Created', pr.createdAt }, { 'Updated', pr.updatedAt } }) do
      if github.scalar(entry[2]) then detail(entry[1], entry[2]:sub(1, 10)) end
    end
    detail('Assignees', names(pr.assignees, 'login'))
    local milestone = github.scalar(pr.milestone)
    detail('Milestone', milestone and milestone.title)
    detail('Labels', names(pr.labels, 'name'))
    local reviewers = {}
    for _, review in ipairs(model.review and model.review.reviews or {}) do
      local name = review.user and github.scalar(review.user.login)
      if name and review.state ~= 'PENDING' then
        local previous = reviewers[name]
        local date = github.scalar(review.submitted_at) or ''
        if not previous or date > previous.date or (date == previous.date and review.id > previous.id) then
          reviewers[name] = { state = review.state, date = date, id = review.id }
        end
      end
    end
    for _, request in ipairs(list(pr.reviewRequests)) do
      local user = github.scalar(request.requestedReviewer) or request
      local name = github.scalar(user.login) or github.scalar(user.name) or github.scalar(user.slug)
      if name then reviewers[name] = { state = 'REVIEW_REQUIRED' } end
    end
    local reviewer_names = vim.tbl_keys(reviewers)
    table.sort(reviewer_names)
    if #reviewer_names > 0 then
      local chunks = { { 'Reviewers: ', 'GitPrHeaderLabel' } }
      for i, name in ipairs(reviewer_names) do
        local icon, group = outcome(reviewers[name].state)
        chunks[#chunks + 1] = { (i > 1 and '  ' or '') .. '@' .. name .. ' ', 'Identifier' }
        chunks[#chunks + 1] = { icon, group }
      end
      row(chunks)
    end
    row({ { 'From: ', 'GitPrHeaderLabel' }, { pr.headRefName, 'Normal' },
      { '  Into: ', 'GitPrHeaderLabel' }, { pr.baseRefName, 'Normal' } })
    local add, del = tonumber(github.scalar(pr.additions)) or 0, tonumber(github.scalar(pr.deletions)) or 0
    local total = add + del
    local unit = total > 0 and math.ceil(total / 5) or 1
    local green = math.floor((add + 0.5) / unit)
    local red = math.floor((del + 0.5) / unit)
    local chunks = { { 'Commits: ', 'GitPrHeaderLabel' }, { tostring(model.commit_count or '—'), 'Normal' },
      { '  Changed files: ', 'GitPrHeaderLabel' }, { tostring(github.scalar(pr.changedFiles) or #model.entries), 'Normal' },
      { '  (', 'GitPrHeaderLabel' }, { '+' .. add .. ' ', 'GitPrPositive' }, { '-' .. del .. ' ', 'GitSignsDelete' },
      { string.rep('■', green), 'GitPrPositive' }, { string.rep('■', red), 'GitSignsDelete' },
      { string.rep('■', math.max(0, 5 - green - red)), 'Comment' }, { ')', 'GitPrHeaderLabel' } }
    row(chunks)
  end
  if expanded then
    local merge = github.scalar(pr.mergeStateStatus)
    if merge and merge ~= 'UNKNOWN' and merge ~= 'CLEAN' and pr.state ~= 'MERGED' then detail('Merge', merge) end
    local pending = model.review and model.review.pending
    if model.review_error then detail('Your review', 'unavailable · ' .. clean(model.review_error), 'DiagnosticWarn')
    elseif model.review and model.review.migration and model.review.migration.phase ~= 'planned' then
      detail('Your review', 'migration needs recovery · gr u', 'DiagnosticWarn')
    elseif pending then
      detail('Your review', ('PENDING #%d · %d comments%s · gr'):format(pending.id, #pending.comments,
        pending.commit_id ~= model.hash and (' · review commit ' .. pending.commit_id:sub(1, 7)) or ''), 'DiagnosticWarn')
    end
    local submitted = model.review and model.review.submitted
    if submitted then
      local hash = github.scalar(submitted.commit_id)
      local at = detail('Your last review', submitted.state,
        submitted.state == 'APPROVED' and 'GitPrPositive' or submitted.state == 'CHANGES_REQUESTED' and 'DiagnosticWarn' or 'Comment',
        github.scalar(submitted.html_url) or (pr.url .. '#pullrequestreview-' .. submitted.id))
      if hash and hash ~= model.hash then result.lines[at] = result.lines[at] .. ' · earlier commit ' .. hash:sub(1, 7) end
    end
    local summary_row = row(github.summary_chunks(pr), pr.url .. '/checks')
    local ci = require('git.features.ci.model')
    local checks = checks_expanded and ci.rollup(pr, ctx) or {}
    for _, check in ipairs(checks) do
      local icon, group = ci.symbol(check.state)
      local label = check.name .. ': ' .. check.state
      local at = row({ { icon .. ' ', group }, { label, check.bucket == 'pass' and 'GitPrPositive' or 'Normal' },
        { ' · ' .. ({ github_actions = 'GitHub Actions', circleci = 'CircleCI', generic = 'Other CI' })[check.provider]
          .. ' · ' .. ci.duration(check.started_at, check.completed_at), 'Comment' } },
        check.url or pr.url .. '/checks')
      result.ci_rows[at] = check
    end
    result.ci_section = { first = summary_row, last = #result.lines }
  end
  return result
end
return M
