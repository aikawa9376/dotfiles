-- Provider-neutral identities and rows. API selection never relies on names alone.
local M = {}
local scalar = require('git.features.github').scalar
function M.web_url(value)
  if type(value) ~= 'string' or value:find('[%s%c]') then return nil end
  local host, path = value:match('^https://([%w%.%-]+)(/[^?#]*)')
  if not host then return nil end
  return 'https://' .. host:lower() .. path
end
function M.url_parts(value)
  local url = M.web_url(value)
  if url then return url:match('^https://([^/]+)(/.*)$') end
end
function M.bucket(value)
  value = tostring(scalar(value) or 'pending'):lower()
  if value == 'success' or value == 'passed' or value == 'succeeded' then return 'pass' end
  if value == 'neutral' or value == 'skipped' or value == 'not_run' then return 'skipping' end
  if value == 'cancelled' or value == 'canceled' then return 'cancel' end
  if vim.tbl_contains({ 'failure', 'failed', 'error', 'errored', 'timed_out', 'timedout', 'action_required', 'startup_failure', 'stale', 'infrastructure_fail', 'unauthorized' }, value) then return 'fail' end
  return 'pending'
end
function M.symbol(value)
  local bucket = M.bucket(value)
  return ({ fail = '✗', pending = '◷', cancel = '⊘', pass = '✓', skipping = '·' })[bucket],
    ({ fail = 'DiagnosticError', pending = 'DiagnosticWarn', cancel = 'DiagnosticWarn', pass = 'GitPrPositive', skipping = 'Comment' })[bucket]
end
function M.provider(raw, url, ctx)
  local app = scalar(raw.app) or {}
  local host, path = M.url_parts(url)
  if app.slug == 'github-actions' or (host == ctx.host and path and (path:match('/actions/runs/') or path:match('/runs/%d+')) and raw.name) then
    return 'github_actions'
  end
  local configured = vim.g.git_ci or {}
  local circle_host = configured.circleci_host or 'circleci.com'
  if app.slug == 'circleci' or app.slug == 'circle-ci' or host == 'circleci.com' or host == 'app.circleci.com' or host == circle_host
    or tostring(raw.context or ''):lower():match('^ci/circleci:') then return 'circleci' end
  return 'generic'
end
function M.check(raw, ctx, sha, kind, ordinal)
  local url = M.web_url(scalar(raw.details_url) or scalar(raw.detailsUrl) or scalar(raw.target_url) or scalar(raw.targetUrl))
  local state = scalar(raw.conclusion) or scalar(raw.state) or scalar(raw.status) or 'pending'
  local number = tonumber(scalar(raw.databaseId)) or (type(raw.id) == 'number' and raw.id or nil)
  local name = scalar(raw.name) or scalar(raw.context) or 'Check'
  local provider = M.provider(raw, url, ctx)
  local upstream = kind == 'status' and name or number or scalar(raw.id) or url and (url .. ':' .. name)
    or 'unresolved:' .. name .. ':' .. tostring(ordinal or 1)
  return { id = table.concat({ ctx.host, ctx.repo, sha, provider, kind, tostring(upstream) }, '/'),
    kind = kind, provider = provider, repo = ctx.repo, pr_number = ctx.number, head_sha = sha, name = name,
    state = state, bucket = M.bucket(state), description = scalar(raw.description), url = url,
    started_at = scalar(raw.started_at) or scalar(raw.startedAt), completed_at = scalar(raw.completed_at) or scalar(raw.completedAt),
    check_run_id = kind == 'check_run' and number or nil, node_id = type(raw.id) == 'string' and raw.id or scalar(raw.node_id), raw = raw }
end
function M.normalize(runs, statuses, ctx, sha)
  local result, latest = {}, {}
  for i, raw in ipairs(runs) do result[#result + 1] = M.check(raw, ctx, sha, 'check_run', i) end
  for _, raw in ipairs(statuses) do
    local context = raw.context or 'Check'
    local previous = latest[context]
    if not previous or (raw.created_at or '') > (previous.created_at or '')
      or ((raw.created_at or '') == (previous.created_at or '') and (tonumber(raw.id) or 0) > (tonumber(previous.id) or 0)) then latest[context] = raw end
  end
  local contexts = vim.tbl_keys(latest); table.sort(contexts)
  for _, context in ipairs(contexts) do result[#result + 1] = M.check(latest[context], ctx, sha, 'status') end
  return M.sort(result)
end
function M.sort(checks)
  local ranks = { fail = 1, pending = 2, cancel = 3, pass = 4, skipping = 5 }
  local ordered = {}
  for i, check in ipairs(checks) do ordered[i] = { check = check, index = i } end
  table.sort(ordered, function(a, b)
    local x, y = ranks[a.check.bucket], ranks[b.check.bucket]
    return x < y or (x == y and a.index < b.index)
  end)
  local result = {}; for _, item in ipairs(ordered) do result[#result + 1] = item.check end
  return result
end
function M.rollup(pr, ctx)
  local checks = {}
  for i, raw in ipairs(scalar(pr.statusCheckRollup) or {}) do
    checks[#checks + 1] = M.check(raw, ctx, pr.headRefOid, raw.context and 'status' or 'check_run', i)
  end
  return M.sort(checks)
end
function M.match(selected, candidates)
  local matches = {}
  for _, candidate in ipairs(candidates) do
    if candidate.kind == selected.kind and candidate.head_sha == selected.head_sha and candidate.repo == selected.repo then
      local exact = selected.check_run_id and candidate.check_run_id == selected.check_run_id
        or selected.node_id and candidate.node_id == selected.node_id
      local linked = not selected.check_run_id and not selected.node_id and selected.url and candidate.url == selected.url and candidate.name == selected.name
      if exact or linked then matches[#matches + 1] = candidate end
    end
  end
  if #matches == 1 then return matches[1] end
  return nil, #matches > 1 and 'Ambiguous check identity; use gx to inspect it on the web.' or 'Selected check could not be identified for this commit; use gx to inspect it on the web.'
end
function M.duration(started, completed)
  local function timestamp(value)
    if type(value) ~= 'string' then return nil end
    local y, m, d, h, min, sec, suffix = value:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$')
    if not y then return nil end
    local local_time = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = tonumber(h), min = tonumber(min), sec = tonumber(sec), isdst = false })
    local utc_table = os.date('!*t', local_time); utc_table.isdst = false
    local utc = local_time + os.difftime(local_time, os.time(utc_table))
    local sign, oh, om = suffix:match('([+-])(%d%d):(%d%d)$')
    if sign then utc = utc - (sign == '+' and 1 or -1) * (tonumber(oh) * 3600 + tonumber(om) * 60) end
    return utc
  end
  local first, last = timestamp(started), timestamp(completed)
  if not first then return '—' end
  local seconds = math.max(0, (last or os.time()) - first)
  return seconds < 60 and ('%ds'):format(seconds) or ('%dm %ds'):format(math.floor(seconds / 60), seconds % 60)
end
return M
