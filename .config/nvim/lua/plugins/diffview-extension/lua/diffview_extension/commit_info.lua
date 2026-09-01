local M = {}

local states = {}

local function refresh_lualine()
  vim.schedule(function()
    local ok, lualine = pcall(require, "lualine")
    if ok then
      lualine.refresh({ place = { "statusline" } })
    end
  end)
end

local function target_commit(view)
  local right = view and view.right
  return right and type(right.commit) == "string" and right.commit ~= "" and right.commit or nil
end

local function repository_root(view)
  local context = view and view.adapter and view.adapter.ctx
  return context and (context.toplevel or context.root) or nil
end

local function clear(tabpage)
  if tabpage and states[tabpage] then
    states[tabpage] = nil
    refresh_lualine()
  end
end

local function prune()
  for tabpage in pairs(states) do
    if not vim.api.nvim_tabpage_is_valid(tabpage) then
      states[tabpage] = nil
    end
  end
  refresh_lualine()
end

local function refresh(view)
  local tabpage = view and view.tabpage
  local commit = target_commit(view)
  local root = repository_root(view)
  if not tabpage or not vim.api.nvim_tabpage_is_valid(tabpage) or not commit or not root then
    clear(tabpage)
    return
  end

  local current = states[tabpage]
  if current and current.commit == commit and (current.text or current.request) then
    return
  end

  local request = {}
  states[tabpage] = { commit = commit, request = request }
  vim.system({ "git", "-C", root, "show", "-s", "--no-show-signature", "--format=%h %s", commit }, {
    text = true,
  }, function(result)
    vim.schedule(function()
      local state = states[tabpage]
      if
        not state
        or state.request ~= request
        or state.commit ~= commit
        or not vim.api.nvim_tabpage_is_valid(tabpage)
      then
        return
      end

      local text = result.code == 0 and vim.trim(result.stdout or "") or ""
      state.request = nil
      state.text = text ~= "" and text or nil
      refresh_lualine()
    end)
  end)
end

local function refresh_current()
  local ok, lib = pcall(require, "diffview.lib")
  local view = ok and lib.get_current_view() or nil
  if view then
    refresh(view)
  end
end

function M.setup(group)
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "DiffviewViewOpened", "DiffviewViewEnter" },
    callback = refresh_current,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "DiffviewViewClosed",
    callback = function()
      clear(vim.api.nvim_get_current_tabpage())
    end,
  })
  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = prune,
  })
end

function M.statusline()
  local state = states[vim.api.nvim_get_current_tabpage()]
  return state and state.text or ""
end

M._states = states
M._target_commit = target_commit
M._refresh = refresh
M._prune = prune

return M
