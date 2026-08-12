local M = {}

local function parse_line(line)
  local display_key, label = line:match('^%s*(.-)%s%s+(.+)$')
  if not display_key then display_key, label = line:match('^%s*(%S+)%s+(.+)$') end
  if not display_key then return nil end

  local key = display_key:match('^([^%s/]+)')
  if not key then return nil end
  return { key = key, display_key = display_key, label = label }
end

---Show help using the shared Fugitive action menu.
---@param title string
---@param lines string[]
function M.show(title, lines)
  local actions = {}
  for _, line in ipairs(lines or {}) do
    local action = parse_line(line)
    if action then table.insert(actions, action) end
  end
  require('features.action_menu').show(title, {
    { title = 'Actions', actions = actions },
  })
end

return M
