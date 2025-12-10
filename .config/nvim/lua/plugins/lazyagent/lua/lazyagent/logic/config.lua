-- logic/config.lua
-- Helpers for resolving configuration values with agent override precedence.
local M = {}

local state = require("lazyagent.logic.state")

--- Resolve a config key, preferring agent-specific value, then global opts, then default.
---@param agent_cfg table|nil
---@param key string
---@param default any
---@return any
function M.pref(agent_cfg, key, default)
  if agent_cfg and agent_cfg[key] ~= nil then return agent_cfg[key] end
  if state.opts and state.opts[key] ~= nil then return state.opts[key] end
  return default
end

return M
