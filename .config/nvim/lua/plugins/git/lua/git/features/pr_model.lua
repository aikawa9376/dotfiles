local M = {}
local github = require('git.features.github')
local commit = require('git.features.commit_model')
local function git(root, args)
  local result, err = commit.git(root, args)
  if not result then error(err, 0) end
  return vim.trim(result)
end
-- Use configured SSH/HTTPS transport when it names the resolved base repository.
function M.remote(ctx)
  local remotes = git(ctx.root, { 'remote' })
  for remote in remotes:gmatch('[^\n]+') do
    local url = git(ctx.root, { 'remote', 'get-url', remote })
    local host, repo = url:match('^https?://([^/]+)/(.+)$')
    if not host then host, repo = url:match('^ssh://[^@]+@([^/]+)/(.+)$') end
    if not host then host, repo = url:match('^[^@]+@([^:]+):(.+)$') end
    if host == ctx.host and repo and repo:gsub('%.git$', '') == ctx.repo then return remote end
  end
  return ('https://%s/%s.git'):format(ctx.host, ctx.repo)
end
function M.fetch(ctx, pr)
  assert(type(pr.baseRefOid) == 'string' and pr.baseRefOid:match('^%x+$'), 'Invalid PR base SHA')
  assert(type(pr.headRefOid) == 'string' and pr.headRefOid:match('^%x+$'), 'Invalid PR head SHA')
  -- Private refs never check out or alter the caller's branch/index/worktree.
  local prefix = ('refs/nvim-pr/%s/%s/%d'):format(ctx.host, ctx.repo, pr.number)
  git(ctx.root, { 'check-ref-format', 'refs/heads/' .. pr.baseRefName })
  git(ctx.root, { 'fetch', '--no-tags', M.remote(ctx),
    '+refs/heads/' .. pr.baseRefName .. ':' .. prefix .. '/base',
    '+refs/pull/' .. pr.number .. '/head:' .. prefix .. '/head' })
  local base = git(ctx.root, { 'rev-parse', prefix .. '/base' })
  local head = git(ctx.root, { 'rev-parse', prefix .. '/head' })
  if base ~= pr.baseRefOid or head ~= pr.headRefOid then
    error('PR changed while fetching; refresh to load its current revisions', 0)
  end
  return git(ctx.root, { 'merge-base', base, head }), head
end
function M.threads(ctx)
  local pages = github.json(ctx, { 'api', '--hostname', ctx.host, '--paginate', '--slurp',
    ('repos/%s/pulls/%d/comments?per_page=100'):format(ctx.repo, ctx.number) })
  local by_id, threads = {}, {}
  for _, page in ipairs(pages) do
    for _, comment in ipairs(page) do
      by_id[comment.id] = comment
      if comment.in_reply_to_id == nil or comment.in_reply_to_id == vim.NIL then
        threads[#threads + 1] = { id = comment.id, path = comment.path, side = comment.side,
          line = comment.line ~= vim.NIL and comment.line or nil,
          start_line = comment.start_line ~= vim.NIL and comment.start_line or nil,
          comments = { comment }, url = comment.html_url }
      end
    end
  end
  local indexed = {}
  for _, thread in ipairs(threads) do indexed[thread.id] = thread end
  for _, page in ipairs(pages) do
    for _, comment in ipairs(page) do
      local parent = by_id[comment.in_reply_to_id]
      local seen = {}
      while parent and parent.in_reply_to_id and parent.in_reply_to_id ~= vim.NIL and not seen[parent.id] do
        seen[parent.id] = true; parent = by_id[parent.in_reply_to_id]
      end
      local thread = parent and indexed[parent.id]
      if thread then thread.comments[#thread.comments + 1] = comment end
    end
  end
  return threads
end
function M.load(ctx)
  local pr = github.pr(ctx)
  local base, head = M.fetch(ctx, pr)
  local model, err = commit.changes({ root = ctx.root, base = base, hash = head, pr = pr, ctx = ctx })
  if not model then error(err, 0) end
  -- Comment permissions/network failures must not hide otherwise readable diffs.
  local ok, threads = pcall(M.threads, ctx)
  model.threads, model.comments_error = ok and threads or {}, not ok and tostring(threads) or nil
  return model
end
function M.coordinates(patch)
  local rows, old, new = {}, nil, nil
  for i, line in ipairs(patch) do
    local a, b = line:match('^@@ %-(%d+),?%d* %+(%d+),?%d* @@')
    if a then old, new = tonumber(a), tonumber(b)
    elseif old and line:sub(1, 1) ~= '\\' then
      local prefix = line:sub(1, 1)
      rows[i] = { left = prefix ~= '+' and old or nil, right = prefix ~= '-' and new or nil }
      if prefix ~= '+' then old = old + 1 end
      if prefix ~= '-' then new = new + 1 end
    end
  end
  return rows
end
function M.threads_at(model, entry, coordinate)
  local found = {}
  for _, thread in ipairs(model.threads or {}) do
    if thread.path == entry.path or thread.path == entry.old_path then
      local line
      if coordinate then line = thread.side == 'LEFT' and coordinate.left or nil
        if thread.side ~= 'LEFT' then line = coordinate.right end
      end
      if not coordinate or (thread.line and line and line >= (thread.start_line or thread.line) and line <= thread.line) then
        found[#found + 1] = thread
      end
    end
  end
  return found
end
return M
