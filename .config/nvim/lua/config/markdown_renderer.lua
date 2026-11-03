-- Optional renderer for UI integrations such as Blink's documentation window.
local M = {}

function M.get()
  local names = { 'inkstone', 'render-markdown' }
  local preferred = vim.g.markdown_renderer
  if preferred == 'inkstone' or preferred == 'render-markdown' then
    local ok, renderer = pcall(require, preferred)
    if ok and renderer.initialized then return renderer end
  end
  for _, name in ipairs(names) do
    local renderer = package.loaded[name]
    if type(renderer) == 'table' and renderer.initialized then return renderer end
  end
  for _, name in ipairs(names) do
    local ok, renderer = pcall(require, name)
    if ok and renderer.initialized then return renderer end
  end
end

-- Inspect only loaded state: focus events must not load a Markdown renderer.
function M.typography_active()
  local typography = package.loaded['inkstone.core.typography']
  if type(typography) ~= 'table' then return false end
  if type(typography.visible) == 'function' then return typography.visible() end
  -- Compatibility with the text backend before the shared visibility query.
  local tab = vim.api.nvim_get_current_tabpage()
  for buf, state in pairs(typography.active or {}) do
    local win = state.win
    if #state.entries > 0 and vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_win_get_tabpage(win) == tab and vim.api.nvim_win_get_buf(win) == buf then
      return true
    end
  end
  return false
end

return M
