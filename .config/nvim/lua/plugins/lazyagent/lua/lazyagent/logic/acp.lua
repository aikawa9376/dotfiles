local M = {}

local state = require("lazyagent.logic.state")

local ACP_BACKENDS = {
  tmux_acp = true,
  buffer_acp = true,
}

local function normalize_acp_config(value)
  if type(value) == "boolean" then
    return { enabled = value }
  end
  if type(value) == "table" then
    return value
  end
  return {}
end

local function normalize_permission_rules(value)
  if type(value) ~= "table" then
    return {}
  end

  local out = {}
  for _, rule in ipairs(value) do
    if type(rule) == "table" then
      out[#out + 1] = vim.deepcopy(rule)
    end
  end
  return out
end

local function merge_permission_rules(agent_rules, global_rules)
  local out = {}
  for _, rule in ipairs(normalize_permission_rules(agent_rules)) do
    out[#out + 1] = rule
  end
  for _, rule in ipairs(normalize_permission_rules(global_rules)) do
    out[#out + 1] = rule
  end
  return out
end

local function normalize_auto_switch_config(value)
  if type(value) == "boolean" then
    return {
      enabled = value,
      preserve_manual = true,
      mode_rules = {},
      model_rules = {},
    }
  end

  local cfg = type(value) == "table" and vim.deepcopy(value) or {}
  cfg.mode_rules = normalize_permission_rules(cfg.mode_rules)
  cfg.model_rules = normalize_permission_rules(cfg.model_rules)
  if cfg.preserve_manual == nil then
    cfg.preserve_manual = true
  end
  if cfg.enabled == nil then
    cfg.enabled = (#cfg.mode_rules > 0 or #cfg.model_rules > 0)
  end
  return cfg
end

local function merge_auto_switch_config(agent_cfg, global_cfg)
  local agent = normalize_auto_switch_config(agent_cfg)
  local global = normalize_auto_switch_config(global_cfg)
  local enabled
  if agent.enabled ~= nil then
    enabled = agent.enabled == true
  else
    enabled = global.enabled == true
  end

  local preserve_manual = agent.preserve_manual
  if preserve_manual == nil then
    preserve_manual = global.preserve_manual
  end
  if preserve_manual == nil then
    preserve_manual = true
  end

  return {
    enabled = enabled,
    preserve_manual = preserve_manual == true,
    mode_rules = merge_permission_rules(agent.mode_rules, global.mode_rules),
    model_rules = merge_permission_rules(agent.model_rules, global.model_rules),
  }
end

local function normalized_view_name(value)
  local view = value
  if type(view) ~= "string" or view == "" then
    view = "tmux"
  end
  view = view:lower()
  if view ~= "buffer" then
    view = "tmux"
  end
  return view
end

local function resolve_from_config(agent_cfg)
  local global_cfg = normalize_acp_config(state.opts and state.opts.acp)
  if global_cfg.enabled == nil and state.opts and state.opts.acp_mode ~= nil then
    global_cfg.enabled = state.opts.acp_mode
  end
  if global_cfg.auto_permission == nil and state.opts and state.opts.acp_auto_permission ~= nil then
    global_cfg.auto_permission = state.opts.acp_auto_permission
  end
  if global_cfg.default_mode == nil then
    global_cfg.default_mode = global_cfg.initial_mode
  end
  if global_cfg.initial_model == nil and state.opts and state.opts.acp_initial_model ~= nil then
    global_cfg.initial_model = state.opts.acp_initial_model
  end

  local agent_acp = normalize_acp_config(agent_cfg and agent_cfg.acp)
  if agent_acp.auto_permission == nil and agent_cfg and agent_cfg.acp_auto_permission ~= nil then
    agent_acp.auto_permission = agent_cfg.acp_auto_permission
  end
  if agent_acp.default_mode == nil then
    agent_acp.default_mode = agent_acp.initial_mode
  end
  if agent_acp.default_mode == nil and agent_cfg and agent_cfg.acp_default_mode ~= nil then
    agent_acp.default_mode = agent_cfg.acp_default_mode
  end
  if agent_acp.initial_model == nil and agent_cfg and agent_cfg.acp_initial_model ~= nil then
    agent_acp.initial_model = agent_cfg.acp_initial_model
  end

  local enabled
  if agent_acp.enabled ~= nil then
    enabled = agent_acp.enabled == true
  elseif global_cfg.enabled ~= nil then
    enabled = global_cfg.enabled == true
  else
    enabled = false
  end

  return {
    enabled = enabled,
    view = normalized_view_name(agent_acp.view or global_cfg.view),
    auto_permission = agent_acp.auto_permission or global_cfg.auto_permission,
    default_mode = agent_acp.default_mode or global_cfg.default_mode,
    initial_model = agent_acp.initial_model or global_cfg.initial_model,
    permission_rules = merge_permission_rules(
      agent_acp.permission_rules or (agent_cfg and agent_cfg.acp_permission_rules),
      global_cfg.permission_rules or (state.opts and state.opts.acp_permission_rules)
    ),
    auto_switch = merge_auto_switch_config(
      agent_acp.auto_switch or (agent_cfg and agent_cfg.acp_auto_switch),
      global_cfg.auto_switch or (state.opts and state.opts.acp_auto_switch)
    ),
  }
end

function M.is_acp_backend(backend_name)
  return ACP_BACKENDS[backend_name] == true
end

function M.resolve(agent_name, agent_cfg)
  local session = agent_name and state.sessions and state.sessions[agent_name] or nil
  if session and M.is_acp_backend(session.backend) then
    return {
      enabled = true,
      view = session.backend == "buffer_acp" and "buffer" or "tmux",
      auto_permission = session.auto_permission,
      default_mode = session.default_mode,
      initial_model = session.initial_model,
      permission_rules = vim.deepcopy(session.permission_rules or {}),
      auto_switch = vim.deepcopy(session.auto_switch or {}),
    }
  end

  return resolve_from_config(agent_cfg)
end

function M.resolve_config(agent_cfg)
  return resolve_from_config(agent_cfg)
end

function M.enabled(agent_name, agent_cfg)
  return M.resolve(agent_name, agent_cfg).enabled
end

function M.backend_name(agent_name, agent_cfg)
  local resolved = M.resolve(agent_name, agent_cfg)
  if not resolved.enabled then
    return nil
  end
  return resolved.view == "buffer" and "buffer_acp" or "tmux_acp"
end

return M
