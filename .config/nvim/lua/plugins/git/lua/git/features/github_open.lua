local M = {}

local function git(root, args)
  local argv = { 'git' }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { cwd = root, text = true }):wait()
  if result.code ~= 0 then return nil end
  return vim.trim(result.stdout or '')
end

local function git_ok(root, args)
  local argv = { 'git' }
  vim.list_extend(argv, args)
  return vim.system(argv, { cwd = root }):wait().code == 0
end

local function github_remote(root, remote)
  local url = git(root, { 'remote', 'get-url', remote })
  if not url then return nil end
  local path = url:match('^git@github%.com:(.+)$')
    or url:match('^ssh://git@github%.com/(.+)$')
    or url:match('^https?://github%.com/(.+)$')
  if not path then return nil end
  path = path:gsub('/$', ''):gsub('%.git$', '')
  if not path:match('^[^/]+/[^/]+$') then return nil end
  return 'https://github.com/' .. path
end

local function encode_ref(ref)
  return vim.uri_encode(ref, 'rfc2396'):gsub('%%2[Ff]', '/')
end

local function remote_ref_url(root, ref, kind)
  local remote = ref:match('^([^/]+)/')
  local name = remote and ref:sub(#remote + 2)
  local base = remote and github_remote(root, remote)
  if not base or not name or name == '' then return nil end
  if not git_ok(root, { 'show-ref', '--verify', '--quiet', 'refs/remotes/' .. ref }) then return nil end
  return base .. '/' .. kind .. '/' .. encode_ref(name)
end

function M.branch_url(root, branch, branch_kind)
  if not root or not branch or branch == '' then return nil end
  if branch_kind == 'remote' then return remote_ref_url(root, branch, 'tree') end
  if branch_kind == 'tags' then return nil end
  local configured = git(root, { 'for-each-ref', '--format=%(push:short)|%(upstream:short)',
    'refs/heads/' .. branch }) or ''
  local push, upstream = configured:match('^([^|]*)|(.*)$')
  if push and push ~= '' then
    local url = remote_ref_url(root, push, 'tree')
    if url then return url end
  end
  if upstream and upstream:sub(-#branch - 1) == '/' .. branch then
    local url = remote_ref_url(root, upstream, 'tree')
    if url then return url end
  end
  local refs = git(root, { 'for-each-ref', '--format=%(refname:short)', 'refs/remotes' }) or ''
  local candidates = {}
  for ref in refs:gmatch('[^\n]+') do
    if ref:sub(-#branch - 1) == '/' .. branch then
      local url = remote_ref_url(root, ref, 'tree')
      if url then candidates[#candidates + 1] = url end
    end
  end
  if #candidates == 1 then return candidates[1] end
  return nil
end

function M.commit_url(root, commit)
  if not root or not commit or not commit:match('^%x+$') then return nil end
  local oid = git(root, { 'rev-parse', '--verify', commit .. '^{commit}' })
  if not oid then return nil end
  local refs = git(root, { 'for-each-ref', '--contains=' .. oid, '--format=%(refname:short)',
    'refs/remotes' }) or ''
  for ref in refs:gmatch('[^\n]+') do
    local remote = ref:match('^([^/]+)/')
    local base = remote and github_remote(root, remote)
    if base then return base .. '/commit/' .. oid end
  end
  return nil
end

function M.open(url, unavailable)
  if not url then
    vim.notify(unavailable or 'This item is not available on GitHub', vim.log.levels.WARN)
    return false
  end
  local _, err = vim.ui.open(url)
  if err then vim.notify('Could not open GitHub URL: ' .. err, vim.log.levels.ERROR); return false end
  return true
end

return M
