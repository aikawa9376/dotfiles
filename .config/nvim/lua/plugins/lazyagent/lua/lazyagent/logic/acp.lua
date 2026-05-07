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

local function normalize_color(value)
  if value == nil then
    return nil
  end
  local text = tostring(value)
  if text == "" then
    return nil
  end
  if text:lower() == "none" then
    return "NONE"
  end
  return text
end

local function normalize_positive_integer(value)
  local number = tonumber(value)
  if not number or number <= 0 then
    return nil
  end
  return math.floor(number)
end

local function normalize_table_layout(value)
  local layout = tostring(value or ""):lower()
  if layout == "card" or layout == "cards" or layout == "vertical" then
    return "card"
  end
  return "table"
end

local function normalize_transcript_compaction_config(value)
  if type(value) == "boolean" then
    return { enabled = value }
  end

  local cfg = type(value) == "table" and vim.deepcopy(value) or {}
  return {
    enabled = cfg.enabled,
    min_sections = normalize_positive_integer(cfg.min_sections or cfg.section_threshold),
    keep_recent_sections = normalize_positive_integer(cfg.keep_recent_sections or cfg.keep_recent),
    summary_items = normalize_positive_integer(cfg.summary_items or cfg.max_summary_items),
  }
end

local function merge_transcript_compaction_config(agent_cfg, global_cfg)
  local agent = normalize_transcript_compaction_config(agent_cfg)
  local global = normalize_transcript_compaction_config(global_cfg)
  local enabled
  if agent.enabled ~= nil then
    enabled = agent.enabled == true
  elseif global.enabled ~= nil then
    enabled = global.enabled == true
  else
    enabled = false
  end

  return {
    enabled = enabled,
    min_sections = agent.min_sections or global.min_sections or 48,
    keep_recent_sections = agent.keep_recent_sections or global.keep_recent_sections or 24,
    summary_items = agent.summary_items or global.summary_items or 6,
  }
end

local function normalize_runtime_compaction_config(value)
  if type(value) == "boolean" then
    return { enabled = value }
  end

  local cfg = type(value) == "table" and vim.deepcopy(value) or {}
  return {
    enabled = cfg.enabled,
    keep_recent_items = normalize_positive_integer(cfg.keep_recent_items or cfg.keep_recent),
    keep_recent_tools = normalize_positive_integer(cfg.keep_recent_tools or cfg.keep_recent_tool_entries),
    body_limit = normalize_positive_integer(cfg.body_limit or cfg.item_body_limit),
    tool_output_limit = normalize_positive_integer(cfg.tool_output_limit or cfg.tool_body_limit),
  }
end

local function merge_runtime_compaction_config(agent_cfg, global_cfg)
  local agent = normalize_runtime_compaction_config(agent_cfg)
  local global = normalize_runtime_compaction_config(global_cfg)
  local enabled
  if agent.enabled ~= nil then
    enabled = agent.enabled == true
  elseif global.enabled ~= nil then
    enabled = global.enabled == true
  else
    enabled = true
  end

  return {
    enabled = enabled,
    keep_recent_items = agent.keep_recent_items or global.keep_recent_items or 80,
    keep_recent_tools = agent.keep_recent_tools or global.keep_recent_tools or 40,
    body_limit = agent.body_limit or global.body_limit or 12000,
    tool_output_limit = agent.tool_output_limit or global.tool_output_limit or 24000,
  }
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

local function resolve_boolean_option(agent_value, global_value, default_value)
  if agent_value ~= nil then
    return agent_value == true
  end
  if global_value ~= nil then
    return global_value == true
  end
  return default_value == true
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
    footer_animation = resolve_boolean_option(agent_acp.footer_animation, global_cfg.footer_animation, true),
    table_layout = normalize_table_layout(agent_acp.table_layout or global_cfg.table_layout),
    release_buffer_on_hide = resolve_boolean_option(
      agent_acp.release_buffer_on_hide,
      global_cfg.release_buffer_on_hide,
      true
    ),
    auto_permission = agent_acp.auto_permission or global_cfg.auto_permission,
    default_mode = agent_acp.default_mode or global_cfg.default_mode,
    initial_model = agent_acp.initial_model or global_cfg.initial_model,
    buffer_background = normalize_color(agent_acp.buffer_background or global_cfg.buffer_background),
    buffer_inactive_background = normalize_color(
      agent_acp.buffer_inactive_background or global_cfg.buffer_inactive_background
    ),
    transcript_max_lines = normalize_positive_integer(
      agent_acp.transcript_max_lines or global_cfg.transcript_max_lines
    ),
    transcript_compaction = merge_transcript_compaction_config(
      agent_acp.transcript_compaction,
      global_cfg.transcript_compaction
    ),
    runtime_compaction = merge_runtime_compaction_config(
      agent_acp.runtime_compaction,
      global_cfg.runtime_compaction
    ),
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
      table_layout = session.table_layout,
      release_buffer_on_hide = session.release_buffer_on_hide,
      buffer_background = session.buffer_background,
      buffer_inactive_background = session.buffer_inactive_background,
      transcript_max_lines = session.transcript_max_lines,
      transcript_compaction = vim.deepcopy(session.transcript_compaction or {}),
      runtime_compaction = vim.deepcopy(session.runtime_compaction or {}),
      footer_animation = session.footer_animation,
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
