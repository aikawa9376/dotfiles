-- Literal argv/stdin only. Authentication and remote selection belong to gh.
local M = {}
local async = require('git.features.async')
local utils = require('git.utils')
vim.api.nvim_set_hl(0, 'GitPrPositive', { default = true, link = 'DiagnosticOk' })
vim.api.nvim_set_hl(0, 'GitPrHeaderLabel', { default = true, link = 'DiagnosticInfo' })
M.fields = 'number,title,body,url,state,isDraft,baseRefName,baseRefOid,headRefName,headRefOid,reviewDecision,mergeable,mergeStateStatus,statusCheckRollup,author,createdAt,updatedAt,assignees,milestone,labels,reviewRequests,additions,deletions,changedFiles'
local function scalar(value)
  if value == vim.NIL or value == '' then return nil end
  return value
end
M.scalar = scalar
function M.checks(pr)
  local result = {}
  for _, check in ipairs(scalar(pr.statusCheckRollup) or {}) do
    result[#result + 1] = {
      label = (check.name or check.context or 'Check') .. ': ' .. (scalar(check.conclusion) or scalar(check.state) or scalar(check.status) or 'pending'),
      url = scalar(check.detailsUrl) or scalar(check.targetUrl),
      result = scalar(check.conclusion) or scalar(check.state) or scalar(check.status),
    }
  end
  return result
end
function M.actions_url(ctx, branch)
  return ('https://%s/%s/actions'):format(ctx.host, ctx.repo)
    .. (branch and ('?query=' .. vim.uri_encode('branch:' .. branch, 'rfc2396')) or '')
end
function M.url_context(url)
  local host, repo, number = (url or ''):match('^https://([^/]+)/([^/]+/[^/]+)/pull/(%d+)')
  if not host then return nil end
  return { host = host, repo = repo, number = tonumber(number), resource_kind = 'pull_request', url = ('https://%s/%s/pull/%s'):format(host, repo, number) }
end
-- Issue resolution is explicit and never consults branch/PR associations.
function M.issue_url_context(url)
  local host, repo, number, tail = (url or ''):match('^https://([^/]+)/([^/]+/[^/]+)/issues/(%d+)(.*)$')
  if not host or (tail ~= '' and not tail:match('^[#?]') and tail ~= '/') then return nil end
  return { host = host, repo = repo, number = tonumber(number), resource_kind = 'issue',
    url = ('https://%s/%s/issues/%s'):format(host, repo, number) }
end
function M.issue(ctx)
  assert(ctx.resource_kind == 'issue' and ctx.number, 'Select an Issue number or URL')
  local issue = M.api(ctx, ('repos/%s/issues/%d'):format(ctx.repo, ctx.number))
  assert(type(issue) == 'table' and not M.scalar(issue.pull_request), 'This number is a pull request; use :GitPr')
  local identity = M.issue_url_context(issue.html_url)
  assert(identity and identity.host:lower() == ctx.host:lower() and identity.repo:lower() == ctx.repo:lower()
    and identity.number == ctx.number and issue.number == ctx.number, 'Issue identity changed; reopen its URL')
  issue.body, issue.author = M.scalar(issue.body) or '', M.scalar(issue.user) or {}
  ctx.url = identity.url
  return issue
end
function M.repo_arg(ctx) return ctx.host .. '/' .. ctx.repo end
function M.command(ctx, args, opts)
  local argv = { 'gh' }; vim.list_extend(argv, args)
  if args[1] == 'api' then
    -- Explicit JSON/preview negotiation, following Octo rather than gh's */*.
    -- Thread creation uses GraphQL; these headers do not fix legacy REST writes.
    vim.list_extend(argv, { '--header', 'Accept: application/vnd.github+json, application/vnd.github.comfort-fade-preview+json',
      '--header', 'X-GitHub-Api-Version: 2022-11-28' })
  end
  local env = { GH_PROMPT_DISABLED = '1' }
  if ctx.host then env.GH_HOST = ctx.host end
  local result = async.system(ctx.root, argv, vim.tbl_extend('force', {
    env = env,
  }, opts or {}))
  if result.code ~= 0 then
    local message = vim.trim(result.stderr or '')
    if message == '' then message = 'GitHub command failed (exit ' .. result.code .. ')' end
    -- gh prints the HTTP response body to stdout, even on failure. Keep the
    -- useful validation reasons without dumping arbitrary response contents.
    if args[1] == 'api' then
      local ok, response = pcall(vim.json.decode, result.stdout or '')
      if ok and type(response) == 'table' then
        local function append(detail)
          if type(detail) == 'string' and detail ~= '' and not message:find(detail, 1, true) then
            message = message .. '\n' .. detail
          end
        end
        append(response.message)
        if type(response.errors) == 'table' then
          for _, detail in ipairs(response.errors) do
            if type(detail) == 'table' then
              append(detail.message or (detail.field and detail.code and (detail.field .. ': ' .. detail.code)))
            else append(detail) end
          end
        end
      end
    end
    error(message, 0)
  end
  return result.stdout or ''
end
function M.json(ctx, args, opts)
  local output = M.command(ctx, args, opts)
  local ok, decoded = pcall(vim.json.decode, output)
  if not ok then error('Invalid JSON from GitHub CLI', 0) end
  return decoded
end
function M.api(ctx, endpoint, payload, method)
  local args = { 'api', '--hostname', ctx.host, endpoint }
  local opts
  if payload then
    vim.list_extend(args, { '--method', method or 'POST', '--input', '-' })
    opts = { stdin = vim.json.encode(payload) }
  elseif method then vim.list_extend(args, { '--method', method }) end
  local output = M.command(ctx, args, opts)
  if vim.trim(output) == '' then return nil end -- Successful 204 mutations.
  local ok, decoded = pcall(vim.json.decode, output)
  if not ok then error('Invalid JSON from GitHub CLI', 0) end
  return decoded
end
function M.resolve(opts)
  opts = opts or {}
  local issue = opts.resource_kind == 'issue'
  local parsed = issue and M.issue_url_context(opts.url) or (not issue and M.url_context(opts.url))
  if opts.url and issue and not parsed then error('Use an Issue URL, not a pull request URL', 0) end
  local ctx = parsed and vim.tbl_extend('force', vim.deepcopy(opts), parsed) or vim.deepcopy(opts)
  ctx.root = utils.normalize_path(opts.root or opts.work_tree
    or utils.get_buf_work_tree(opts.bufnr or vim.api.nvim_get_current_buf()) or utils.get_work_tree({}))
  if not ctx.root then error('Not in a Git repository', 0) end
  if not issue and not ctx.number and not opts.url and not opts.repository_only then
    local branch = async.git(ctx.root, { 'branch', '--show-current' })
    if branch and vim.trim(branch) ~= '' then
      local saved = async.git(ctx.root, { 'config', '--get', 'branch.' .. vim.trim(branch) .. '.pullRequestUrl' })
      local associated = saved and M.url_context(vim.trim(saved))
      if associated then ctx = vim.tbl_extend('force', ctx, associated) end
    end
  end
  if not ctx.repo then
    local repo = M.json(ctx, { 'repo', 'view', '--json', 'nameWithOwner,url,defaultBranchRef' })
    ctx.host = repo.url:match('^https://([^/]+)/')
    local default = scalar(repo.defaultBranchRef)
    ctx.repo, ctx.default_branch = repo.nameWithOwner, default and default.name
  end
  ctx.resource_kind = issue and 'issue' or 'pull_request'
  ctx.host = ctx.host or 'github.com'
  if not ctx.host:match('^[%w%.%-]+$') or not ctx.repo:match('^[%w_.%-]+/[%w_.%-]+$') then error('Invalid GitHub host/repository', 0) end
  if ctx.number and (type(ctx.number) ~= 'number' or ctx.number < 1 or ctx.number % 1 ~= 0) then error(issue and 'Invalid Issue number' or 'Invalid PR number', 0) end
  return ctx
end
function M.pr(ctx)
  local args = { 'pr', 'view' }
  if ctx.number then
    vim.list_extend(args, { tostring(ctx.number), '--repo', M.repo_arg(ctx) })
  end
  -- --repo requires a selector. Without a number, let gh resolve the current
  -- branch and its tracking/fork association from the captured worktree.
  vim.list_extend(args, { '--json', M.fields })
  local pr = M.json(ctx, args)
  pr.author = scalar(pr.author) or {}
  pr.body = scalar(pr.body) or ''
  ctx.number, ctx.url = pr.number, pr.url
  return pr
end
function M.summary(pr)
  local checks = scalar(pr.statusCheckRollup)
  local failed, pending, total = 0, 0, 0
  for _, check in ipairs(type(checks) == 'table' and checks or {}) do
    total = total + 1
    local result = scalar(check.conclusion) or scalar(check.state)
    if vim.tbl_contains({ 'FAILURE', 'ERROR', 'TIMED_OUT', 'CANCELLED', 'ACTION_REQUIRED', 'STARTUP_FAILURE', 'STALE' }, result) then
      failed = failed + 1
    elseif result ~= 'SUCCESS' and result ~= 'NEUTRAL' and result ~= 'SKIPPED' then pending = pending + 1 end
  end
  local ci = total == 0 and 'CI: —' or failed > 0 and ('CI: ✗ %d/%d'):format(failed, total)
    or pending > 0 and ('CI: ◷ %d/%d'):format(pending, total) or ('CI: ✓ %d'):format(total)
  local review = ({ APPROVED = 'approved', CHANGES_REQUESTED = 'changes requested', REVIEW_REQUIRED = 'review required' })[scalar(pr.reviewDecision)] or '—'
  local merge = pr.state == 'MERGED' and 'merged'
    or ({ MERGEABLE = 'mergeable', CONFLICTING = 'conflicts', UNKNOWN = 'checking' })[scalar(pr.mergeable)]
  return ci .. ' · Review: ' .. review .. (merge and (' · ' .. merge) or '')
end
-- Status lists and PR headers share label/value colors and neutral separators.
function M.summary_chunks(pr)
  local parts = vim.split(M.summary(pr), ' · ', { plain = true })
  local ci, review = parts[1]:match('^CI: (.*)$'), parts[2]:match('^Review: (.*)$')
  local ci_group = ci:find('✓', 1, true) == 1 and 'GitPrPositive'
    or ci:find('✗', 1, true) == 1 and 'DiagnosticError'
    or ci:find('◷', 1, true) == 1 and 'DiagnosticWarn' or 'Normal'
  local review_group = ({ APPROVED = 'GitPrPositive', CHANGES_REQUESTED = 'DiagnosticError',
    REVIEW_REQUIRED = 'DiagnosticWarn' })[scalar(pr.reviewDecision)] or 'Normal'
  local chunks = { { 'CI', 'GitPrHeaderLabel' }, { ': ', 'Normal' }, { ci, ci_group },
    { ' · ', 'Normal' }, { 'Review', 'GitPrHeaderLabel' }, { ': ', 'Normal' }, { review, review_group } }
  if parts[3] then
    chunks[#chunks + 1] = { ' · ', 'Normal' }
    chunks[#chunks + 1] = { parts[3], pr.state == 'MERGED' and 'GitPrPositive'
      or ({ MERGEABLE = 'GitPrPositive', CONFLICTING = 'DiagnosticError',
        UNKNOWN = 'DiagnosticWarn' })[scalar(pr.mergeable)] or 'Normal' }
  end
  return chunks
end
function M.changed(ctx)
  if ctx.resource_kind ~= 'issue' then utils.fire_git_changed({ work_tree = ctx.root }) end
  vim.api.nvim_exec_autocmds('User', { pattern = 'GitHubChanged', data = ctx })
end
return M
