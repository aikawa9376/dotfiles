-- logic/agent.lua
-- This module handles agent resolution and management.
local M = {}

local state = require("lazyagent.logic.state")
local acp_logic = require("lazyagent.logic.acp")
local acp_local_commands = require("lazyagent.acp.local_commands")
local path_completions = require("lazyagent.logic.path_completions")
local completion_cache = {}
local is_list = vim.islist or vim.tbl_islist

local function join_cmd_parts(cmd)
  if not cmd then return nil end
  if type(cmd) == "table" then
    local quoted = {}
    for _, part in ipairs(cmd) do
      table.insert(quoted, vim.fn.shellescape(tostring(part)))
    end
    return table.concat(quoted, " ")
  end
  return tostring(cmd)
end

local function first_executable(cmd)
  if type(cmd) == "table" then
    return cmd[1] and tostring(cmd[1]) or nil
  end
  if type(cmd) == "string" then
    return cmd:match("^%s*([^%s]+)")
  end
  return nil
end

local function add_command_candidates(out, spec)
  if not spec then return end
  if type(spec) == "table" and is_list(spec) and type(spec[1]) == "table" then
    for _, nested in ipairs(spec) do
      add_command_candidates(out, nested)
    end
    return
  end
  table.insert(out, spec)
end

local function command_is_available(spec)
  local exe = first_executable(spec)
  return exe ~= nil and exe ~= "" and vim.fn.executable(exe) == 1
end

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

--- Gets the configuration for a specific interactive agent.
-- @param agent (string) The name of the agent.
-- @return (table|nil) The agent's configuration table, or nil if not found.
function M.get_interactive_agent(agent)
  return state.opts.interactive_agents and state.opts.interactive_agents[agent] or nil
end

function M.use_acp(agent_name, agent_cfg)
  return acp_logic.enabled(agent_name, agent_cfg)
end

function M.resolve_acp_command(agent_name, agent_cfg)
  local cfg = agent_cfg or M.get_interactive_agent(agent_name) or {}
  local candidates = {}
  add_command_candidates(candidates, cfg.acp_cmd)
  add_command_candidates(candidates, cfg.acp_cmd_fallbacks)

  for _, candidate in ipairs(candidates) do
    if command_is_available(candidate) then
      return vim.deepcopy(candidate)
    end
  end

  local primary = candidates[1]
  if primary then
    return nil, "ACP command not found: " .. tostring(first_executable(primary) or primary)
  end

  return nil, "ACP command is not configured"
end

function M.compute_cli_launch_cmd(agent_cfg)
  local base_cmd = agent_cfg and agent_cfg.cmd or nil
  local agent_yolo_flag = (agent_cfg and agent_cfg.yolo_flag) or (state.opts and state.opts.yolo_flag)
  local use_yolo = agent_cfg and agent_cfg.yolo or false

  local cmd_str
  if use_yolo and agent_yolo_flag and base_cmd then
    local joined = join_cmd_parts(base_cmd)
    if joined and joined ~= "" then
      cmd_str = joined .. " " .. tostring(agent_yolo_flag)
    end
  end

  return cmd_str or join_cmd_parts(base_cmd)
end

function M.resolve_launch_spec(agent_name, agent_cfg)
  if M.use_acp(agent_name, agent_cfg) then
    local acp_cmd, err = M.resolve_acp_command(agent_name, agent_cfg)
    if not acp_cmd then
      return nil, err
    end
    local backend_name = acp_logic.backend_name(agent_name, agent_cfg) or "tmux_acp"
    return {
      backend = backend_name,
      mode = "acp",
      command = acp_cmd,
    }
  end

  local cmd = M.compute_cli_launch_cmd(agent_cfg)
  if not cmd or cmd == "" then
    return nil, "Launch command is not configured"
  end

  return {
    backend = (agent_cfg and agent_cfg.backend) or nil,
    mode = "cli",
    command = cmd,
  }
end

function M.is_agent_available(agent_name, agent_cfg)
  local cfg = agent_cfg or M.get_interactive_agent(agent_name)
  if not cfg then return false end

  if M.use_acp(agent_name, cfg) then
    local acp_cmd = M.resolve_acp_command(agent_name, cfg)
    return acp_cmd ~= nil
  end

  return cfg.cmd and command_is_available(cfg.cmd) or false
end

--- Gets a list of agents with active sessions (e.g., running tmux panes).
-- @return (table) A list of active agent names.
function M.get_active_agents()
  local active = {}
  for name, s in pairs(state.sessions or {}) do
    if s and s.pane_id and s.pane_id ~= "" then
        -- Optimization: Do not check backend.pane_exists(s.pane_id) synchronously here.
        -- It causes lualine to lag/blink because it runs `tmux list-panes` on every redraw.
        -- We assume state.sessions is accurate enough for status line display.
        table.insert(active, name)
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
    if M.is_agent_available(k, cfg) then
      table.insert(available, k)
    end
  end
  table.sort(available)
  return available
end

function M.available_acp_agents()
  local available = {}
  for _, name in ipairs(M.available_agents()) do
    local cfg = M.get_interactive_agent(name)
    if M.use_acp(name, cfg) then
      table.insert(available, name)
    end
  end
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
      local doc = v.doc or v.documentation or v[3]
      if label and label ~= "" then
        return { label = label, desc = desc, doc = doc }
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
  local use_acp = M.use_acp(agent_name, cfg)
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
  local running = agent_name and state.sessions and state.sessions[agent_name] or nil
  if use_acp then
    local local_slash = normalize_completion_list(acp_local_commands.entries())
    local explicit_slash = normalize_completion_list((provided and provided.slash) or {})
    local dynamic_slash = {}
    if running and type(running.acp_available_commands) == "table" then
      dynamic_slash = vim.deepcopy(running.acp_available_commands)
    end
    res.slash = normalize_completion_list(vim.list_extend(vim.list_extend(local_slash, dynamic_slash), explicit_slash))
  else
    local dynamic_slash = {}
    if running and type(running.acp_available_commands) == "table" then
      dynamic_slash = vim.deepcopy(running.acp_available_commands)
    end
    res.slash = normalize_completion_list(vim.list_extend(dynamic_slash, res.slash or {}))
  end
  -- Replace @ completions with fd-based file/dir list (common across agents).
  local fd_paths = path_completions.list_fd_paths()
  if fd_paths and #fd_paths > 0 then
    res.at = fd_paths
  else
    res.at = {}
  end
  return res
end

return M
