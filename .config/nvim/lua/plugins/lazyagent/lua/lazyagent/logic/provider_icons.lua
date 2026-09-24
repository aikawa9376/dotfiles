local M = {}

M.Codex = ""
M.Claude = ""
M.Copilot = ""
M.Bubble = "󰭹"

local icons = {
  codex = M.Codex,
  claude = M.Claude,
  copilot = M.Copilot,
}
local icon_set = {
  [M.Bubble] = true,
  [M.Codex] = true,
  [M.Claude] = true,
  [M.Copilot] = true,
}

function M.get(provider)
  if type(provider) ~= "string" then return nil end
  local name = provider:lower()
  name = name:match("^([^:]+)::") or name
  return icons[name]
end

function M.is_icon(icon)
  return icon_set[icon] == true
end

return M
