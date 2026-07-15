local M = {}

local state = require("lazyagent.logic.state")
local acp_logic = require("lazyagent.logic.acp")
local agent_logic = require("lazyagent.logic.agent")
local backend_logic = require("lazyagent.logic.backend")
local window = require("lazyagent.window")
local identity = require("lazyagent.logic.session.identity")

function M.current_editor_session_name()
  local value = state.current_session_name
  if type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

function M.session_view(session_name)
  if not session_name or session_name == "" then
    return nil
  end
  state.session_views = state.session_views or {}
  local view = state.session_views[session_name]
  if type(view) ~= "table" then
    view = {}
    state.session_views[session_name] = view
  end
  view.agents = type(view.agents) == "table" and view.agents or {}
  view.visible_agents = type(view.visible_agents) == "table" and view.visible_agents or {}
  view.open_agent = type(view.open_agent) == "string" and view.open_agent or nil
  return view
end

function M.session_agents_for_name(session_name)
  local names = {}
  local view = M.session_view(session_name)
  if not view then
    return names
  end

  for name, snapshot in pairs(view.agents) do
    if type(snapshot) == "table" and snapshot.pane_id and snapshot.pane_id ~= "" then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

function M.resolve_saved_snapshot(agent_name, snapshot)
  if type(snapshot) ~= "table" or not snapshot.pane_id or snapshot.pane_id == "" then
    return nil, nil, false, nil
  end

  local agent_cfg = agent_logic.get_interactive_agent(agent_name)
  local backend_name, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, agent_cfg)
  if not backend_mod then
    return backend_name, backend_mod, false, nil
  end

  local pane_alive = false
  local live_snapshot = nil
  if acp_logic.is_acp_backend(backend_name) and type(backend_mod.get_runtime_snapshot) == "function" then
    live_snapshot = backend_mod.get_runtime_snapshot(snapshot.pane_id)
    pane_alive = type(live_snapshot) == "table" and live_snapshot.acp_failed ~= true
  elseif type(backend_mod.pane_exists) == "function" then
    pane_alive = backend_mod.pane_exists(snapshot.pane_id)
  else
    pane_alive = true
  end

  return backend_name, backend_mod, pane_alive, live_snapshot
end

function M.mark_session_scope(agent_name, session_name)
  local session = agent_name and state.sessions and state.sessions[agent_name] or nil
  if not session then
    return
  end
  session.session_scope = session_name or M.current_editor_session_name()
end

function M.is_acp_agent(name)
  if not name or name == "" then
    return false
  end

  local session_key, session = identity.resolve(state, name)
  if session and acp_logic.is_acp_backend(session.backend) then
    return true
  end
  local provider_id = identity.provider_id(session_key, session)
  local agent_cfg = agent_logic.get_interactive_agent(provider_id)
  if not agent_cfg then
    return false
  end

  local backend_name = select(1, backend_logic.resolve_backend_for_agent(provider_id, agent_cfg))
  return acp_logic.is_acp_backend(backend_name)
end

function M.current_context_acp_agent()
  local bufnr = vim.api.nvim_get_current_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local candidates = {
    vim.b[bufnr] and vim.b[bufnr].lazyagent_acp_agent or nil,
    vim.b[bufnr] and vim.b[bufnr].lazyagent_agent or nil,
  }

  for _, candidate in ipairs(candidates) do
    if M.is_acp_agent(candidate) then
      return candidate
    end
  end

  return nil
end

function M.active_acp_agents()
  local active = {}
  for session_key, session in pairs(state.sessions or {}) do
    if session and session.pane_id and session.pane_id ~= "" and M.is_acp_agent(session_key) then
      active[#active + 1] = session_key
    end
  end
  table.sort(active)
  return active
end

function M.preferred_session_agent(session_key)
  local view = M.session_view(session_key)
  if view and view.last_agent and M.is_acp_agent(view.last_agent) then
    local snapshot = view.agents and view.agents[view.last_agent] or nil
    if type(snapshot) == "table" and snapshot.pane_id and snapshot.pane_id ~= "" then
      return view.last_agent
    end
  end

  local names = M.session_agents_for_name(session_key)
  if #names == 1 and M.is_acp_agent(names[1]) then
    return names[1]
  end

  return nil
end

function M.resolve_acp_target_agent(agent_name, callback)
  if agent_name and agent_name ~= "" then
    local session_key = identity.resolve(state, agent_name)
    callback(session_key)
    return
  end

  local current = M.current_context_acp_agent()
  if current then
    callback(current)
    return
  end

  local scoped = M.preferred_session_agent(M.current_editor_session_name())
  if scoped then
    callback(scoped)
    return
  end

  local active = M.active_acp_agents()
  if #active == 1 then
    callback(active[1])
    return
  end

  local available = agent_logic.available_acp_agents()
  if #available == 0 then
    vim.notify("LazyAgentACP: no ACP-enabled agents are configured", vim.log.levels.WARN)
    return
  end

  if #available == 1 then
    callback(available[1])
    return
  end

  vim.ui.select(available, { prompt = "Choose ACP agent:" }, function(choice)
    if choice and choice ~= "" then
      callback(choice)
    end
  end)
end

function M.resolve_acp_switch_target_agent(current_agent, target_agent, callback)
  if target_agent and target_agent ~= "" then
    if target_agent == current_agent then
      vim.notify("LazyAgentACP: already using '" .. tostring(target_agent) .. "'", vim.log.levels.INFO)
      return
    end
    if not M.is_acp_agent(target_agent) then
      vim.notify("LazyAgentACP: agent '" .. tostring(target_agent) .. "' is not using ACP", vim.log.levels.WARN)
      return
    end
    callback(target_agent)
    return
  end

  local candidates = {}
  for _, name in ipairs(agent_logic.available_acp_agents()) do
    if name ~= current_agent then
      candidates[#candidates + 1] = name
    end
  end

  if #candidates == 0 then
    vim.notify("LazyAgentACP: no alternate ACP providers are configured", vim.log.levels.INFO)
    return
  end

  if #candidates == 1 then
    callback(candidates[1])
    return
  end

  vim.ui.select(candidates, {
    prompt = "Switch ACP provider:",
    format_item = function(item)
      return string.format("%s -> %s", current_agent, item)
    end,
  }, function(choice)
    if choice and choice ~= "" then
      callback(choice)
    end
  end)
end

function M.resolve_active_acp_session(agent_name, callback)
  callback = callback or function() end

  local function active_acp_key(name)
    local session_key, session = identity.resolve(state, name)
    if session and session.pane_id and session.pane_id ~= "" and M.is_acp_agent(session_key) then
      return session_key
    end
    return nil
  end

  if agent_name and agent_name ~= "" then
    local session_key = active_acp_key(agent_name)
    if not session_key then
      vim.notify("LazyAgentConversation: no active ACP session found for '" .. tostring(agent_name) .. "'", vim.log.levels.WARN)
      return
    end
    callback(session_key)
    return
  end

  local current = M.current_context_acp_agent()
  local current_key = current and active_acp_key(current) or nil
  if current_key then
    callback(current_key)
    return
  end

  local scoped = M.preferred_session_agent(M.current_editor_session_name())
  local scoped_key = scoped and active_acp_key(scoped) or nil
  if scoped_key then
    callback(scoped_key)
    return
  end

  local active = {}
  for _, name in ipairs(M.active_acp_agents()) do
    local session_key = active_acp_key(name)
    if session_key then
      table.insert(active, session_key)
    end
  end

  if #active == 0 then
    vim.notify("LazyAgentConversation: no active ACP sessions found", vim.log.levels.INFO)
    return
  end

  if #active == 1 then
    callback(active[1])
    return
  end

  vim.ui.select(active, { prompt = "Choose ACP agent conversation to save:" }, function(choice)
    if choice and choice ~= "" then
      callback(choice)
    end
  end)
end

function M.capture_switch_scratch_state(agent_name)
  if state.open_agent ~= agent_name or not window.is_open() then
    return nil
  end

  local bufnr = window.get_bufnr()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  return {
    was_open = true,
    text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n"),
    source_bufnr = vim.b[bufnr].lazyagent_source_bufnr,
    source_winid = vim.b[bufnr].lazyagent_source_winid,
  }
end

function M.resolve_switch_anchor(runtime_snapshot, scratch_state)
  local source_winid = (scratch_state and scratch_state.source_winid) or (runtime_snapshot and runtime_snapshot.source_winid) or nil
  if source_winid and not vim.api.nvim_win_is_valid(source_winid) then
    source_winid = nil
  end

  if not source_winid then
    local current_winid = vim.api.nvim_get_current_win()
    if current_winid and vim.api.nvim_win_is_valid(current_winid) then
      local current_bufnr = vim.api.nvim_win_get_buf(current_winid)
      if not (vim.b[current_bufnr] and vim.b[current_bufnr].lazyagent_acp_pane_id) then
        source_winid = current_winid
      end
    end
  end

  local source_bufnr = scratch_state and scratch_state.source_bufnr or nil
  if source_bufnr and not vim.api.nvim_buf_is_valid(source_bufnr) then
    source_bufnr = nil
  end
  if not source_bufnr and source_winid and vim.api.nvim_win_is_valid(source_winid) then
    source_bufnr = vim.api.nvim_win_get_buf(source_winid)
  end
  if not source_bufnr or not vim.api.nvim_buf_is_valid(source_bufnr) then
    source_bufnr = vim.api.nvim_get_current_buf()
  end

  return {
    source_bufnr = source_bufnr,
    source_winid = source_winid,
  }
end

return M
