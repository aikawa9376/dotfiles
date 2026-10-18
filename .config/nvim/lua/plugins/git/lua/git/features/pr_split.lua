-- Explicit PR-status handoff for immutable native two-pane comparisons.
-- No PR discovery: coordinates belong to this captured merge-base/head pair.
local M = {}
local api = vim.api
local model_api = require('git.features.pr_model')
local preview = require('git.features.pr_comment_preview')
local states, windows = {}, {}
local ns = api.nvim_create_namespace('git_pr_split')
local function valid(p)
  return p and states[p.state.tab] == p.state and api.nvim_win_is_valid(p.win)
    and api.nvim_win_get_buf(p.win) == p.buf and vim.wo[p.win].diff
    and api.nvim_buf_get_changedtick(p.buf) == p.tick
end
local function active()
  local p = windows[api.nvim_get_current_win()]
  if valid(p) then return p end
  vim.notify('This window no longer matches the PR diff; reopen it from PR status', vim.log.levels.WARN)
end
local function viewer(s) return s.model.review and s.model.review.viewer end
local function anchored(p, thread)
  local s = p.state
  if p.missing or (thread.path ~= s.entry.path and thread.path ~= s.entry.old_path)
    or thread.side ~= p.side or not thread.line or thread.line < 1 or thread.line > p.count
    or (thread.start_line or thread.line) < 1 or (thread.start_line or thread.line) > thread.line then return false end
  local status = s.model.thread_status
  local remote = status and status.head == s.hash and status.by_id[thread.id]
  if remote then return remote.isOutdated == false and remote.subjectType == 'LINE' and remote.path == thread.path end
  -- Legacy servers may omit GraphQL draft anchors. Only current-head originals
  -- can fall back to the existing native draft coordinate normalization.
  if thread.pending then
    local comment = thread.comments[1]
    local scalar = require('git.features.github').scalar
    local pending = s.model.review and s.model.review.pending
    return (scalar(comment.original_commit_id) or scalar(comment.commit_id) or pending and pending.commit_id) == s.hash
  end
  return false
end
local function selected(p, row)
  local result = {}
  for _, thread in ipairs(p.state.model.threads or {}) do
    if anchored(p, thread) and (thread.start_line or thread.line) <= row and row <= thread.line then
      result[#result + 1] = thread
    end
  end
  return result
end
local function stop(s)
  if states[s.tab] ~= s then return end
  states[s.tab] = nil
  if s.task then s.task.cancel() end
  for _, p in ipairs(s.panes) do
    windows[p.win] = nil
    preview.close(p.buf)
    if api.nvim_win_is_valid(p.win) and vim.wo[p.win].winbar == p.bar then vim.wo[p.win].winbar = p.old_bar end
    if api.nvim_buf_is_valid(p.buf) then
      api.nvim_buf_call(p.buf, function()
        for _, map in ipairs(p.maps) do
          local current = vim.fn.maparg(map.key, map.mode, false, true)
          if current.callback == map.callback then
            vim.keymap.del(map.mode, map.key, { buffer = p.buf })
            if map.old then vim.fn.mapset(map.mode, false, map.old) end
          end
        end
      end)
    end
  end
  vim.cmd('redraw')
end
local function live(s)
  if not s or states[s.tab] ~= s then return false end
  for _, p in ipairs(s.panes) do if not valid(p) then stop(s); return false end end
  return true
end
local function paint(s)
  for _, p in ipairs(s.panes) do
    preview.close(p.buf)
    p.rows = {}
    if valid(p) and not s.stale then
      for _, thread in ipairs(s.model.threads or {}) do
        if anchored(p, thread) then
          p.rows[thread.line] = p.rows[thread.line] or {}
          p.rows[thread.line][#p.rows[thread.line] + 1] = thread
        end
      end
      local errors = s.model.comments_error or s.model.review_error or s.model.thread_status_error
      p.bar = ('PR #%d · %s · %s%s'):format(s.model.ctx.number, s.entry.path:gsub('[%z\1-\31\127]', ' '), p.side,
        errors and ' · comments incomplete (R retry)' or ' · gk comment · gct threads · ? help'):gsub('%%', '%%%%')
    else p.bar = 'PR comparison changed · reopen from PR status' end
    if api.nvim_win_is_valid(p.win) then vim.wo[p.win].winbar = p.bar end
  end
  vim.cmd('redraw')
end
local function usable(p)
  if not p then return end
  if p.state.stale then vim.notify('PR comparison changed; reopen the diff from PR status', vim.log.levels.WARN); return end
  return p.state
end
function M.refresh(s)
  if not live(s) or s.loading then return end
  s.loading = true
  s.task = require('git.features.github_actions').run(s.model.ctx, function(ctx)
    local model = model_api.load(ctx, { previous = s.model, expanded = { [s.entry.path] = true } })
    return model
  end, function(model)
    if not live(s) then return end
    s.loading, s.task = false, nil
    -- The panes are immutable. New API anchors must never decorate old code.
    s.stale = model.hash ~= s.hash or model.base ~= s.base or model.pr.baseRefOid ~= s.base_oid
    s.model = model
    paint(s)
    if s.reload then s.reload = false; M.refresh(s) end
  end, false, function()
    if states[s.tab] == s then
      s.loading, s.task = false, nil
      if s.reload then s.reload = false; M.refresh(s) end
    end
  end)
end
function M.open(focus)
  local p = active()
  local s = usable(p)
  if not s then return end
  local threads = selected(p, api.nvim_win_get_cursor(p.win)[1])
  if #threads == 0 then vim.notify('No review comments on this line · gct lists all threads'); return end
  preview.show({ buf = p.buf, win = p.win, ctx = s.model.ctx, viewer = viewer(s), threads = threads,
    focus = focus, reply = function() M.reply() end, resolve = function() M.resolve() end, navigate = M.navigate })
end
function M.reply()
  local p = active(); local s = usable(p)
  if s then require('git.features.pr_threads').select(s.model.ctx, selected(p, vim.fn.line('.')), viewer(s)) end
end
function M.resolve()
  local p = active(); local s = usable(p)
  if s then require('git.features.pr_thread_status').toggle(s.model.ctx, selected(p, vim.fn.line('.'))) end
end
function M.actions()
  local p = active(); local s = usable(p)
  if not s then return end
  local comments = {}
  for _, thread in ipairs(selected(p, vim.fn.line('.'))) do
    for _, comment in ipairs(thread.comments) do
      local copy = vim.deepcopy(comment)
      copy.kind, copy.review_id = 'inline', thread.review_id
      comments[#comments + 1] = copy
    end
  end
  require('git.features.pr_comment_actions').select(s.model.ctx, comments, viewer(s))
end
function M.navigate(direction, count)
  local p = active(); local s = usable(p)
  if not s then return end
  local targets = {}
  -- Logical LEFT then RIGHT order is independent of split geometry/window IDs.
  for _, pane in ipairs(s.panes) do
    if valid(pane) then
      local rows = vim.tbl_keys(pane.rows); table.sort(rows)
      for _, row in ipairs(rows) do targets[#targets + 1] = { pane = pane, row = row } end
    end
  end
  if #targets == 0 then vim.notify('No line comments in this file · gct lists all threads'); return end
  local row, index = api.nvim_win_get_cursor(p.win)[1], direction > 0 and #targets or 1
  if direction > 0 then
    for i, target in ipairs(targets) do
      if target.pane.order > p.order or target.pane == p and target.row > row then index = i - 1; break end
    end
  else
    for i = #targets, 1, -1 do
      local target = targets[i]
      if target.pane.order < p.order or target.pane == p and target.row < row then index = i + 1; break end
    end
  end
  index = math.max(1, math.min(#targets, index + direction * (count or vim.v.count1)))
  local target = targets[index]
  api.nvim_set_current_win(target.pane.win); api.nvim_win_set_cursor(target.pane.win, { target.row, 0 })
  M.open(false)
end
function M.list()
  local p = active(); if not p then return end
  local s = p.state
  -- Even a stale comparison retains access to file-level/outdated histories.
  local threads = s.model.threads or {}
  if #threads == 0 then vim.notify(s.model.comments_error or 'No PR review threads'); return end
  vim.ui.select(threads, { prompt = 'PR review threads (including file-level / outdated)', format_item = function(thread)
    return require('git.features.pr_thread_status').label(thread) .. ' · '
      .. require('git.features.pr_comment_location').format(thread, 'file / outdated') .. ' · '
      .. (thread.comments[1].body or ''):gsub('[\r\n]', ' ')
  end }, function(thread)
    if not thread or not valid(p) or api.nvim_get_current_win() ~= p.win then return end
    require('git.features.pr_threads').open(s.model.ctx, thread, viewer(s))
  end)
end
function M.target(p, first, last)
  if not valid(p) or p.state.stale then return nil, 'Reopen the PR diff before commenting' end
  local coordinates = p.state.coordinates
  if not coordinates then return nil, 'PR patch is loading; retry shortly' end
  if first < 1 or last < first or last > p.count or p.missing then return nil, 'Select existing PR diff lines' end
  for row = first, last do
    if not coordinates[p.side][row] then return nil, 'Select lines inside one PR diff hunk' end
  end
  if coordinates[p.side][first] ~= coordinates[p.side][last] then return nil, 'Select lines inside one PR diff hunk' end
  return { path = p.state.entry.path, side = p.side, line = last,
    start_line = first ~= last and first or nil, start_side = first ~= last and p.side or nil }
end
local function new_comment(destination, visual)
  local p = active(); local s = usable(p)
  if not s then return end
  local first, last = vim.fn.line('.'), vim.fn.line('.')
  if visual then first, last = math.min(vim.fn.line('v'), first), math.max(vim.fn.line('v'), first); vim.cmd('normal! \27') end
  local target, err
  if destination ~= 'p' then target, err = M.target(p, first, last) end
  if err then vim.notify(err, vim.log.levels.WARN); return end
  require('git.features.pr_review').new_comment(s.model, target, { destination = destination })
end
local function bind(p, mode, key, callback, desc)
  local old = api.nvim_buf_call(p.buf, function() return vim.fn.maparg(key, mode, false, true) end)
  local wrapped = function() if active() == p then callback() end end
  p.maps[#p.maps + 1] = { mode = mode, key = key, old = old.buffer == 1 and old or nil, callback = wrapped }
  vim.keymap.set(mode, key, wrapped, { buffer = p.buf, silent = true, desc = desc })
end
local function setup()
  if M.group then return end
  M.group = api.nvim_create_augroup('GitPrSplit', { clear = true })
  api.nvim_set_decoration_provider(ns, { on_win = function(_, win, buf)
    local p = windows[win]; return valid(p) and p.buf == buf and not p.state.stale or false
  end, on_line = function(_, win, buf, row)
    local p = windows[win]
    if not valid(p) or p.state.stale or p.buf ~= buf or not p.rows[row + 1] then return end
    local public, pending, resolved = 0, 0, 0
    for _, thread in ipairs(p.rows[row + 1]) do
      if thread.pending then pending = pending + 1 else public = public + 1 end
      if not thread.pending and thread.has_pending then pending = pending + 1 end
      if thread.resolved then resolved = resolved + 1 end
    end
    local text = {}
    if public > 0 then text[#text + 1] = { ' 💬 ' .. public, 'DiagnosticInfo' } end
    if pending > 0 then text[#text + 1] = { ' 📝 ' .. pending .. ' [pending]', 'DiagnosticWarn' } end
    if resolved > 0 then text[#text + 1] = { ' ✅ ' .. resolved, 'GitPrPositive' } end
    api.nvim_buf_set_extmark(buf, ns, row, 0, { ephemeral = true, virt_text = text, virt_text_pos = 'eol', priority = 210 })
  end })
  local function sweep()
    for _, s in pairs(states) do
      for _, p in ipairs(s.panes) do if not valid(p) then stop(s); break end end
    end
  end
  api.nvim_create_autocmd({ 'WinClosed', 'BufWinEnter', 'BufWipeout', 'TabEnter', 'TextChanged', 'TextChangedI' },
    { group = M.group, callback = function() vim.schedule(sweep) end })
  api.nvim_create_autocmd('OptionSet', { group = M.group, pattern = 'diff', callback = function() vim.schedule(sweep) end })
  api.nvim_create_autocmd('User', { group = M.group, pattern = 'GitHubChanged', callback = function(ev)
    local ctx = ev.data or {}
    for _, s in pairs(states) do
      if ctx.resource_kind ~= 'issue' and ctx.host == s.model.ctx.host and ctx.repo == s.model.ctx.repo and (not ctx.number or ctx.number == s.model.ctx.number) then
        if s.loading then s.reload = true else M.refresh(s) end
      end
    end
  end })
end
function M.attach(model, entry, left, right, source)
  setup()
  local tab = api.nvim_win_get_tabpage(left)
  if states[tab] then stop(states[tab]) end
  local s = { tab = tab, model = model, entry = entry, hash = model.hash, base = model.base,
    base_oid = model.pr.baseRefOid, source = source, panes = {} }
  states[tab] = s
  for i, win in ipairs({ left, right }) do
    local buf = api.nvim_win_get_buf(win)
    local p = { win = win, buf = buf, tick = api.nvim_buf_get_changedtick(buf), count = api.nvim_buf_line_count(buf),
      side = i == 1 and 'LEFT' or 'RIGHT', order = i, state = s, maps = {}, rows = {}, old_bar = vim.wo[win].winbar,
      missing = i == 1 and entry.status == 'A' or i == 2 and entry.status == 'D' }
    s.panes[i], windows[win] = p, p
    for key, fn in pairs({ gk = function() M.open(true) end, gc = M.reply, gA = M.actions, gR = M.resolve, gct = M.list,
      R = function() M.refresh(s) end, gx = function()
        local threads = not s.stale and selected(p, vim.fn.line('.')) or {}
        vim.ui.open(threads[1] and threads[1].url or s.model.ctx.url)
      end, gp = function() require('git.features.pr').open(s.model.ctx) end,
      gr = function() if usable(p) then require('git.features.pr_review').menu(s.model) end end,
      q = function()
        stop(s)
        for _, pane in ipairs(s.panes) do
          if api.nvim_win_is_valid(pane.win) and api.nvim_win_get_buf(pane.win) == pane.buf then api.nvim_win_close(pane.win, true) end
        end
        if source and api.nvim_win_is_valid(source) then api.nvim_set_current_win(source) end
      end,
      ['?'] = function() require('git.features.help').show_text('PR split diff', {
        'gk          Preview conversation; repeat to focus', 'gc          Read / reply or edit pending draft',
        'gA          Reactions / edit / delete / suggestion', 'gR          Resolve / reopen thread',
        ']t / [t     Next / previous comment (both sides)', 'gct         All PR threads, including file / outdated',
        'gC          New comment destination', 'gcn / gcr   Immediate / pending review comment',
        'gcp         PR conversation comment', 'gr          Review menu', 'gx / gp     Browser / PR status',
        'R / q       Refresh comments / close owned diff panes',
        'Visual gC / gcn / gcr  Comment on a range in one hunk',
      }) end }) do bind(p, 'n', key, fn, 'PR split: ' .. key) end
    for key, direction in pairs({ [']t'] = 1, ['[t'] = -1, [']C'] = 1, ['[C'] = -1 }) do
      bind(p, 'n', key, function() M.navigate(direction, vim.v.count1) end, 'Move to PR comment')
    end
    for _, key in ipairs({ 'gC', 'gcn', 'gcr', 'gcp' }) do
      local destination = ({ gcn = 'c', gcr = 'r', gcp = 'p' })[key]
      bind(p, 'n', key, function() new_comment(destination) end, 'New PR comment')
      bind(p, 'x', key, function() new_comment(destination, true) end, 'Comment on selected PR lines')
    end
  end
  paint(s)
  local task = require('git.features.async').run(model.root, function()
    local patch, err = require('git.features.commit_model').patch(model, entry)
    assert(patch, err)
    local coords, hunk = { LEFT = {}, RIGHT = {} }, 0
    local rows = model_api.coordinates(patch)
    for row, line in ipairs(patch) do
      if line:match('^@@') then hunk = hunk + 1 end
      local at = rows[row]
      if at then
        if at.left then coords.LEFT[at.left] = hunk end
        if at.right then coords.RIGHT[at.right] = hunk end
      end
    end
    return coords
  end, function(ok, coords)
    if not live(s) then return end
    s.task, s.loading = nil, false
    if ok then s.coordinates = coords else vim.notify(tostring(coords), vim.log.levels.WARN) end
    if s.reload then s.reload = false; M.refresh(s) end
  end)
  if task and not task.completed then s.task, s.loading = task, true end
  return s
end
M._states, M._windows, M._valid, M._namespace = states, windows, valid, ns
return M
