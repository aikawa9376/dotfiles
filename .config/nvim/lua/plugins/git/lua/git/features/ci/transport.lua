-- Read-only requests with bounded output and deliberately terse/redacted errors.
local M = {}
local async = require('git.features.async')
local model = require('git.features.ci.model')
local allow_escape = false
function M.config() return vim.g.git_ci or {} end
function M.limit() return math.max(1024, tonumber(M.config().max_log_bytes) or 2 * 1024 * 1024) end
function M.clean(value)
  value = tostring(value or ''):gsub('^\239\187\191', ''):gsub('\r\n', '\n'):gsub('\r', '\n')
  value = value:gsub('\27%][^\7\27]*\7', ''):gsub('\27%][^\27]*\27\\', '')
    :gsub('\27%[[0-?]*[ -/]*[@-~]', ''):gsub('\27[ -/]*[@-~]', '')
  for _, name in ipairs({ 'CIRCLE_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN' }) do
    local secret = vim.env[name]
    if secret and secret ~= '' then value = value:gsub(secret:gsub('([^%w])', '%%%1'), '[redacted]') end
  end
  return (value:gsub('[%z\1-\8\11\12\14-\31\127]', ''))
end
function M.error(result, logs)
  local text = tostring(result.stderr or ''):lower()
  local status = text:match('http%s+(%d%d%d)') or tostring(result.http_status or '')
  if result.code == 124 or result.code == 28 or text:find('timeout', 1, true) or text:find('timed out', 1, true) then return 'Request timed out; R retries.' end
  if status == '401' or text:find('gh auth login', 1, true) then return 'Authentication required; check gh auth or CIRCLE_TOKEN.' end
  if status == '403' then return logs and 'Log access denied or signed download expired (HTTP 403); R requests a fresh log.' or 'Permission denied (HTTP 403); check repository read access.' end
  if status == '404' then return logs and 'Log unavailable (HTTP 404): expired, not generated, or unsupported by this server.' or 'Resource unavailable (HTTP 404): missing or private without access.' end
  if status == '429' then return 'API rate limit reached (HTTP 429); retry later with R.' end
  if result.code == 63 then return 'Log exceeds the download size limit; open it on the web.' end
  if status:match('^%d%d%d$') then return 'API request failed (HTTP ' .. status .. '); R retries.' end
  return 'Network or API request failed; R retries.'
end
function M.system(ctx, argv, opts, limit)
  local parts, bytes, truncated = {}, 0, false
  opts = vim.tbl_extend('force', { text = false, timeout = tonumber(M.config().timeout_ms) or 30000 }, opts or {})
  opts.stdout = function(err, chunk)
    if err or not chunk then return end
    local keep = math.max(0, limit - bytes)
    if #chunk > keep then truncated = true end
    if keep > 0 then parts[#parts + 1] = chunk:sub(1, keep); bytes = bytes + math.min(keep, #chunk) end
  end
  local result = async.system(ctx.root, argv, opts)
  -- Also accept complete outputs from test transports or older wrappers.
  local output = #parts > 0 and table.concat(parts) or result.stdout or ''
  if #output > limit then output, truncated = output:sub(1, limit), true end
  result.stdout = output
  return result, truncated
end
function M.github(ctx, endpoint, logs)
  assert(ctx.host:match('^[%w%.%-]+$') and ctx.repo:match('^[%w_.%-]+/[%w_.%-]+$'), 'Invalid GitHub context')
  assert(endpoint:sub(1, #('repos/' .. ctx.repo .. '/')) == 'repos/' .. ctx.repo .. '/' and not endpoint:find('%.%.'), 'Invalid API endpoint')
  local argv = { 'gh', 'api', '--hostname', ctx.host, endpoint, '--method', 'GET',
    '--header', 'Accept: application/vnd.github+json', '--header', 'X-GitHub-Api-Version: '
      .. (M.config().github_api_version or (ctx.host == 'github.com' and '2026-03-10' or '2022-11-28')) }
  if logs and allow_escape then argv[#argv + 1] = '--allow-escape-sequences' end
  local opts = { env = { GH_HOST = ctx.host, GH_PROMPT_DISABLED = '1', GH_DEBUG = '' } }
  local limit = logs and M.limit() or 8 * 1024 * 1024
  local result, truncated = M.system(ctx, argv, opts, limit)
  -- New gh versions reject terminal escape sequences by default. Opt in only
  -- when the CLI requests it; old gh versions need no unsupported flag. Raw
  -- bytes still pass through service.log's display sanitization.
  if logs and not allow_escape and result.code ~= 0 and (result.stderr or ''):find('pass --allow-escape-sequences', 1, true) then
    allow_escape = true; argv[#argv + 1] = '--allow-escape-sequences'
    result, truncated = M.system(ctx, argv, opts, limit)
  end
  if result.code ~= 0 then error(M.error(result, logs), 0) end
  if logs then return result.stdout, truncated end
  if truncated then error('API response exceeded the size limit', 0) end
  local ok, decoded = pcall(vim.json.decode, result.stdout)
  if not ok or type(decoded) ~= 'table' then error('Invalid JSON response from GitHub', 0) end
  return decoded
end
function M.pages(ctx, endpoint, field)
  local all, page = {}, 1
  while true do
    local response = M.github(ctx, endpoint .. (endpoint:find('?', 1, true) and '&' or '?') .. 'per_page=100&page=' .. page)
    local entries = field and response[field] or response
    if type(entries) ~= 'table' then error('Invalid paginated API response', 0) end
    vim.list_extend(all, entries)
    if #entries < 100 then break end
    page = page + 1
    if page > 1000 then error('API pagination limit reached', 0) end
  end
  return all
end
function M.circle_host() return M.config().circleci_host or 'circleci.com' end
local function quote(value) return '"' .. value:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"' end
function M.download(ctx, url, token, logs, bearer)
  local host = model.url_parts(url)
  -- Keep the original signed query only in the transient request, never in UI/cache.
  if not host then error('Unsafe download URL; open the check on the web.', 0) end
  local allowed = host == M.circle_host() or host == 'circleci.com' or host == 'app.circleci.com'
    or host:match('%.amazonaws%.com$') or host:match('%.circleci%.com$')
  for _, extra in ipairs(M.config().log_hosts or {}) do if host == extra then allowed = true end end
  if token then allowed = host == M.circle_host() end
  if not allowed then error('Unrecognized log host; configure git_ci.log_hosts or open the check on the web.', 0) end
  if url:find('[%c%s]') or url:find('"', 1, true) or url:find('\\', 1, true) then error('Unsafe download URL', 0) end
  -- Secrets/URLs travel through stdin, not argv. Redirects are rejected for
  -- both API and signed-log downloads.
  local config = 'url = ' .. quote(url) .. '\n'
  if token then
    if token:find('[%c]') then error('Invalid CIRCLE_TOKEN', 0) end
    config = config .. 'header = ' .. quote((bearer and 'Authorization: Bearer ' or 'Circle-Token: ') .. token) .. '\n'
  end
  local argv = { 'curl', '--disable', '--silent', '--show-error', '--globoff', '--proto', '=https', '--proto-redir', '=https',
    '--max-time', tostring((tonumber(M.config().timeout_ms) or 30000) / 1000), '--max-filesize', tostring(logs and M.limit() or 8 * 1024 * 1024),
    '--write-out', '\n%{http_code}', '--config', '-' }
  -- Reject redirects rather than forwarding authentication or following an
  -- arbitrary destination. Retrying reacquires any expired presigned URL.
  local result, truncated = M.system(ctx, argv, { stdin = config }, (logs and M.limit() or 8 * 1024 * 1024) + 32)
  local body, code = result.stdout:match('^(.*)\n(%d%d%d)$')
  result.http_status = code
  if result.code ~= 0 or not code or tonumber(code) < 200 or tonumber(code) >= 300 then error(M.error(result, logs), 0) end
  return body, truncated
end
function M.circle_raw(ctx, path, logs)
  local token = vim.env.CIRCLE_TOKEN
  if not token or token == '' then error('CircleCI authentication required: set CIRCLE_TOKEN; o opens the web page.', 0) end
  local host = M.circle_host()
  if not host:match('^[%w%.%-]+$') or path:find('%.%.') or not path:match('^/api/') then error('Invalid CircleCI API configuration', 0) end
  return M.download(ctx, 'https://' .. host .. path, token, logs, path:match('^/api/v3/') ~= nil)
end
function M.circle_json(ctx, path)
  local output = M.circle_raw(ctx, path, false)
  local ok, decoded = pcall(vim.json.decode, output)
  if not ok or type(decoded) ~= 'table' then error('Invalid JSON response from CircleCI', 0) end
  return decoded
end
return M
