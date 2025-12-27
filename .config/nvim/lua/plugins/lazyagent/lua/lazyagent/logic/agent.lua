-- logic/agent.lua
-- This module handles agent resolution and management.
local M = {}

local state = require("lazyagent.logic.state")
local backend = require("lazyagent.logic.backend")
local completion_cache = {}

local function load_default_completions(agent_name)
  local key = agent_name and agent_name:lower() or ""
  if completion_cache[key] then return completion_cache[key] end
  if key == "" then return {} end

  local modnames = {
    "lazyagent.completion.agents." .. key,
    "lazyagent.completion." .. key,
  }

  for _, modname in ipairs(modnames) do
    local ok, mod = pcall(require, modname)
    if ok and type(mod) == "table" then
      completion_cache[key] = mod
      return mod
    end
  end

  completion_cache[key] = {}
  return completion_cache[key]
end

local function list_fd_paths()
  if vim.fn.executable("fd") ~= 1 then return {} end
  local cmd = { "fd", "--type", "f", "--type", "d", "--max-results", "120", "--strip-cwd-prefix", "." }
  local ok, out = pcall(vim.fn.systemlist, cmd)
  if not ok or not out then return {} end
  local items = {}
  for _, line in ipairs(out) do
    if line and line ~= "" then
      table.insert(items, { label = "@" .. line, desc = "Path" })
    end
  end
  return items
end

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

  -- Check for default agent
  for _, name in ipairs(available) do
    local cfg = state.opts.interactive_agents[name]
    if cfg and cfg.default then
      callback(name)
      return
    end
  end

  if #available == 0 then
    vim.notify("No available agents found. Please install agent CLI tools.", vim.log.levels.WARN)
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
  for k, cfg in pairs(state.opts.interactive_agents or {}) do
    if cfg.cmd and vim.fn.executable(cfg.cmd) == 1 then
      table.insert(available, k)
    end
  end
  table.sort(available)
  return available
end

local function normalize_completion_list(list)
  local out = {}
  if type(list) ~= "table" then return out end
  local seen = {}

  local function to_entry(v)
    if type(v) == "string" then
      return { label = v, desc = "" }
    end
    if type(v) == "table" then
      local label = v.label or v.text or v[1]
      local desc = v.desc or v.description or v[2] or ""
      if label and label ~= "" then
        return { label = label, desc = desc }
      end
    end
    return nil
  end

  for _, v in ipairs(list) do
    local entry = to_entry(v)
    if entry and entry.label and not seen[entry.label] then
      seen[entry.label] = true
      table.insert(out, entry)
    end
  end
  return out
end

function M.get_scratch_completions(agent_name)
  if not agent_name or agent_name == "" then
    -- Fallback to default agent if configured.
    local available = M.available_agents()
    if #available > 0 then agent_name = available[1] end
  end

  local cfg = M.get_interactive_agent(agent_name)
  local provider = cfg and cfg.scratch_completions
  local defaults = load_default_completions(agent_name)
  local provided = {}
  if provider then
    local ok, val = pcall(function()
      if type(provider) == "function" then
        return provider(cfg)
      end
        return provider
      end)
    if ok and type(val) == "table" then
      provided = val
    end
  end

  local res = vim.tbl_deep_extend("force", {}, defaults or {}, provided or {})
  res.slash = normalize_completion_list(res.slash or {})
  -- Replace @ completions with fd-based file/dir list (common across agents).
  local fd_paths = list_fd_paths()
  if fd_paths and #fd_paths > 0 then
    res.at = fd_paths
  else
    res.at = {}
  end
  return res
end

return M
