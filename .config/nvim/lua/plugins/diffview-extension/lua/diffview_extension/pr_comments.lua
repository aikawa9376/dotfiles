-- Public GitHub threads are projected onto confirmed, unchanged Diffview code.
-- Decorations belong to windows, since worktree buffers can also be ordinary
-- editor buffers and the same revision can appear in several comparisons.
local M = {}
local api = vim.api
local async = require('git.features.async')
local related = require('diffview_extension.github_context')
local model = require('diffview_extension.pr_comment_model')
local projection = require('diffview_extension.comment_projection')
local ns = api.nvim_create_namespace('diffview_extension_pr_comments')
local states, windows = {}, {}
local function current_view()
  local lib = package.loaded['diffview.lib']
  return lib and lib.get_current_view()
end
local function redraw(state)
  local view = state.view
  if view.panel and view.panel.bufid and api.nvim_buf_is_valid(view.panel.bufid) then
    view.panel:render(); view.panel:redraw()
  end
  vim.cmd('redraw')
end
local function clear_plans(state)
  for win, plan in pairs(state.plans or {}) do
    if windows[win] == plan then windows[win] = nil end
    require('git.features.pr_comment_preview').close(plan.buf)
  end
  state.plans = {}
end
local function stop(tab)
  local state = states[tab]
  if not state then return end
  states[tab] = nil
  for _, task in ipairs({ state.task or false, state.projection_task or false }) do if task then task.cancel() end end
  clear_plans(state)
  state.view._github_comment_summary, state.view._github_comment_hint = nil, nil
end
local function panes(view)
  local result = {}
  local entry = view.cur_entry or view.panel and view.panel.cur_item and view.panel.cur_item[2]
  local layout = view.cur_layout
  -- A three/four-pane conflict has no faithful PR LEFT/RIGHT interpretation.
  if not entry or not layout or #layout.windows ~= 2 then return result end
  for _, window in ipairs(layout.windows) do
    local file, win = window.file, window.id
    if file and win and api.nvim_win_is_valid(win) and file.bufnr and api.nvim_buf_is_loaded(file.bufnr)
      and api.nvim_win_get_buf(win) == file.bufnr and not file.nulled
      and (file.symbol == 'a' or file.symbol == 'b')
      and api.nvim_buf_get_offset(file.bufnr, api.nvim_buf_line_count(file.bufnr)) <= 1024 * 1024 then
      result[#result + 1] = { win = win, buf = file.bufnr, path = entry.path,
        side = file.symbol == 'a' and 'LEFT' or 'RIGHT', tick = api.nvim_buf_get_changedtick(file.bufnr),
        lines = api.nvim_buf_get_lines(file.bufnr, 0, -1, false), rows = {}, ranges = {}, state = states[view.tabpage] }
    end
  end
  return result
end
local function valid(plan)
  return plan and states[plan.state.view.tabpage] == plan.state and plan.state.plans[plan.win] == plan
    and api.nvim_win_is_valid(plan.win) and api.nvim_win_get_buf(plan.win) == plan.buf
    and api.nvim_buf_is_valid(plan.buf) and api.nvim_buf_get_changedtick(plan.buf) == plan.tick
end
local function summarize(state)
  local summary, errors = {}, 0
  for _, snapshot in ipairs(state.snapshots or {}) do
    summary[snapshot.ctx.url] = '💬 ' .. #snapshot.threads
    errors = errors + #snapshot.errors
  end
  state.view._github_comment_summary = summary
  state.view._github_comment_hint = errors > 0 and 'Comments incomplete · gR retry · gct list'
    or 'gk comment · ]t/[t move · gct all threads'
end
function M.project(state)
  if not state or states[state.view.tabpage] ~= state or state.loading then return end
  if state.projection_task then state.projection_task.cancel(); state.projection_task = nil end
  clear_plans(state)
  state.generation = (state.generation or 0) + 1
  local generation, captured = state.generation, panes(state.view)
  local task = async.run(state.view.adapter.ctx.toplevel, function()
    for _, plan in ipairs(captured) do
      for _, snapshot in ipairs(state.snapshots) do
        local threads = vim.tbl_filter(function(thread)
          return thread.projectable and thread.path == plan.path and thread.side == plan.side
        end, snapshot.threads)
        if #threads > 0 then
          snapshot.sources = snapshot.sources or {}
          local key = plan.side .. ':' .. plan.path
          if snapshot.sources[key] == nil then snapshot.sources[key] = model.source(snapshot, plan.path, plan.side) or false end
          local source = snapshot.sources[key]
          if source then
            local mapping = projection.prepare(source, plan.lines)
            for _, thread in ipairs(threads) do
              local first, last = projection.range(mapping, thread.start_line or thread.line, thread.line)
              if first then
                local record = { snapshot = snapshot, thread = thread, first = first, last = last }
                plan.ranges[#plan.ranges + 1] = record
                plan.rows[last] = plan.rows[last] or {}; plan.rows[last][#plan.rows[last] + 1] = record
              end
            end
          end
        end
      end
    end
    return captured
  end, function(ok, plans)
    if states[state.view.tabpage] ~= state or generation ~= state.generation then return end
    state.projection_task = nil
    if ok then
      for _, plan in ipairs(plans) do
        state.plans[plan.win] = plan
        if valid(plan) then windows[plan.win] = plan else state.plans[plan.win] = nil end
      end
    end
    summarize(state); redraw(state)
  end)
  if task and not task.completed then state.projection_task = task end
end
function M.refresh(tab)
  stop(tab)
  local relationship = related.state(tab)
  if not relationship or relationship.loading or not relationship.result or #relationship.result.items == 0 then return end
  local state = { view = relationship.view, relationship = relationship, loading = true, snapshots = {}, plans = {} }
  states[tab] = state
  state.view._github_comment_hint = 'Loading PR comments…'
  local task = async.run(state.view.adapter.ctx.toplevel, function()
    local snapshots = {}
    for first = 1, #relationship.result.items, 4 do
      local reads = {}
      for index = first, math.min(first + 3, #relationship.result.items) do
        local pr = relationship.result.items[index]
        reads[#reads + 1] = function() return model.load(pr.ctx) end
      end
      for index, read in ipairs(async.gather(reads)) do
        local pr = relationship.result.items[first + index - 1]
        snapshots[#snapshots + 1] = read.ok and read.value or { ctx = pr.ctx, threads = {}, errors = { tostring(read.value) } }
      end
    end
    return snapshots
  end, function(ok, snapshots)
    if states[tab] ~= state or related.state(tab) ~= relationship or not api.nvim_tabpage_is_valid(tab) then return end
    state.task, state.loading = nil, false
    state.snapshots = ok and snapshots or {}
    summarize(state); M.project(state)
  end)
  if task and not task.completed then state.task = task end
end
local function active()
  local view = current_view()
  return view and states[view.tabpage]
end
local function show(record, source)
  if not record or not source then return end
  local snapshot, thread = record.snapshot, record.thread
  local buf = require('git.features.pr_comment_preview').show({ buf = source.buf, win = source.win,
    ctx = snapshot.ctx, viewer = snapshot.viewer, threads = { thread }, focus = true,
    reply = function() require('git.features.pr_threads').open(snapshot.ctx, thread, snapshot.viewer) end,
    resolve = function() require('git.features.pr_thread_status').toggle(snapshot.ctx, { thread }) end,
    navigate = M.navigate })
  local win = buf and vim.fn.bufwinid(buf)
  if win and win ~= -1 then api.nvim_set_current_win(win) end
end
function M.open()
  local plan = windows[api.nvim_get_current_win()]
  if not valid(plan) then vim.notify('No mapped PR comment here · gct lists all threads'); return end
  local row, records = vim.fn.line('.'), {}
  for _, record in ipairs(plan.ranges) do if record.first <= row and row <= record.last then records[#records + 1] = record end end
  if #records == 0 then vim.notify('No PR comment on this line · gct lists all threads'); return end
  local function select(record)
    if valid(plan) and api.nvim_get_current_win() == plan.win and api.nvim_win_get_cursor(plan.win)[1] == row then show(record, plan) end
  end
  if #records == 1 then select(records[1]) else
    vim.ui.select(records, { prompt = 'PR conversations', format_item = function(record)
      return ('#%d · %s'):format(record.snapshot.ctx.number, record.thread.comments[1].body:gsub('[\r\n]', ' '))
    end }, select)
  end
end
function M.navigate(direction, count)
  local state = active()
  if not state then return end
  local targets, win, row = {}, api.nvim_get_current_win(), vim.fn.line('.')
  for _, plan in pairs(state.plans) do
    if valid(plan) then for at in pairs(plan.rows) do targets[#targets + 1] = { win = plan.win, row = at } end end
  end
  table.sort(targets, function(a, b) return a.win == b.win and a.row < b.row or a.win < b.win end)
  if #targets == 0 then vim.notify('No mapped comments in this file · gct lists all threads'); return end
  local index = direction > 0 and #targets or 1
  if direction > 0 then
    for i, target in ipairs(targets) do if target.win > win or target.win == win and target.row > row then index = i - 1; break end end
  else
    for i = #targets, 1, -1 do
      local target = targets[i]
      if target.win < win or target.win == win and target.row < row then index = i + 1; break end
    end
  end
  local target = targets[((index - 1 + direction * (count or vim.v.count1)) % #targets) + 1]
  api.nvim_set_current_win(target.win); api.nvim_win_set_cursor(target.win, { target.row, 0 }); M.open()
end
function M.list()
  local state = active()
  if not state or state.loading then vim.notify(state and 'PR comments are loading' or 'No related PR comments available'); return end
  local records, source = {}, { buf = api.nvim_get_current_buf(), win = api.nvim_get_current_win() }
  for _, snapshot in ipairs(state.snapshots) do
    for _, thread in ipairs(snapshot.threads) do records[#records + 1] = { snapshot = snapshot, thread = thread } end
  end
  if #records == 0 then
    local errors = {}; for _, snapshot in ipairs(state.snapshots) do vim.list_extend(errors, snapshot.errors) end
    vim.notify(#errors > 0 and table.concat(errors, '\n') or 'No PR review threads', #errors > 0 and vim.log.levels.WARN or nil)
    return
  end
  vim.ui.select(records, { prompt = 'All related PR review threads (including outdated / file-level)', format_item = function(record)
    local thread, label = record.thread, 'list only'
    for _, plan in pairs(state.plans) do if valid(plan) then
      for _, at in ipairs(plan.ranges) do if at.thread == thread then label = 'L' .. at.last; break end end
    end end
    local comment = thread.comments[1]
    local body = (comment.body or ''):gsub('[\r\n]', ' ')
    if vim.fn.strdisplaywidth(body) > 80 then body = vim.fn.strcharpart(body, 0, 60) .. '…' end
    return ('#%d %s · %s · %s · @%s: %s'):format(record.snapshot.ctx.number, thread.path,
      require('git.features.pr_thread_status').label(thread), label, comment.user and comment.user.login or 'unknown', body)
  end }, function(record)
    if not record or states[state.view.tabpage] ~= state or not api.nvim_win_is_valid(source.win)
      or api.nvim_win_get_buf(source.win) ~= source.buf or api.nvim_get_current_win() ~= source.win then return end
    for _, plan in pairs(state.plans) do if valid(plan) then
      for _, at in ipairs(plan.ranges) do if at.thread == record.thread then
        api.nvim_set_current_win(plan.win); api.nvim_win_set_cursor(plan.win, { at.last, 0 }); show(at, plan); return
      end end
    end end
    show(record, source)
  end)
end
function M.setup(group)
  api.nvim_set_decoration_provider(ns, { on_win = function(_, win, buf)
    local plan = windows[win]
    return valid(plan) and plan.buf == buf or false
  end, on_line = function(_, win, buf, row)
    local plan = windows[win]
    if not valid(plan) or plan.buf ~= buf then return end
    local records = plan.rows[row + 1]
    if not records then return end
    local resolved = true; for _, record in ipairs(records) do if not record.thread.resolved then resolved = false end end
    api.nvim_buf_set_extmark(buf, ns, row, 0, { ephemeral = true,
      virt_text = { { ' 💬 ' .. #records, resolved and 'DiagnosticOk' or 'DiagnosticInfo' } },
      virt_text_pos = 'eol', priority = 210 })
  end })
  api.nvim_create_autocmd('User', { group = group, pattern = 'DiffviewRelatedPRsUpdated', callback = function(ev)
    if ev.data and ev.data.tabpage then M.refresh(ev.data.tabpage) end
  end })
  local function schedule(state)
    state = state or active()
    if not state then return end
    if state.projection_task then state.projection_task.cancel(); state.projection_task = nil end
    state.generation = (state.generation or 0) + 1
    clear_plans(state)
    state.pending = (state.pending or 0) + 1
    local pending = state.pending
    vim.defer_fn(function() if states[state.view.tabpage] == state and state.pending == pending then M.project(state) end end, 80)
  end
  api.nvim_create_autocmd('User', { group = group,
    pattern = { 'DiffviewDiffBufWinEnter', 'DiffviewSelectionChanged', 'DiffviewViewEnter' }, callback = function() schedule() end })
  api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, { group = group, callback = function(ev)
    for _, state in pairs(states) do
      for _, plan in pairs(state.plans) do if plan.buf == ev.buf then schedule(state); break end end
    end
  end })
  api.nvim_create_autocmd('BufWinEnter', { group = group, callback = function(ev)
    local state = active()
    if not state then return end
    for _, window in ipairs(state.view.cur_layout and state.view.cur_layout.windows or {}) do
      if window.file and window.file.bufnr == ev.buf and window.id == api.nvim_get_current_win() then schedule(); return end
    end
  end })
  api.nvim_create_autocmd('TabClosed', { group = group, callback = function()
    for tab in pairs(states) do if not api.nvim_tabpage_is_valid(tab) then stop(tab) end end
  end })
end
M._states, M._windows, M._valid, M._panes, M._namespace = states, windows, valid, panes, ns
return M
