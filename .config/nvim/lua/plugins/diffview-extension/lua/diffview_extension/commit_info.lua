-- Asynchronous, tab/view-owned comparison cache. Statusline rendering reads it.
local M = {}
local comparison = require('diffview_extension.comparison')
local states = {}
local function publish(tab)
  vim.api.nvim_exec_autocmds('User', { pattern = 'DiffviewContextUpdated', modeline = false, data = { tabpage = tab } })
  vim.cmd('redrawstatus')
  local lualine = package.loaded.lualine
  if lualine then lualine.refresh({ place = { 'statusline' } }) end
end
local function clear(tab)
  local state = states[tab]
  if not state then return end
  states[tab] = nil
  if state.job then state.job:kill(15) end
  publish(tab)
end
local function prune()
  for tab in pairs(states) do if not vim.api.nvim_tabpage_is_valid(tab) then clear(tab) end end
end
local function refresh(view)
  local context = comparison.describe(view)
  local tab = view and view.tabpage
  if not context or not tab or not vim.api.nvim_tabpage_is_valid(tab) then clear(tab); return end
  local old = states[tab]
  if old and old.view == view and old.context.key == context.key then return old end
  clear(tab)
  local state = { view = view, context = context, metadata = {}, request = true }
  states[tab] = state
  local function current() return states[tab] == state and vim.api.nvim_tabpage_is_valid(tab) end
  local function done()
    if not current() then return end
    state.request, state.job = nil, nil
    state.text = comparison.format(context, state.metadata, state.counts)
    publish(tab)
  end
  local function run(args, callback)
    local argv = { 'git', '-C', context.root }; vim.list_extend(argv, args)
    state.job = vim.system(argv, { text = true, timeout = 10000 }, function(result)
      vim.schedule(function() if current() then state.job = nil; callback(result) end end)
    end)
  end
  local function count()
    if context.left.commit and context.right.commit then
      local empty = context.left.commit == comparison.empty_tree
      run(empty and { 'rev-list', '--count', context.right.commit }
        or { 'rev-list', '--left-right', '--count', context.left.commit .. '...' .. context.right.commit }, function(result)
        if result.code == 0 then
          local left, right = (result.stdout or ''):match('(%d+)%s+(%d+)')
          if empty then left, right = '0', (result.stdout or ''):match('%d+') end
          if left and right then state.counts = { left = tonumber(left), right = tonumber(right) } end
        end
        local tip = state.metadata[context.right.commit]
        local commit_range = context.raw:match('^%x+%.%.%x+$') or context.raw:match('%^%.%.')
        local single = tip and (tip.parent == context.left.commit
          or context.left.commit == comparison.empty_tree and not tip.parent)
        if context.mode == 'range' and commit_range and single and state.counts
          and state.counts.left == 0 and state.counts.right == 1 then context.mode = 'commit' end
        done()
      end)
    else done() end
  end
  local args, seen = { 'show', '-s', '--no-show-signature', '--format=%H%x00%h%x00%s%x00%P' }, {}
  for _, side in ipairs({ context.right, context.left }) do
    if side.commit and side.commit ~= comparison.empty_tree and not seen[side.commit] then
      seen[side.commit] = true; args[#args + 1] = side.commit
    end
  end
  if #args == 4 then done()
  else
    run(args, function(result)
      if result.code == 0 then
        for line in (result.stdout or ''):gmatch('[^\n]+') do
          local hash, short, subject, parents = line:match('([^%z]+)%z([^%z]+)%z([^%z]*)%z(.*)')
          if hash then state.metadata[hash] = { short = short, subject = subject, parent = parents:match('^%x+') } end
        end
      end
      count()
    end)
  end
  state.text = comparison.format(context, state.metadata)
  publish(tab)
  return state
end
local function refresh_current()
  local lib = package.loaded['diffview.lib']
  local view = lib and lib.get_current_view()
  if view then
    if not view._comparison_context_hooked and view.emitter then
      view._comparison_context_hooked = true
      view.emitter:on('files_updated', function() vim.schedule(function() if vim.api.nvim_tabpage_is_valid(view.tabpage) then refresh(view) end end) end)
      view.emitter:on('view_closed', function() clear(view.tabpage) end)
    end
    return refresh(view)
  end
end
function M.setup(group)
  vim.api.nvim_create_autocmd('User', { group = group,
    pattern = { 'DiffviewViewOpened', 'DiffviewViewEnter', 'DiffviewDiffBufWinEnter', 'DiffviewSelectionChanged', 'DiffviewFilesStaged' },
    callback = function() vim.schedule(refresh_current) end })
  vim.api.nvim_create_autocmd('TabClosed', { group = group, callback = prune })
end
function M.statusline(width)
  local state = states[vim.api.nvim_get_current_tabpage()]
  return state and comparison.format(state.context, state.metadata, state.counts, width) or ''
end
function M.state(tab) return states[tab or vim.api.nvim_get_current_tabpage()] end
M._states, M._refresh, M._prune = states, refresh, prune
M._target_commit = function(view) return view and view.right and view.right.commit end
return M
