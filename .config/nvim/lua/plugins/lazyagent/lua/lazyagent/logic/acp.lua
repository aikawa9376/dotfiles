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
