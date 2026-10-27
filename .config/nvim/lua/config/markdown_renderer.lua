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

return M
