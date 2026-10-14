-- GitHub relationships belong to the captured comparison, never the global cwd.
local M = { commit_limit = 20 }
local api = vim.api
local info = require('diffview_extension.commit_info')
local comparison = require('diffview_extension.comparison')
local states = {}
local function clean(text) return tostring(text or ''):gsub('[\r\n\t]', ' ') end
local function current_view()
  local lib = package.loaded['diffview.lib']
  return lib and lib.get_current_view()
end
local function stop(tab)
  local state = states[tab]
  states[tab] = nil
  if state and state.task then state.task.cancel() end
end
local function item(pr, ctx)
  local github = require('git.features.github')
  local target = github.url_context(github.scalar(pr.html_url) or pr.url)
  if not target or not tonumber(pr.number) or target.number ~= tonumber(pr.number) or target.host ~= ctx.host then return end
  target.root = ctx.root
  local status
  if github.scalar(pr.merged_at) or pr.state == 'MERGED' then status = 'merged'
  elseif pr.state == 'closed' or pr.state == 'CLOSED' then status = 'closed'
  elseif pr.draft or pr.isDraft then status = 'draft' else status = 'open' end
  return { number = target.number, title = clean(pr.title), url = target.url, ctx = target, status = status }
end
local function fetch(context, explicit)
  local github, async = require('git.features.github'), require('git.features.async')
  local ctx = github.resolve(explicit and vim.tbl_extend('force', explicit.ctx, { root = context.root })
    or { root = context.root, repository_only = true })
  local result, indexed = { items = {}, errors = {}, scanned = 0 }, {}
  local mutable = context.left.kind == 'worktree' or context.right.kind == 'worktree'
    or context.left.kind == 'index' or context.right.kind == 'index'
  local function add(pr)
    local entry = item(pr, ctx)
    if entry and not indexed[entry.url] then indexed[entry.url] = true; result.items[#result.items + 1] = entry end
  end
  if explicit then add(github.pr(ctx)); result.explicit = true; return result end
  local targets, seen = {}, {}
  local function target(hash)
    if hash and hash:match('^%x+$') and hash ~= comparison.empty_tree and not seen[hash] then
      targets[#targets + 1], seen[hash] = hash, true
    end
  end
  if context.mode == 'range' or context.mode == 'snapshot' and context.right.commit then
    local range = context.right.commit
    if context.left.commit and context.left.commit ~= comparison.empty_tree then range = context.left.commit .. '...' .. context.right.commit end
    local args = { 'rev-list', '--topo-order', '--max-count=' .. (M.commit_limit + 1), range }
    local output, err = async.git(context.root, args)
    if not output then error(err, 0) end
    for hash in output:gmatch('%x+') do target(hash) end
    result.limited = #targets > M.commit_limit
    while #targets > M.commit_limit do table.remove(targets) end
  else target(context.right.commit) end
  if #targets == 0 then
    if mutable then
      local head = async.git(context.root, { 'rev-parse', '--verify', 'HEAD' })
      target(head and vim.trim(head))
    else target(context.left.commit) end
  end
  -- For mutable views, also include an open PR for the captured branch. This
  -- still works when local commits have not been pushed or a fork is tracked.
  if mutable then
    local branch = async.git(context.root, { 'branch', '--show-current' })
    branch = branch and vim.trim(branch)
    if branch and branch ~= '' then
      local ok, pr = pcall(github.pr, vim.deepcopy(ctx))
      if ok and pr.state == 'OPEN' and pr.headRefName == branch then add(pr) end
    end
  end
  for first = 1, #targets, 4 do
    local reads = {}
    for index = first, math.min(first + 3, #targets) do
      local hash = targets[index]
      reads[#reads + 1] = function()
        local pages = github.json(ctx, { 'api', '--hostname', ctx.host, '--paginate', '--slurp',
          ('repos/%s/commits/%s/pulls?per_page=100'):format(ctx.repo, hash) })
        local prs = {}; for _, page in ipairs(pages) do vim.list_extend(prs, page) end
        return prs
      end
    end
    for _, read in ipairs(async.gather(reads)) do
      result.scanned = result.scanned + 1
      if read.ok then for _, pr in ipairs(read.value) do add(pr) end
      else result.errors[#result.errors + 1] = clean(read.value) end
    end
  end
  local rank = { open = 1, draft = 2, merged = 3, closed = 4 }
  table.sort(result.items, function(a, b)
    if a.status ~= b.status then return rank[a.status] < rank[b.status] end
    return a.number > b.number
  end)
  return result
end
local function render(view)
  local panel, state, cached = view.panel, states[view.tabpage], info.state(view.tabpage)
  if not panel or not panel.render_data or not cached or cached.view ~= view then return end
  local component = view._github_component
  local found = false
  for _, existing in ipairs(panel.render_data.components) do if component and existing == component.comp then found = true end end
  if not found then
    component = panel.render_data:create_component({ name = 'github_context',
      { name = 'comparison' }, { name = 'title' }, { name = 'prs' }, { name = 'hint' } })
    view._github_component = component
  end
  component.comp:clear()
  local context, description = cached.context, component.comparison.comp
  description:add_line()
  description:add_line('Comparison', 'DiffviewFilePanelTitle')
  description:add_line(comparison.prefix(context, cached.metadata, cached.counts), 'DiffviewFilePanelPath')
  for _, side in ipairs({ { 'Left', context.left }, { 'Right', context.right } }) do
    local rev, meta = side[2], cached.metadata[side[2].commit]
    description:add_line(side[1] .. ': ' .. rev.label .. (meta and (' · ' .. meta.short .. ' ' .. clean(meta.subject)) or ''), 'DiffviewDim1')
  end
  local prs = component.prs.comp
  component.title.comp:add_line('Related PRs', 'DiffviewFilePanelTitle')
  if not state or state.loading then prs:add_line('  Loading…', 'DiffviewDim1')
  elseif state.error then prs:add_line('  Unavailable · gR to retry', 'DiagnosticWarn')
  else
    local result = state.result
    if #result.items == 0 then prs:add_line(#result.errors > 0 and '  Lookup incomplete · gR to retry' or '  None found', 'DiffviewDim1') end
    for _, pr in ipairs(result.items) do
      local icon = ({ open = '●', draft = '◷', closed = '✗', merged = '✓' })[pr.status]
      prs:add_text('  ' .. icon .. ' #' .. pr.number, pr.status == 'merged' and 'DiagnosticOk' or pr.status == 'closed' and 'DiagnosticError' or 'DiagnosticInfo')
      prs:add_line(' ' .. pr.title, 'DiffviewFilePanelPath')
    end
    local scope = result.explicit and 'PR comparison' or ('%d commit(s) checked'):format(result.scanned)
    if context.custom then scope = 'Snapshot provenance · ' .. scope end
    if result.limited then scope = scope .. ' · latest ' .. M.commit_limit .. ' only' end
    component.hint.comp:add_line(scope, result.limited and 'DiagnosticWarn' or 'DiffviewDim1')
    if #result.errors > 0 then component.hint.comp:add_line('Lookup incomplete · gR to retry', 'DiagnosticWarn') end
  end
  component.hint.comp:add_line('gp PR · gA actions · gR refresh', 'DiffviewDim1')
  -- Extend native j/k constraints while keeping file components and identities.
  local native = panel.components
  local constraints = {}
  if native and native.working then
    for _, name in ipairs({ 'conflicting', 'working', 'staged' }) do constraints[#constraints + 1] = native[name].files.comp end
  elseif native and native.log then constraints[#constraints + 1] = native.log.entries.comp end
  if #constraints > 0 then
    constraints[#constraints + 1] = prs
    panel.constrain_cursor = function(...)
      return require('diffview.renderer').create_cursor_constraint(constraints)(...)
    end
  end
end
local function redraw(view)
  if view.panel and view.panel.bufid and api.nvim_buf_is_valid(view.panel.bufid) then view.panel:render(); view.panel:redraw() end
end
local function hook(view)
  if not view.panel or view._github_panel_hooked then return end
  view._github_panel_hooked = true
  local original = view.panel.render
  view.panel.render = function(panel, ...)
    local result = original(panel, ...)
    render(view)
    return result
  end
end
function M.refresh(view, force)
  view = view or current_view()
  local cached = view and info.state(view.tabpage)
  if not cached or cached.view ~= view then return end
  hook(view)
  local context, state = cached.context, states[view.tabpage]
  if not force and state and state.view == view and state.key == context.key
    and (state.loading or (vim.uv.hrtime() - state.loaded_at < 120e9)) then redraw(view); return end
  stop(view.tabpage)
  state = { view = view, key = context.key, loading = true }
  states[view.tabpage] = state
  local explicit = view._github_association
  if explicit and explicit.key ~= context.key then explicit = nil; view._github_association = nil end
  local function begin()
    if states[view.tabpage] ~= state or not api.nvim_tabpage_is_valid(view.tabpage) then return end
    local async = require('git.features.async')
    local task, err = async.run(context.root, function() return fetch(context, explicit) end, function(ok, result)
      if states[view.tabpage] ~= state or not api.nvim_tabpage_is_valid(view.tabpage) then return end
      state.task, state.loading, state.loaded_at = nil, false, vim.uv.hrtime()
      if ok then state.result = result else state.error = clean(result) end
      redraw(view)
    end)
    if not task then state.loading, state.error, state.loaded_at = false, clean(err), vim.uv.hrtime() end
    if task and not task.completed then state.task = task end
  end
  -- Rapid FileHistory navigation and initial revision setup should settle
  -- before launching remote reads. Explicit refresh/association runs at once.
  if force then begin() else vim.defer_fn(begin, 150) end
  redraw(view)
end
function M.associate(view, ctx)
  local cached = info._refresh(view)
  if not cached then return end
  view._github_association = { key = cached.context.key, ctx = vim.deepcopy(ctx) }
  M.refresh(view, true)
end
function M.at(view, row)
  local state, component = view and states[view.tabpage], view and view._github_component
  if not state or state.loading or not state.result or not component then return end
  if state.view ~= view or state.key ~= info.state(view.tabpage).context.key then return end
  return state.result.items[row - component.prs.comp.lstart]
end
local function choose(action)
  local view = current_view()
  local state = view and states[view.tabpage]
  if not state or state.loading then vim.notify('Related PRs are loading'); return end
  if state.error then vim.notify(state.error, vim.log.levels.WARN); return end
  local entries = state.result.items
  if #entries == 0 then vim.notify('No related PR found'); return end
  local selected = view.panel.bufid == api.nvim_get_current_buf() and M.at(view, vim.fn.line('.'))
  local tab, win, buf = view.tabpage, api.nvim_get_current_win(), api.nvim_get_current_buf()
  local function perform(pr)
    if not pr or states[tab] ~= state or api.nvim_get_current_win() ~= win or api.nvim_get_current_buf() ~= buf then return end
    if action == 'actions' then require('git.features.github_actions').open(vim.tbl_extend('force', pr.ctx, { bufnr = buf }))
    elseif action == 'browser' then vim.ui.open(pr.url)
    else require('git.features.pr').open(pr.ctx) end
  end
  if selected or #entries == 1 then perform(selected or entries[1])
  else vim.ui.select(entries, { prompt = 'Related PRs', format_item = function(pr) return ('#%d %s · %s'):format(pr.number, pr.title, pr.status) end }, perform) end
end
function M.open() choose('open') end
function M.actions() choose('actions') end
function M.browser() choose('browser') end
function M.select_entry()
  local view = current_view()
  if view and view.panel.bufid == api.nvim_get_current_buf() and M.at(view, vim.fn.line('.')) then M.open()
  else require('diffview.actions').select_entry() end
end
function M.setup(group)
  api.nvim_create_autocmd('User', { group = group, pattern = 'DiffviewContextUpdated', callback = function(ev)
    local tab = ev.data and ev.data.tabpage
    local cached = tab and info.state(tab)
    if cached then M.refresh(cached.view) elseif tab then stop(tab) end
  end })
  api.nvim_create_autocmd('User', { group = group, pattern = 'GitHubChanged', callback = function(ev)
    for _, state in pairs(states) do
      local cached = info.state(state.view.tabpage)
      if cached and (not ev.data or not ev.data.root or cached.context.root == ev.data.root) then M.refresh(state.view, true) end
    end
  end })
  api.nvim_create_autocmd('TabClosed', { group = group, callback = function()
    for tab in pairs(states) do if not api.nvim_tabpage_is_valid(tab) then stop(tab) end end
  end })
end
M._states, M._fetch, M._item = states, fetch, item
return M
