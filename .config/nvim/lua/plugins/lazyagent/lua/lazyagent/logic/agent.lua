-- logic/agent.lua
-- This module handles agent resolution and management.
local M = {}

local state = require("lazyagent.logic.state")
local backend = require("lazyagent.logic.backend")

--- Gets the configuration for a specific interactive agent.
-- @param agent (string) The name of the agent.
-- @return (table|nil) The agent's configuration table, or nil if not found.
function M.get_interactive_agent(agent)
  return state.opts.interactive_agents and state.opts.interactive_agents[agent] or nil
end

--- Gets a list of agents with active sessions (e.g., running tmux panes).
-- @return (table) A list of active agent names.
function M.get_active_agents()
  local active = {}
  for name, s in pairs(state.sessions or {}) do
    if s and s.pane_id and s.pane_id ~= "" then
        local _, backend_mod = backend.resolve_backend_for_agent(name, nil)
        if backend_mod and type(backend_mod.pane_exists) == "function" then
          if backend_mod.pane_exists(s.pane_id) then table.insert(active, name) end
        else
          -- If pane_exists isn't available on this backend, consider the session table as truth.
          table.insert(active, name)
        end
      end
    end
    table.sort(active)
  return active
end

--- Resolves the target agent to use based on context.
-- 1) If 'explicit' is provided, use it.
-- 2) If exactly one active agent is present, use it.
-- 3) If multiple active agents are present, present a ui.select of the active agents.
-- 4) If no active agents exist: if 'hint' is provided and valid, use it; otherwise, present ui.select of configured agents.
-- @param explicit (string|nil) An explicitly provided agent name.
-- @param hint (string|nil) A hint for the agent name (e.g., from a command).
-- @param callback (function) A function to call with the chosen agent name.
function M.resolve_target_agent(explicit, hint, callback)
  callback = callback or function() end

  if explicit and explicit ~= "" then
    callback(explicit)
    return
  end

  local active = M.get_active_agents()
  if #active == 1 then
    callback(active[1])
    return
  end

  if #active > 1 then
    vim.ui.select(active, { prompt = "Choose running agent:" }, function(choice)
      if choice and choice ~= "" then callback(choice) end
    end)
    return
  end

  -- No active agents
  local available = M.available_agents()

  -- If a hint (e.g. command name) is provided and valid, use it directly.
  if hint and hint ~= "" and state.opts.interactive_agents and state.opts.interactive_agents[hint] then
    callback(hint)
    return
  end

  if #available == 0 then
    callback(nil)
    return
  end

  if #available == 1 then
    callback(available[1])
    return
  end

  vim.ui.select(available, { prompt = "Choose agent to start:" }, function(choice)
    if choice and choice ~= "" then callback(choice) end
  end)
end

--- Returns an alphabetically sorted list of configured interactive agent names.
-- Using a stable, sorted list ensures UI/select and keymap registration order is deterministic.
function M.available_agents()
  local available = {}
  for k, _ in pairs(state.opts.interactive_agents or {}) do table.insert(available, k) end
  table.sort(available)
  return available
end

return M
