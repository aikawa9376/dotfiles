local M = {}
local agent_logic = require("lazyagent.logic.agent")

local icons = {
  Claude = "󰛨", -- 󰛨 (lightbulb/spark) or similar
  Codex = "", --  (chip)
  Gemini = "󰠠", -- 󰠠 (star/sparkle)
  Copilot = "", --  (github copilot icon usually)
  Cursor = "", --  (edit/cursor)
  -- Fallback
  Default = "",
}

function M.get_status()
  local active = agent_logic.get_active_agents()
  if #active == 0 then return nil end

  local status_parts = {}
  for _, name in ipairs(active) do
    local icon = icons[name] or icons.Default
    table.insert(status_parts, icon)
  end

  return table.concat(status_parts, " ")
end

return M
