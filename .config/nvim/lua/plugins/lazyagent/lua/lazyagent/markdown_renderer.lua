-- Keep renderer modules and their request/cache namespaces on the same backend.
local M = {}

local function available(name)
  if package.loaded[name] or package.loaded[name .. ".request.view"] then return true end
  local lazy = package.loaded["lazy.core.config"]
  local plugin = lazy and lazy.plugins and lazy.plugins[name .. ".nvim"]
  if plugin and plugin.dir and vim.fn.filereadable(plugin.dir .. "/lua/" .. name .. "/init.lua") == 1 then
    return true
  end
  return package.searchpath(name, package.path) ~= nil
    or #vim.api.nvim_get_runtime_file("lua/" .. name .. "/init.lua", false) > 0
end

function M.name()
  local selected = vim.g.markdown_renderer
  if (selected == "inkstone" or selected == "render-markdown") and available(selected) then return selected end
  for _, name in ipairs({ "inkstone", "render-markdown" }) do
    local renderer = package.loaded[name]
    if type(renderer) == "table" and renderer.initialized then return name end
  end
  for _, name in ipairs({ "inkstone", "render-markdown" }) do
    if available(name) then return name end
  end
  -- Existing callers use pcall for optional rendering when neither plugin is installed.
  return "render-markdown"
end

function M.require(suffix)
  return require(M.name() .. "." .. suffix)
end

function M.loaded(suffix)
  return package.loaded[M.name() .. "." .. suffix]
end

return M
