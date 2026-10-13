local M = {}
local github = require('git.features.github')
local commit = require('git.features.commit_model')
local async = require('git.features.async')
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
  local refs = git(ctx.root, { 'for-each-ref', '--format=%(refname) %(objectname)', prefix .. '/' })
  local cached = {}
  for ref, oid in refs:gmatch('([^\n ]+) (%x+)') do cached[ref] = oid end
  -- Fresh API SHAs define the snapshot. Only our verified private refs can
  -- bypass the network fetch.
  if cached[prefix .. '/base'] == pr.baseRefOid and cached[prefix .. '/head'] == pr.headRefOid then
    return git(ctx.root, { 'merge-base', pr.baseRefOid, pr.headRefOid }), pr.headRefOid
  end
  -- API base SHAs can lag the current base branch even for open PRs. Fetch
  -- that exact revision, rather than treating branch advancement as PR drift.
  -- Closed PR heads are historical too; open heads still use the advertised
  -- PR ref so a push during loading cannot mix snapshots.
  local historical = pr.state == 'MERGED' or pr.state == 'CLOSED'
  local head_source = historical and pr.headRefOid or 'refs/pull/' .. pr.number .. '/head'
  git(ctx.root, { 'fetch', '--no-tags', M.remote(ctx),
    '+' .. pr.baseRefOid .. ':' .. prefix .. '/base',
    '+' .. head_source .. ':' .. prefix .. '/head' })
  local base = git(ctx.root, { 'rev-parse', prefix .. '/base' })
  local head = git(ctx.root, { 'rev-parse', prefix .. '/head' })
  if base ~= pr.baseRefOid or head ~= pr.headRefOid then
    error('PR changed while fetching; refresh to load its current revisions', 0)
  end
  return git(ctx.root, { 'merge-base', base, head }), head
end
function M.threads(ctx, pending, hash, pages)
  pages = pages or github.json(ctx, { 'api', '--hostname', ctx.host, '--paginate', '--slurp',
    ('repos/%s/pulls/%d/comments?per_page=100'):format(ctx.repo, ctx.number) })
  if pending then
    -- The review endpoint includes the viewer's unpublished comments. Merge
    -- them once even on servers that also return them in the public listing.
    local ids = {}
    for _, comment in ipairs(pending.comments) do ids[comment.id] = true; comment.pending = true end
    for i, page in ipairs(pages) do
      pages[i] = vim.tbl_filter(function(comment) return not ids[comment.id] end, page)
    end
    pages[#pages + 1] = pending.comments
  end
  local by_id, threads = {}, {}
  local function make_thread(comment)
    local line, start = github.scalar(comment.line), github.scalar(comment.start_line)
    -- Unpublished REST comments may lack displayed coordinates. Original
    -- coordinates are safe only when they belong to the displayed revision.
    local revision = github.scalar(comment.original_commit_id) or github.scalar(comment.commit_id)
      or (comment.pending and pending.commit_id)
    if comment.pending and hash and revision == hash and comment.subject_type ~= 'file' then
      if not line then
        line, start = github.scalar(comment.original_line), github.scalar(comment.original_start_line)
      elseif line == github.scalar(comment.original_line) and not start then
        start = github.scalar(comment.original_start_line)
      end
    end
    local result = { id = comment.id, path = comment.path, side = comment.side,
      line = line, start_line = start, comments = { comment }, url = comment.html_url,
      pending = comment.pending, review_id = comment.pending and pending.id or nil }
    threads[#threads + 1] = result
    return result
  end
  for _, page in ipairs(pages) do
    for _, comment in ipairs(page) do
      by_id[comment.id] = comment
      if comment.in_reply_to_id == nil or comment.in_reply_to_id == vim.NIL then
        make_thread(comment)
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
      if thread then thread.comments[#thread.comments + 1] = comment
      elseif comment.pending and github.scalar(comment.in_reply_to_id) then
        -- Keep a private reply accessible even if its public parent is not in
        -- the listing (permissions, deletion or server pagination differences).
        make_thread(comment)
      end
    end
  end
  for _, thread in ipairs(threads) do
    for _, comment in ipairs(thread.comments) do if comment.pending then thread.has_pending = true end end
  end
  return threads
end
function M.load(ctx, opts)
  opts = opts or {}
  local pr = github.pr(ctx)
  local reads = async.gather({
    function()
      local base, head = M.fetch(ctx, pr)
      local model = { root = ctx.root, base = base, hash = head, pr = pr, ctx = ctx }
      local previous = opts.previous
      if previous and previous.root == ctx.root and previous.base == base and previous.hash == head then
        -- Reuse immutable diffs, including lazy patches; mutable API state is
        -- always reloaded and entries belong to the new snapshot.
        model.entries = {}
        for i, entry in ipairs(previous.entries) do model.entries[i] = vim.tbl_extend('force', {}, entry) end
        model.commit_count = previous.commit_count
        model.commits = previous.commits
      else
        local err
        model, err = commit.changes(model)
        if not model then error(err, 0) end
      end
      if not model.commits then model.commits = require('git.features.pr_commits').load(ctx.root, base, head) end
      model.commit_count = #model.commits
      -- Expanded files must not block the UI with synchronous patch reads
      -- when a refresh brings new revisions. Collapsed files stay lazy.
      for _, entry in ipairs(model.entries) do
        if opts.expanded and opts.expanded[entry.path] then
          local patch, err = commit.patch(model, entry)
          if not patch then error(err, 0) end
        end
      end
      return model
    end,
    function() return require('git.features.pr_review_model').load(ctx) end,
    function()
      return github.json(ctx, { 'api', '--hostname', ctx.host, '--paginate', '--slurp',
        ('repos/%s/pulls/%d/comments?per_page=100'):format(ctx.repo, ctx.number) })
    end,
    function() return require('git.features.pr_thread_status').load(ctx) end,
    function() return require('git.features.pr_viewed_state').load(ctx) end,
    function() return require('git.features.pr_conversation').load(ctx) end,
    function() return require('git.features.pr_timeline').load(ctx, pr.headRefOid) end,
  })
  if not reads[1].ok then error(reads[1].value, 0) end
  local model = reads[1].value
  -- Cached Git entries must not retain old viewer state after a failed read.
  for _, entry in ipairs(model.entries) do entry.viewed_state = nil end
  -- Comment permissions/network failures must not hide otherwise readable diffs.
  local review_ok, review = reads[2].ok, reads[2].value
  model.review, model.review_error = review_ok and review or nil, not review_ok and tostring(review) or nil
  local conversation_ok, conversation = reads[6].ok, reads[6].value
  local errors = {}
  if not conversation_ok then errors[#errors + 1] = 'PR comments unavailable: ' .. tostring(conversation) end
  if not review_ok then errors[#errors + 1] = 'Review summaries unavailable: ' .. tostring(review) end
  local timeline_ok, timeline = reads[7].ok, reads[7].value
  if not timeline_ok then errors[#errors + 1] = 'PR timeline unavailable: ' .. tostring(timeline) end
  model.conversation = require('git.features.pr_conversation').build(ctx,
    conversation_ok and conversation or {}, review_ok and review.reviews or {}, errors, timeline_ok and timeline or nil)
  local viewed_ok, viewed = reads[5].ok, reads[5].value
  if viewed_ok then viewed_ok, viewed = pcall(require('git.features.pr_viewed_state').apply, model, viewed) end
  if not viewed_ok then model.viewed_error = tostring(viewed) end
  local ok, pages = reads[3].ok, reads[3].value
  local pending = model.review and model.review.pending
  local grouped, threads = pcall(M.threads, ctx, pending, model.hash, ok and pages or {})
  model.threads = grouped and threads or {}
  model.comments_error = not ok and tostring(pages) or not grouped and tostring(threads) or nil
  -- A failed public-comment read must not hide already fetched private drafts.
  if not grouped and pending then model.threads = M.threads(ctx, pending, model.hash, {}) end
  local status_ok, status = reads[4].ok, reads[4].value
  model.thread_status, model.thread_status_error = status_ok and status or nil, not status_ok and tostring(status) or nil
  if status_ok then
    for _, thread in ipairs(model.threads) do
      local remote = status.by_id[thread.id]
      if remote then
        if not remote.pending then thread.node_id, thread.resolved = remote.id, remote.isResolved end
        -- Review-specific REST listings can omit all line/side fields. Use the
        -- current GraphQL thread anchor only when it belongs to this snapshot.
        if status.head == model.hash and remote.path == thread.path then
          thread.line, thread.start_line = nil, nil
          if remote.isOutdated == false and remote.subjectType == 'LINE' then
            thread.line, thread.start_line = github.scalar(remote.line), github.scalar(remote.startLine)
            thread.side = github.scalar(remote.diffSide)
          end
        end
      end
    end
  end
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
