-- Read PR relationships for a captured cursor target, never the menu buffer.
local M = {}
local github = require('git.features.github')
local async = require('git.features.async')
local function clean(value) return tostring(github.scalar(value) or ''):gsub('[%c]', ' ') end
M.clean = clean

local function remote_repo(root, remote)
  if not remote or remote == '.' then return end
  local url = async.git(root, { 'remote', 'get-url', remote })
  url = url and vim.trim(url)
  if not url then return end
  local host, repo = url:match('^https?://([^/]+)/(.+)$')
  if not host then host, repo = url:match('^ssh://[^@]+@([^/]+)/(.+)$') end
  if not host then host, repo = url:match('^[^@]+@([^:]+):(.+)$') end
  if repo then return host, repo:gsub('/$', ''):gsub('%.git$', '') end
end

function M.load(opts)
  local explicit = opts.url or opts.number
  local branch, kind = opts.branch, opts.branch_kind
  -- Capture the ordinary-file fallback before the first network request.
  if not explicit and not opts.commit and not branch and not opts.no_target then
    local value = async.git(opts.root, { 'branch', '--show-current' })
    branch = value and vim.trim(value)
  end
  local ctx = github.resolve(vim.tbl_extend('force', opts, { repository_only = not explicit }))
  local result, seen = { items = {} }, {}
  local function add(pr)
    local identity = github.url_context(github.scalar(pr.html_url) or pr.url)
    if not identity or identity.number ~= pr.number or seen[identity.url] then return end
    seen[identity.url] = true
    pr = vim.deepcopy(pr)
    pr.url = identity.url
    pr.state = (github.scalar(pr.merged_at) or pr.state == 'MERGED') and 'MERGED' or (pr.state or 'OPEN'):upper()
    pr.isDraft = pr.isDraft or pr.draft or false
    pr.headRefName = pr.headRefName or (pr.head and pr.head.ref)
    pr.baseRefName = pr.baseRefName or (pr.base and pr.base.ref)
    result.items[#result.items + 1] = pr
  end
  if explicit then add(github.pr(ctx)); return result end
  if opts.commit or kind == 'tags' then
    local ref = opts.commit or ('refs/tags/' .. branch)
    local hash, err = async.git(ctx.root, { 'rev-parse', '--verify', '--end-of-options', ref .. '^{commit}' })
    if not hash then error(err, 0) end
    local prs = github.api(ctx, ('repos/%s/commits/%s/pulls?per_page=100'):format(ctx.repo, vim.trim(hash)))
    for _, pr in ipairs(prs) do add(pr) end
    result.limited = #prs == 100
  else
    if opts.no_target then return result end
    if not branch or branch == '' then return result end
    local remote, head = nil, branch
    if kind == 'remote' then remote, head = branch:match('^([^/]+)/(.+)$')
    else
      local saved = async.git(ctx.root, { 'config', '--get', 'branch.' .. branch .. '.pullRequestUrl' })
      if saved and github.url_context(vim.trim(saved)) then
        local associated = github.resolve({ root = ctx.root, url = vim.trim(saved) })
        add(github.pr(associated)); return result
      end
      for _, key in ipairs({ 'branch.' .. branch .. '.pushRemote', 'remote.pushDefault', 'branch.' .. branch .. '.remote' }) do
        local value = async.git(ctx.root, { 'config', '--get', key })
        if value and vim.trim(value) ~= '' and vim.trim(value) ~= '.' then remote = vim.trim(value); break end
      end
      remote = remote or 'origin'
    end
    local host, repo = remote_repo(ctx.root, remote)
    if host and host:lower() ~= ctx.host:lower() then error('Selected branch remote uses another GitHub host', 0) end
    local prs = github.json(ctx, { 'pr', 'list', '--repo', github.repo_arg(ctx), '--state', 'all',
      '--head', head, '--limit', '100', '--json',
      'number,title,url,state,isDraft,headRefName,baseRefName,headRepository,headRepositoryOwner,reviewDecision,mergeable,statusCheckRollup' })
    for _, pr in ipairs(prs) do
      local owner, repository = github.scalar(pr.headRepositoryOwner), github.scalar(pr.headRepository)
      local actual = owner and repository and (owner.login .. '/' .. repository.name)
      if not repo or not actual or actual:lower() == repo:lower() then add(pr) end
    end
    result.limited = #prs == 100
  end
  local function rank(pr) return pr.state == 'OPEN' and (pr.isDraft and 2 or 1) or pr.state == 'MERGED' and 3 or 4 end
  table.sort(result.items, function(a, b)
    if rank(a) ~= rank(b) then return rank(a) < rank(b) end
    return a.number > b.number
  end)
  return result
end

function M.label(pr)
  return ('#%d [%s] %s (%s → %s)'):format(pr.number,
    pr.isDraft and pr.state == 'OPEN' and 'draft' or pr.state:lower(), clean(pr.title),
    clean(pr.headRefName), clean(pr.baseRefName))
end
return M
