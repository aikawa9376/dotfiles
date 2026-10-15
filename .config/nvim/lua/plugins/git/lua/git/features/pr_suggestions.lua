-- Apply one explicit suggestion against a verified PR head, locally or remotely.
local M = {}
local github = require('git.features.github')
local actions = require('git.features.github_actions')
local commit = require('git.features.commit_model')
local function git(root, args)
  local value, err = commit.git(root, args)
  if not value then error(err, 0) end
  return value
end
function M.parse(body)
  local suggestions, active, fence, inside = {}, nil, nil, false
  for row, line in ipairs(vim.split((body or ''):gsub('\r\n', '\n'), '\n', { plain = true })) do
    if not inside then
      local ticks, suffix = line:match('^%s*(```+)(.*)$')
      local before, after
      if suffix then before, after = suffix:match('^suggestion:%-(%d+)%+(%d+)%s*$') end
      if ticks then
        inside, fence = true, #ticks
        if suffix:match('^suggestion%s*$') or before then
          active = { lines = {}, before = tonumber(before), after = tonumber(after), first_row = row }
        end
      end
    elseif line:match('^%s*`+%s*$') and #(line:match('`+') or '') >= fence then
      if active then active.last_row = row; suggestions[#suggestions + 1] = active end
      active, inside, fence = nil, false, nil
    elseif active then active.lines[#active.lines + 1] = line end
  end
  return suggestions
end
local function range(item, suggestion)
  local line = tonumber(github.scalar(item.line))
  if not line then return end
  return suggestion.before and line - suggestion.before or tonumber(github.scalar(item.start_line)) or line,
    suggestion.after and line + suggestion.after or line
end
-- REST diff_hunk is the historical patch at comment creation, even when the
-- current line has moved or disappeared. Never read today's file for this view.
local function original(item, suggestion)
  if item.subject_type == 'file' then return end
  local line = github.scalar(item.original_line)
  local start
  if line then start = github.scalar(item.original_start_line)
  else start = github.scalar(item.start_line) end
  local first, last = range({ line = line or github.scalar(item.line),
    start_line = start }, suggestion)
  if not first or first < 1 or last < first then return end
  local side = github.scalar(item.side)
  if side ~= 'LEFT' and side ~= 'RIGHT' then return end
  if start and github.scalar(item.start_side) and item.start_side ~= side then return end
  local source, old, new = {}, nil, nil
  for _, text in ipairs(vim.split((github.scalar(item.diff_hunk) or ''):gsub('\r\n', '\n'), '\n', { plain = true })) do
    local left, right = text:match('^@@ %-(%d+),?%d* %+(%d+),?%d* @@')
    if left then old, new = tonumber(left), tonumber(right)
    elseif old then
      local prefix = text:sub(1, 1)
      if prefix == ' ' or prefix == '+' or prefix == '-' then
        local at = side == 'LEFT' and old or new
        if prefix == ' ' or (side == 'LEFT' and prefix == '-') or (side == 'RIGHT' and prefix == '+') then
          source[at] = text:sub(2)
        end
        if prefix ~= '+' then old = old + 1 end
        if prefix ~= '-' then new = new + 1 end
      end
    end
  end
  local lines = {}
  for at = first, last do
    if source[at] == nil then return end
    lines[#lines + 1] = source[at]
  end
  return lines, first
end
-- Display only: retain the original comment body and action identity.
function M.display(item)
  local body = vim.split((item.body or ''):gsub('\r\n', '\n'), '\n', { plain = true })
  local lines, highlights, hunks, next_row = {}, {}, {}, 1
  for _, suggestion in ipairs(M.parse(item.body)) do
    vim.list_extend(lines, vim.list_slice(body, next_row, suggestion.first_row - 1))
    local old, first = original(item, suggestion)
    if old then
      local width = 3
      for _, text in ipairs(vim.list_extend(vim.deepcopy(old), suggestion.lines)) do
        for ticks in text:gmatch('`+') do width = math.max(width, #ticks + 1) end
      end
      local fence = string.rep('`', width)
      local language = body[suggestion.first_row]:match('^%s*```+(.-)%s*$')
      lines[#lines + 1] = fence .. language
      local new_first = #suggestion.lines == 0 and first - 1 or first
      lines[#lines + 1] = ('@@ -%d,%d +%d,%d @@'):format(first, #old, new_first, #suggestion.lines)
      highlights[#highlights + 1] = { row = #lines, group = 'DiffChange' }
      local hunk = { filename = item.path, start_line = #lines, old_start = first, new_start = new_first, lines = {} }
      for _, change in ipairs({ { old, '-' }, { suggestion.lines, '+' } }) do
        for _, text in ipairs(change[1]) do
          lines[#lines + 1] = change[2] .. text
          hunk.lines[#hunk.lines + 1] = change[2] .. text
        end
      end
      hunks[#hunks + 1] = hunk
      lines[#lines + 1] = fence
    else
      lines[#lines + 1] = #suggestion.lines == 0
        and 'Suggestion deletes selected code (original lines unavailable).'
        or 'Suggestion (original lines unavailable):'
      vim.list_extend(lines, vim.list_slice(body, suggestion.first_row, suggestion.last_row))
    end
    next_row = suggestion.last_row + 1
  end
  vim.list_extend(lines, vim.list_slice(body, next_row))
  return lines, highlights, hunks
end
function M.replace(source, item, suggestion)
  assert(item.side == 'RIGHT' and tonumber(github.scalar(item.line)), 'Suggestion must target a current RIGHT-side line')
  assert(not source:find('\0', 1, true), 'Binary suggestions are unsupported')
  local first, last = range(item, suggestion)
  local crlf, eol = source:find('\r\n', 1, true) ~= nil, source:sub(-1) == '\n'
  local lines = vim.split(source:gsub('\r\n', '\n'), '\n', { plain = true })
  if eol then table.remove(lines) end
  assert(first >= 1 and last >= first and last <= #lines, 'Suggestion range is outside this file')
  local result = vim.list_slice(lines, 1, first - 1)
  vim.list_extend(result, suggestion.lines)
  vim.list_extend(result, vim.list_slice(lines, last + 1))
  local separator = crlf and '\r\n' or '\n'
  return table.concat(result, separator) .. (eol and #result > 0 and separator or ''), first, last
end
function M.prepare(ctx, item, suggestion)
  local fresh = require('git.features.pr_comment_actions').read(ctx, item)
  assert(fresh.body == item.body, 'Suggestion changed; reopen the comment')
  local pr = github.pr(ctx)
  assert(pr.state == 'OPEN', 'Suggestions can only be applied to an open PR')
  require('git.features.pr_model').fetch(ctx, pr)
  local path = fresh.path
  assert(type(path) == 'string' and path ~= '' and path:sub(1, 1) ~= '/' and not path:find('[\r\n%z]'), 'Invalid suggestion path')
  for part in path:gmatch('[^/]+') do assert(part ~= '..' and part ~= '.', 'Invalid suggestion path') end
  local tree = git(ctx.root, { '--literal-pathspecs', 'ls-tree', pr.headRefOid, '--', path })
  local mode = tree:match('^(%d+) blob ')
  assert(mode == '100644' or mode == '100755', 'Suggestion must target a regular tracked file')
  local original = git(ctx.root, { 'show', pr.headRefOid .. ':' .. path })
  local replacement, first, last = M.replace(original, fresh, suggestion)
  assert(original ~= replacement, 'This suggestion does not change the PR head')
  return { ctx = vim.deepcopy(ctx), item = vim.deepcopy(fresh), original = original, replacement = replacement,
    path = path, mode = mode, hash = pr.headRefOid, first = first, last = last }
end
local function current(plan)
  local fresh = require('git.features.pr_comment_actions').read(plan.ctx, plan.item)
  assert(fresh.body == plan.item.body and fresh.path == plan.path and fresh.line == plan.item.line
    and fresh.start_line == plan.item.start_line and fresh.side == plan.item.side, 'Suggestion changed; reopen it')
  local pr = github.pr(plan.ctx)
  assert(pr.state == 'OPEN' and pr.headRefOid == plan.hash, 'PR head changed; reopen the suggestion')
end
local function read(path)
  local fd = assert(vim.uv.fs_open(path, 'r', 0))
  local stat = assert(vim.uv.fs_fstat(fd))
  local data = assert(vim.uv.fs_read(fd, stat.size, 0)); vim.uv.fs_close(fd)
  return data, stat
end
function M.local_apply(plan)
  current(plan)
  local root = assert(vim.uv.fs_realpath(plan.ctx.root))
  local path = root .. '/' .. plan.path
  assert(vim.uv.fs_realpath(path) == path, 'Suggestion target follows a symlink or is missing')
  assert(vim.trim(git(root, { 'rev-parse', 'HEAD' })) == plan.hash, 'Check out the PR head or open its PR worktree first')
  assert(git(root, { 'show', ':' .. plan.path }) == plan.original, 'Target has staged changes; keep them before applying')
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.uv.fs_realpath(vim.api.nvim_buf_get_name(buf)) == path then
      assert(not vim.bo[buf].modified, 'Target has unsaved edits; save or keep them before applying')
    end
  end
  local source, stat = read(path)
  assert(stat.type == 'file' and source == plan.original, 'Target has local changes; keep them before applying')
  local temporary = path .. '.nvim-suggestion-' .. tostring(vim.uv.hrtime())
  local fd = assert(vim.uv.fs_open(temporary, 'wx', stat.mode))
  local ok, err = pcall(function()
    assert(vim.uv.fs_write(fd, plan.replacement, 0) == #plan.replacement, 'Could not write the full suggestion')
    assert(vim.uv.fs_fsync(fd)); assert(vim.uv.fs_close(fd)); fd = nil
    assert(read(path) == plan.original, 'Target changed during suggestion application')
    assert(vim.uv.fs_rename(temporary, path))
  end)
  if fd then vim.uv.fs_close(fd) end
  if not ok then vim.uv.fs_unlink(temporary); error(err, 0) end
  require('git.utils').fire_git_changed({ work_tree = root })
  vim.schedule(function() vim.cmd('silent! checktime') end)
  return path
end
function M.remote_apply(plan, message)
  current(plan)
  local pr = github.api(plan.ctx, ('repos/%s/pulls/%d'):format(plan.ctx.repo, plan.ctx.number))
  assert(pr.head and pr.head.sha == plan.hash and pr.head.repo and pr.head.repo.full_name, 'PR head repository is unavailable or changed')
  local lines = vim.split(message, '\n', { plain = true })
  local headline = table.remove(lines, 1)
  assert(headline and vim.trim(headline) ~= '', 'Commit message is required')
  local response = github.api(plan.ctx, 'graphql', {
    query = 'mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid url } } }',
    variables = { input = { branch = { repositoryNameWithOwner = pr.head.repo.full_name, branchName = pr.head.ref },
      expectedHeadOid = plan.hash, message = { headline = headline, body = table.concat(lines, '\n') },
      fileChanges = { additions = { { path = plan.path, contents = vim.base64.encode(plan.replacement) } } } } },
  })
  if response.errors then error(response.errors[1].message or 'Suggestion commit rejected', 0) end
  return assert(response.data and response.data.createCommitOnBranch and response.data.createCommitOnBranch.commit,
    'Suggestion commit response is unavailable')
end
function M.preview(plan)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].filetype = 'nofile', 'wipe', 'diff'
  local header = ('Suggestion · %s:L%d-L%d · head %s'):format(plan.path, plan.first, plan.last, plan.hash:sub(1, 7))
  local patch = vim.diff(plan.original, plan.replacement, { result_type = 'unified' })
  local lines = { header, 'l apply locally · g commit on GitHub · q close', '' }
  vim.list_extend(lines, vim.split(patch, '\n', { plain = true }))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable, vim.bo[buf].readonly = false, true
  if vim.api.nvim_win_get_config(0).relative ~= '' then
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_config(win).relative == '' then vim.api.nvim_set_current_win(win); break end
    end
  end
  vim.cmd('botright split'); vim.api.nvim_win_set_buf(0, buf)
  local running = false
  vim.keymap.set('n', 'q', function() if not running then vim.api.nvim_buf_delete(buf, { force = true }) end end, { buffer = buf })
  vim.keymap.set('n', 'l', function()
    if running then return end
    running = true
    actions.run(plan.ctx, function() return M.local_apply(plan) end, function()
      vim.notify('Suggestion applied locally; commit and push when ready')
      if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
    end, false, function() running = false end)
  end, { buffer = buf, desc = 'Apply suggestion locally without commit or push' })
  vim.keymap.set('n', 'g', function()
    if running then return end
    require('git.features.pr_composer').open({ ctx = plan.ctx, title = 'Commit suggestion on GitHub',
      body = 'Apply review suggestion', history = { plan.item }, prefix = { header }, action = 'commit', success = 'Suggestion committed on GitHub',
      submit = function(_, message) return M.remote_apply(plan, message) end })
  end, { buffer = buf, desc = 'Commit suggestion directly to the PR branch on GitHub' })
  return buf
end
function M.choose(ctx, item)
  local choices = M.parse(item.body)
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local function choose(suggestion)
    if not suggestion then return end
    actions.run(ctx, function(target) return M.prepare(target, item, suggestion) end, function(plan)
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf and vim.api.nvim_get_current_win() == win then M.preview(plan) end
    end)
  end
  if #choices == 1 then return choose(choices[1]) end
  vim.ui.select(choices, { prompt = 'Suggested change', format_item = function(suggestion)
    return table.concat(suggestion.lines, ' ')
  end }, choose)
end
return M
