-- Read PR relationships for a captured cursor target, never the menu buffer.
local M = {}
local github = require('git.features.github')
local async = require('git.features.async')
local cache = require('git.features.github_related_cache')
local utils = require('git.utils')
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

function M.load(opts, resolved)
  local explicit = opts.url or opts.number
  local branch, kind = opts.branch, opts.branch_kind
  -- Capture the ordinary-file fallback before the first network request.
  if not explicit and not opts.commit and not branch and not opts.no_target then
    local value = async.git(opts.root, { 'branch', '--show-current' })
    branch = value and vim.trim(value)
  end
  local ctx = resolved or github.resolve(vim.tbl_extend('force', opts, { repository_only = not explicit }))
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

local function prepare(opts)
  local explicit = opts.url or opts.number
  if not explicit and not opts.commit then
    if opts.no_target and not opts.branch then return false end
    if not opts.branch then
      local branch = async.git(opts.root, { 'branch', '--show-current' })
      opts.branch = branch and vim.trim(branch)
    end
    if not opts.branch or opts.branch == '' then return false end
  end
  local parsed = opts.url and github.url_context(opts.url)
  if parsed then opts.url = parsed.url end
  if not explicit and (opts.commit or opts.branch_kind == 'tags') then
    local ref = opts.commit or ('refs/tags/' .. opts.branch)
    local hash, err = async.git(opts.root, { 'rev-parse', '--verify', '--end-of-options', ref .. '^{commit}' })
    if not hash then error(err, 0) end
    opts.commit, opts.branch, opts.branch_kind = vim.trim(hash), nil, nil
  end
  -- Local configuration participates in identity: changing a fork/host or a
  -- saved branch association must not reuse the former repository's PRs.
  local config = async.git(opts.root, { 'config', '--get-regexp',
    '^(remote[.].*[.](url|pushurl)|remote[.]pushdefault|branch[.].*[.](remote|pushremote|pullrequesturl))$' })
  local scope = vim.json.encode({ opts.root, config or '' })
  local repository = vim.json.encode({ scope, opts.host or '', opts.repo or '',
    parsed and parsed.host or '', parsed and parsed.repo or '' })
  local target
  if explicit then target = { 'pr', (parsed and parsed.number) or opts.number or opts.url }
  elseif opts.commit then target = { 'commit', opts.commit }
  else target = { 'branch', opts.branch_kind == 'remote' and 'remote' or 'local', opts.branch } end
  return { opts = opts, repository = repository, scope = scope, target = target, explicit = explicit ~= nil }
end

function M.generation(root) return cache.generation(utils.normalize_path(root)) end
function M.invalidate(root) cache.invalidate(root and utils.normalize_path(root)) end

-- Consumers receive independent results and cancellable subscriptions. Only
-- local Git preparation is per caller; repository discovery and PR reads join.
function M.request(opts, callback)
  opts = vim.deepcopy(opts or {})
  opts.root = utils.normalize_path(opts.root or opts.work_tree
    or utils.get_buf_work_tree(opts.bufnr or vim.api.nvim_get_current_buf()) or utils.get_work_tree({}))
  local handle, pending = {}, nil
  function handle.cancel()
    handle.cancelled = true
    if pending then pending.cancel() end
  end
  local function publish(ok, result, expires)
    if not handle.cancelled then callback(ok, result, expires or (vim.uv.now() + 10000)) end
  end
  local task, err = async.run(opts.root, function()
    assert(opts.root, 'Not in a Git repository')
    return prepare(opts)
  end, function(ok, prepared)
    if handle.cancelled then return end
    if not ok then publish(false, prepared); return end
    if not prepared then publish(true, { items = {} }, vim.uv.now() + 300000); return end
    pending = cache.get(opts.root, 'repository:' .. prepared.repository, function()
      -- A repository cache must never retain a particular PR selector.
      return github.resolve({ root = opts.root, host = opts.host or (github.url_context(opts.url) or {}).host,
        repo = opts.repo or (github.url_context(opts.url) or {}).repo, repository_only = true })
    end, function(resolved, ctx, expires)
      if handle.cancelled then return end
      if not resolved then publish(false, ctx, expires); return end
      local key = vim.json.encode({ prepared.scope, ctx.host:lower(), ctx.repo:lower(), prepared.target })
      pending = cache.get(opts.root, 'related:' .. key, function()
        local target = vim.tbl_extend('force', ctx, prepared.opts)
        if prepared.explicit then target = github.resolve(target) end
        return M.load(prepared.opts, target)
      end, publish)
    end)
  end)
  pending = task
  if not task then vim.schedule(function() publish(false, err) end) end
  return handle
end

vim.api.nvim_create_autocmd('User', {
  group = vim.api.nvim_create_augroup('GitRelatedPRCache', { clear = true }), pattern = 'GitHubChanged',
  callback = function(ev) M.invalidate(ev.data and ev.data.root) end,
})

function M.label(pr)
  return ('#%d [%s] %s (%s → %s)'):format(pr.number,
    pr.isDraft and pr.state == 'OPEN' and 'draft' or pr.state:lower(), clean(pr.title),
    clean(pr.headRefName), clean(pr.baseRefName))
end
return M
