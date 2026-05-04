local M = {}

function M.setup(deps)
  local state = deps.state
  local acp_logic = deps.acp_logic
  local agent_logic = deps.agent_logic
  local backend_logic = deps.backend_logic
  local window = deps.window
  local session_view = deps.session_view
  local session_agents_for_name = deps.session_agents_for_name
  local resolve_saved_snapshot = deps.resolve_saved_snapshot
  local current_editor_session_name = deps.current_editor_session_name
  local start_interactive_session = deps.start_interactive_session

  local module = {}
  local ACP_SNAPSHOT_DROP_KEYS = {
    available_commands = true,
    config_options = true,
    session_info = true,
    agent_info = true,
    agent_capabilities = true,
    model_catalog = true,
    mode_catalog = true,
    usage_stats = true,
    permission_rules = true,
    auto_switch = true,
    manual_config_overrides = true,
    conversation_timeline = true,
    conversation_timeline_index = true,
    conversation_next_item_id = true,
    tool_calls = true,
    tool_timeline = true,
    tool_timeline_index = true,
    pending_switch_history = true,
    current_stream_key = true,
    current_stream_heading = true,
    current_stream_at_line_start = true,
    current_stream_item_id = true,
    acp_available_commands = true,
    acp_config_options = true,
    acp_session_info = true,
    acp_agent_info = true,
    acp_agent_capabilities = true,
    acp_session_capabilities = true,
    acp_model_catalog = true,
    acp_mode_catalog = true,
    acp_usage_stats = true,
    acp_permission_rules = true,
    acp_auto_switch = true,
    acp_manual_config_overrides = true,
    acp_tool_timeline = true,
    acp_conversation_timeline = true,
    on_idle_callback = true,
  }

  local function deepcopy_value(value)
    local ok, copied = pcall(vim.deepcopy, value)
    return ok and copied or value
  end

  local function compact_session_snapshot(session)
    if type(session) ~= "table" then
      return nil
    end
    if not acp_logic.is_acp_backend(session.backend) then
      return deepcopy_value(session)
    end

    local snapshot = {}
    for key, value in pairs(session) do
      if key == "view_state" then
        local source_winid = type(value) == "table" and value.source_winid or nil
        if source_winid ~= nil then
          snapshot.view_state = { source_winid = source_winid }
        end
      elseif not ACP_SNAPSHOT_DROP_KEYS[key] then
        snapshot[key] = deepcopy_value(value)
      end
    end
    return snapshot
  end

  function module.hide_session_agent_pane(agent_name)
    local session = state.sessions[agent_name]
    if not session or not session.pane_id or session.pane_id == "" or session.hidden then
      return false
    end

    local _, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, agent_logic.get_interactive_agent(agent_name))
    if not backend_mod or type(backend_mod.break_pane) ~= "function" then
      return false
    end

    backend_mod.break_pane(session.pane_id)
    session.hidden = true
    return true
  end

  function module.show_session_agent_pane(agent_name)
    local session = state.sessions[agent_name]
    if not session or not session.pane_id or session.pane_id == "" or not session.hidden then
      return false
    end

    local agent_cfg = agent_logic.get_interactive_agent(agent_name) or {}
    local _, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, agent_cfg)
    if not backend_mod or type(backend_mod.join_pane) ~= "function" then
      return false
    end

    if type(backend_mod.configure_pane) == "function" then
      local refocus = (agent_cfg and agent_cfg.refocus_on_send) or (state.opts and state.opts.refocus_on_send) or false
      backend_mod.configure_pane(session.pane_id, {
        refocus_on_send = refocus,
        source_winid = vim.api.nvim_get_current_win(),
      })
    end

    backend_mod.join_pane(
      session.pane_id,
      agent_cfg.pane_size or 30,
      agent_cfg.is_vertical or false,
      function(success)
        if success and state.sessions[agent_name] then
          state.sessions[agent_name].hidden = false
        end
      end,
      session
    )
    return true
  end

  function module.event_session_name(opts)
    local name = opts and opts.session_name or nil
    if type(name) ~= "string" or name == "" then
      local data = opts and opts.data or nil
      name = data and data.session or nil
    end
    if type(name) ~= "string" or name == "" then
      return nil
    end
    return name
  end

  function module.capture_runtime_session(session_name, opts)
    opts = opts or {}
    if not session_name or session_name == "" then
      return nil
    end

    local view = session_view(session_name)
    if not view then
      return nil
    end
    local previous_agents = vim.deepcopy(view.agents or {})
    local previous_visible_agents = vim.deepcopy(view.visible_agents or {})
    local previous_last_agent = view.last_agent
    local previous_open_agent = view.open_agent
    view.agents = {}
    view.visible_agents = {}
    view.last_agent = nil
    view.open_agent = nil

    for agent_name, snapshot in pairs(previous_agents) do
      local _, _, pane_alive, live_snapshot = resolve_saved_snapshot(agent_name, snapshot)
      if pane_alive then
        local preserved = deepcopy_value(snapshot)
        if type(live_snapshot) == "table" then
          preserved = vim.tbl_extend("force", preserved, live_snapshot)
        end
        preserved.session_scope = session_name
        view.agents[agent_name] = compact_session_snapshot(preserved)
        if previous_visible_agents[agent_name] then
          view.visible_agents[agent_name] = true
        end
        if previous_last_agent == agent_name then
          view.last_agent = agent_name
        end
        if previous_open_agent == agent_name then
          view.open_agent = agent_name
        end
      end
    end

    local ordered = {}
    for agent_name, session in pairs(state.sessions or {}) do
      if type(session) == "table" and session.pane_id and session.pane_id ~= "" then
        ordered[#ordered + 1] = agent_name
      end
    end
    table.sort(ordered)

    for _, agent_name in ipairs(ordered) do
      local session = state.sessions[agent_name]
      local visible = not session.hidden
      local snapshot = compact_session_snapshot(session)
      snapshot.session_scope = session_name
      view.agents[agent_name] = snapshot
      if visible then
        view.visible_agents[agent_name] = true
      end
      if state.open_agent == agent_name then
        view.last_agent = agent_name
        view.open_agent = agent_name
      elseif not view.last_agent then
        view.last_agent = agent_name
      end

      if opts.hide_visible and visible then
        module.hide_session_agent_pane(agent_name)
        view.agents[agent_name].hidden = true
      end

      if opts.detach_runtime then
        state.sessions[agent_name] = nil
      end
    end

    if not view.last_agent then
      view.last_agent = previous_last_agent
    end
    if not view.open_agent then
      view.open_agent = previous_open_agent
    end

    if opts.detach_runtime and state.open_agent then
      if window.is_open() then
        window.close({ force = true, keep_buffer = true })
      end
      state.open_agent = nil
    end

    return view
  end

  function module.restore_captured_session(session_name)
    local view = session_view(session_name)
    if not view then
      return
    end

    local ordered = session_agents_for_name(session_name)
    if #ordered == 0 then
      return
    end

    if view.last_agent then
      for idx, agent_name in ipairs(ordered) do
        if agent_name == view.last_agent then
          table.remove(ordered, idx)
          table.insert(ordered, 1, agent_name)
          break
        end
      end
    end

    for _, agent_name in ipairs(ordered) do
      local snapshot = view.agents[agent_name]
      local backend_name, backend_mod, pane_alive, live_snapshot = resolve_saved_snapshot(agent_name, snapshot)

      if snapshot and backend_mod and pane_alive then
        local restored = vim.deepcopy(snapshot)
        if acp_logic.is_acp_backend(backend_name) then
          restored = vim.tbl_extend("force", restored, live_snapshot or {})
        end
        restored.session_scope = session_name
        restored.hidden = true
        state.sessions[agent_name] = restored
        if view.visible_agents[agent_name] then
          module.show_session_agent_pane(agent_name)
        end
      else
        view.agents[agent_name] = nil
        view.visible_agents[agent_name] = nil
      end
    end
  end

  function module.on_session_save_pre(opts)
    local session_name = module.event_session_name(opts)
    if not session_name then
      return
    end

    state.current_session_name = session_name
    module.capture_runtime_session(session_name, { hide_visible = false, detach_runtime = false })
  end

  function module.resession_snapshot()
    local session_name = current_editor_session_name()
    if not session_name then
      return nil
    end
    local view = module.capture_runtime_session(session_name, { hide_visible = false, detach_runtime = false })
    if not view then
      return nil
    end
    local snapshot = vim.deepcopy(view)
    snapshot.session_name = session_name
    return snapshot
  end

  function module.resession_pre_load(_data)
    local current = current_editor_session_name()
    if not current then
      return
    end

    module.capture_runtime_session(current, { hide_visible = true, detach_runtime = true })
  end

  function module.resession_post_load(data)
    if type(data) ~= "table" then
      return
    end
    local session_name = data.session_name
    if not session_name then
      return
    end

    state.current_session_name = session_name
    state.session_views[session_name] = vim.deepcopy(data)
    module.restore_captured_session(session_name)
    if data.open_agent and state.sessions[data.open_agent] and state.sessions[data.open_agent].pane_id then
      vim.schedule(function()
        if not (state.sessions[data.open_agent] and state.sessions[data.open_agent].pane_id) then
          return
        end
        start_interactive_session({
          agent_name = data.open_agent,
          reuse = true,
          stay_hidden = false,
        })
      end)
    end
  end

  function module.on_session_load_pre(opts)
    module.resession_pre_load(opts)
  end

  function module.on_session_load_post(opts)
    local session_name = module.event_session_name(opts)
    if not session_name then
      return
    end
    state.current_session_name = session_name
  end

  return module
end

return M
