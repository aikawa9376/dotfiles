local M = {}
local session_identity = require("lazyagent.logic.session.identity")

function M.setup(deps)
  local state = deps.state
  local acp_logic = deps.acp_logic
  local agent_logic = deps.agent_logic
  local backend_logic = deps.backend_logic
  local cache_logic = deps.cache_logic
  local window = deps.window
  local persistence = deps.persistence
  local util = deps.util
  local maybe_kill_pane = deps.maybe_kill_pane
  local wait_for_idle_before_close = deps.wait_for_idle_before_close
  local maybe_disable_watchers = deps.maybe_disable_watchers
  local resolve_acp_target_agent = deps.resolve_acp_target_agent
  local current_editor_session_name = deps.current_editor_session_name
  local build_resume_prompt = deps.build_resume_prompt
  local select_saved_conversation = deps.select_saved_conversation
  local persist_conversation_capture = deps.persist_conversation_capture
  local backend_supports_persistence = deps.backend_supports_persistence
  local refresh_acp_command_visibility = deps.refresh_acp_command_visibility
  local call_watch = deps.call_watch
  local ensure_session = deps.ensure_session
  local start_interactive_session = deps.start_interactive_session

  local module = {}

  local function cleanup_agent_external_configs(agent_name)
    if string.lower(agent_name) ~= "cursor" then return end
    local function remove_lazyagent_from(path)
      local fh = io.open(path, "r")
      if not fh then return end
      local ok, cfg = pcall(vim.fn.json_decode, fh:read("*a"))
      fh:close()
      if not (ok and type(cfg) == "table") then return end
      local changed = false
      if type(cfg.mcpServers) == "table" and cfg.mcpServers.lazyagent then
        cfg.mcpServers.lazyagent = nil
        changed = true
      end
      if type(cfg.hooks) == "table" then
        for event, entries in pairs(cfg.hooks) do
          if type(entries) == "table" then
            local filtered = vim.tbl_filter(function(e)
              return not (type(e) == "table" and type(e.id) == "string" and e.id:match("^lazyagent%-"))
            end, entries)
            if #filtered ~= #entries then
              cfg.hooks[event] = #filtered > 0 and filtered or nil
              changed = true
            end
          end
        end
      end
      if changed then
        local fw = io.open(path, "w")
        if fw then fw:write(vim.fn.json_encode(cfg)); fw:close() end
      end
    end
    remove_lazyagent_from(vim.fn.expand("~/.cursor/mcp.json"))
    remove_lazyagent_from(vim.fn.expand("~/.cursor/hooks.json"))
  end

  local function purge_agent_session_views(agent_name)
    if not agent_name or agent_name == "" then
      return false
    end

    local removed = false
    for session_name, view in pairs(state.session_views or {}) do
      if type(view) == "table" then
        local changed = false
        if type(view.agents) == "table" and view.agents[agent_name] ~= nil then
          view.agents[agent_name] = nil
          changed = true
        end
        if type(view.visible_agents) == "table" and view.visible_agents[agent_name] ~= nil then
          view.visible_agents[agent_name] = nil
          changed = true
        end
        if view.last_agent == agent_name then
          view.last_agent = nil
          changed = true
        end
        if view.open_agent == agent_name then
          view.open_agent = nil
          changed = true
        end
        if changed then
          local has_agents = type(view.agents) == "table" and next(view.agents) ~= nil
          local has_visible = type(view.visible_agents) == "table" and next(view.visible_agents) ~= nil
          if not has_agents and not has_visible and not view.last_agent and not view.open_agent then
            state.session_views[session_name] = nil
          end
          removed = true
        end
      end
    end

    return removed
  end

  local function finalize_closed_session(agent_name, session, backend_mod)
    if backend_mod and session and type(backend_mod.clear_pane_config) == "function" then
      backend_mod.clear_pane_config(session.pane_id)
    end
    session_identity.deactivate(state, agent_name, session)
    state.sessions[agent_name] = nil
    purge_agent_session_views(agent_name)
    persistence.remove_session(agent_name, session and session.cwd or nil)
    maybe_disable_watchers()
    cleanup_agent_external_configs(agent_name)
    if backend_mod and type(backend_mod.cleanup_if_idle) == "function" then
      pcall(backend_mod.cleanup_if_idle)
    end
    util.fire_event("SessionStopped", { agent_name = agent_name })
  end

  function module.force_close_session(agent_name)
    agent_name = session_identity.resolve(state, agent_name)
    if state.open_agent == agent_name then
      local bufnr = window.get_bufnr()
      if window.close() and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
      state.open_agent = nil
    end

    local session = state.sessions[agent_name]
    if not session or not session.pane_id or session.pane_id == "" then
      session_identity.deactivate(state, agent_name, session)
      state.sessions[agent_name] = nil
      purge_agent_session_views(agent_name)
      persistence.remove_session(agent_name)
      maybe_disable_watchers()
      return true
    end

    local _, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, nil)
    if backend_mod and type(backend_mod.kill_pane) == "function" then
      maybe_kill_pane(agent_name, session.pane_id, backend_mod, false)
    end
    finalize_closed_session(agent_name, session, backend_mod)
    return true
  end

  function module.with_acp_session(agent_name, callback)
    resolve_acp_target_agent(agent_name, function(chosen)
      if not chosen or chosen == "" then
        return
      end

      local agent_cfg = agent_logic.get_interactive_agent(chosen)
      if not agent_cfg then
        vim.notify("LazyAgentACP: agent '" .. tostring(chosen) .. "' is not configured", vim.log.levels.WARN)
        return
      end

      local backend_name, backend_mod = backend_logic.resolve_backend_for_agent(chosen, agent_cfg)
      if not acp_logic.is_acp_backend(backend_name) then
        vim.notify("LazyAgentACP: agent '" .. tostring(chosen) .. "' is not using ACP", vim.log.levels.WARN)
        return
      end

      ensure_session(chosen, agent_cfg, true, function(pane_id)
        if not pane_id or pane_id == "" then
          vim.notify("LazyAgentACP: failed to obtain a session for '" .. tostring(chosen) .. "'", vim.log.levels.ERROR)
          return
        end
        callback(chosen, pane_id, backend_mod, agent_cfg)
      end)
    end)
  end

  function module.reopen_acp_window(agent_name)
    resolve_acp_target_agent(agent_name, function(chosen)
      if not chosen or chosen == "" then
        return
      end
      start_interactive_session({
        agent_name = chosen,
        reuse = true,
        stay_hidden = false,
      })
    end)
  end

  function module.capture_and_save_session(agent_name, open_file, on_done, opts)
    agent_name = session_identity.resolve(state, agent_name)
    opts = opts or {}
    on_done = on_done or function() end
    if not agent_name or agent_name == "" then
      on_done()
      return false
    end

    local s = state.sessions[agent_name]
    if not s or not s.pane_id or s.pane_id == "" then
      on_done()
      return false
    end

    local _, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, nil)
    if not backend_mod or type(backend_mod.capture_pane) ~= "function" then
      on_done()
      return false
    end

    backend_mod.capture_pane(s.pane_id, function(text)
      vim.schedule(function()
        if not text or text == "" then
          vim.notify("LazyAgentConversation: captured conversation was empty for agent '" .. tostring(agent_name) .. "'", vim.log.levels.INFO)
          on_done()
          return
        end

        local lines = vim.split(text, "\n")

        if opts.line_limit and tonumber(opts.line_limit) then
          local limit = tonumber(opts.line_limit)
          if #lines > limit then
            local start_idx = #lines - limit + 1
            local user_idx = nil
            for i = start_idx, #lines do
              if lines[i]:match("^─ .*User") then
                user_idx = i
                break
              end
            end
            if user_idx then
              start_idx = user_idx
            end
            lines = vim.list_slice(lines, start_idx)
          end
        end

        local path = persist_conversation_capture(agent_name, s, lines, {
          merge_with_last_save = opts.merge_with_last_save,
        })

        if open_file then
          util.open_in_normal_win(path)
          vim.cmd("setlocal nowrap")
        end

        on_done(path)
      end)
    end)

    return true
  end

  function module.restart_session(agent_name)
    agent_name = session_identity.resolve(state, agent_name)
    local function restart(chosen)
      if not chosen or chosen == "" then return end
      module.close_session(chosen)
      vim.defer_fn(function()
        start_interactive_session({ agent_name = chosen, reuse = false })
      end, 100)
    end

    if agent_name and agent_name ~= "" then
      restart(agent_name)
    else
      agent_logic.resolve_target_agent(nil, nil, restart)
    end
  end

  function module.close_session(agent_name)
    agent_name = session_identity.resolve(state, agent_name)
    if not agent_name or agent_name == "" then
      return
    end

    if state.open_agent == agent_name then
      local bufnr = window.get_bufnr()
      if window.close() and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
      state.open_agent = nil
    end

    local s = state.sessions[agent_name]
    if not s or not s.pane_id or s.pane_id == "" then
      state.sessions[agent_name] = nil
      purge_agent_session_views(agent_name)
      persistence.remove_session(agent_name)
      maybe_disable_watchers()
      return
    end

    wait_for_idle_before_close(agent_name, function()
      local s2 = state.sessions[agent_name]
      if not s2 or not s2.pane_id or s2.pane_id == "" then return end

      local agent_cfg = agent_logic.get_interactive_agent(agent_name)
      local save_conv = (agent_cfg and agent_cfg.save_conversation_on_close) or (state.opts and state.opts.save_conversation_on_close)
      local open_conv = (agent_cfg and agent_cfg.open_conversation_on_save) or (state.opts and state.opts.open_conversation_on_save)

      local _, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, nil)

      if save_conv and backend_mod and type(backend_mod.capture_pane) == "function" then
        module.capture_and_save_session(agent_name, open_conv, function()
          local _, backend_mod2 = backend_logic.resolve_backend_for_agent(agent_name, nil)
          if backend_mod2 and type(backend_mod2.kill_pane) == "function" then
            maybe_kill_pane(agent_name, s2.pane_id, backend_mod2, false)
          end
          finalize_closed_session(agent_name, s2, backend_mod2)
        end, {
          merge_with_last_save = s2.merge_conversation_on_next_save,
        })
        return
      end

      if backend_mod and type(backend_mod.kill_pane) == "function" then
        maybe_kill_pane(agent_name, s2.pane_id, backend_mod, false)
      end
      finalize_closed_session(agent_name, s2, backend_mod)
    end)
  end

  function module.close_all_sessions(sync)
    local seen_backends = {}
    local closed_panes = {}
    for name, s in pairs(state.sessions) do
      if s and s.pane_id and s.pane_id ~= "" then
        closed_panes[tostring(s.pane_id)] = true
        local agent_cfg = agent_logic.get_interactive_agent(name)
        local save_conv = (agent_cfg and agent_cfg.save_conversation_on_close) or (state.opts and state.opts.save_conversation_on_close)
        local open_conv = (agent_cfg and agent_cfg.open_conversation_on_save) or (state.opts and state.opts.open_conversation_on_save)
        local _, backend_mod = backend_logic.resolve_backend_for_agent(name, nil)
        if backend_mod then seen_backends[backend_mod] = true end

        if sync then
          local resume_enabled = (agent_cfg and agent_cfg.resume) or (state.opts and state.opts.resume) or (s and s.force_resume)

          if save_conv and backend_mod and type(backend_mod.capture_pane_sync) == "function" then
            local text = backend_mod.capture_pane_sync(s.pane_id)
            if text and text ~= "" then
              local lines = vim.split(text, "\n")
              persist_conversation_capture(name, s, lines, {
                merge_with_last_save = s.merge_conversation_on_next_save,
              })
            end
          end

          if resume_enabled and backend_supports_persistence(s.backend) then
            if not s.hidden then
              if backend_mod and type(backend_mod.break_pane_sync) == "function" then
                backend_mod.break_pane_sync(s.pane_id)
              elseif backend_mod and type(backend_mod.break_pane) == "function" then
                backend_mod.break_pane(s.pane_id)
              end
            end
          else
            if backend_mod and type(backend_mod.kill_pane_sync) == "function" then
              maybe_kill_pane(name, s.pane_id, backend_mod, true)
            elseif backend_mod and type(backend_mod.kill_pane) == "function" then
              maybe_kill_pane(name, s.pane_id, backend_mod, false)
            end
            persistence.remove_session(name, s.cwd)
          end
          state.sessions[name] = nil
        else
          if save_conv and backend_mod and type(backend_mod.capture_pane) == "function" then
            module.capture_and_save_session(name, open_conv, function()
              local _, backend_mod2 = backend_logic.resolve_backend_for_agent(name, nil)
              if backend_mod2 and type(backend_mod2.kill_pane) == "function" then
                maybe_kill_pane(name, s.pane_id, backend_mod2, false)
              end
              state.sessions[name] = nil
            end, {
              merge_with_last_save = s.merge_conversation_on_next_save,
            })
          else
            if backend_mod and type(backend_mod.kill_pane) == "function" then
              maybe_kill_pane(name, s.pane_id, backend_mod, false)
            end
            state.sessions[name] = nil
          end
        end
      else
        state.sessions[name] = nil
      end
    end

    for session_name, view in pairs(state.session_views or {}) do
      if type(view) == "table" and type(view.agents) == "table" then
        for agent_name, saved in pairs(view.agents) do
          local pane_id = saved and saved.pane_id or nil
          local pane_key = pane_id and tostring(pane_id) or nil
          if pane_key and not closed_panes[pane_key] then
            closed_panes[pane_key] = true
            local _, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, nil)
            if backend_mod then
              seen_backends[backend_mod] = true
            end
            if sync then
              if backend_mod and type(backend_mod.kill_pane_sync) == "function" then
                maybe_kill_pane(agent_name, pane_id, backend_mod, true)
              elseif backend_mod and type(backend_mod.kill_pane) == "function" then
                maybe_kill_pane(agent_name, pane_id, backend_mod, false)
              end
            else
              if backend_mod and type(backend_mod.kill_pane) == "function" then
                maybe_kill_pane(agent_name, pane_id, backend_mod, false)
              end
            end
            persistence.remove_session(agent_name, saved.cwd)
          end
        end
      end
      state.session_views[session_name] = nil
    end
    state.current_session_name = nil
    call_watch("disable")
    refresh_acp_command_visibility()

    for backend_mod, _ in pairs(seen_backends) do
      if backend_mod and type(backend_mod.cleanup_if_idle) == "function" then
        pcall(backend_mod.cleanup_if_idle)
      end
    end
  end

  local function session_has_visible_pane(session, backend_mod)
    if not session or not session.pane_id or session.pane_id == "" then
      return false
    end
    if session.hidden == true then
      return false
    end
    if backend_mod and type(backend_mod.get_pane_info) == "function" then
      local ok, info = pcall(backend_mod.get_pane_info, session.pane_id)
      if ok and info == false then
        session.hidden = true
        return false
      end
    end
    return true
  end

  local function mark_agent_hidden_in_views(agent_name)
    for _, view in pairs(state.session_views or {}) do
      if type(view) == "table" then
        if type(view.visible_agents) == "table" then
          view.visible_agents[agent_name] = nil
        end
        if view.open_agent == agent_name then
          view.open_agent = nil
        end
        if not view.last_agent then
          view.last_agent = agent_name
        end
      end
    end
  end

  local function close_visible_scratch_window(force_delete)
    if not window.is_open() then
      state.open_agent = nil
      return true
    end

    local bufnr = window.get_bufnr()
    if not window.close({ keep_buffer = not force_delete }) then
      return false
    end
    if force_delete and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    state.open_agent = nil
    return true
  end

  local function hide_agent_ui(agent_name)
    if not agent_name or agent_name == "" then
      return false
    end

    local hidden = false
    local session = state.sessions[agent_name]
    local agent_cfg = agent_logic.get_interactive_agent(agent_name)
    local backend_name, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, agent_cfg)
    local preserve_scratch = acp_logic.is_acp_backend(backend_name)

    if state.open_agent == agent_name and window.is_open() then
      local bufnr = window.get_bufnr()
      if window.close({ keep_buffer = preserve_scratch }) then
        if not preserve_scratch and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_delete(bufnr, { force = true })
        end
        state.open_agent = nil
        hidden = true
      else
        return false
      end
    end

    if session_has_visible_pane(session, backend_mod) then
      if backend_mod and type(backend_mod.break_pane) == "function" then
        backend_mod.break_pane(session.pane_id)
        session.hidden = true
        hidden = true
      end
    end

    mark_agent_hidden_in_views(agent_name)
    return hidden
  end

  local function has_visible_lazyagent_ui()
    if window.is_open() then
      return true
    end

    for name, session in pairs(state.sessions or {}) do
      local _, backend_mod = backend_logic.resolve_backend_for_agent(name, nil)
      if session_has_visible_pane(session, backend_mod) then
        return true
      end
    end

    return false
  end

  local function hide_all_visible_lazyagent_ui()
    local hidden = false
    if window.is_open() then
      local agent_name = state.open_agent
      local force_delete = true
      if agent_name and agent_name ~= "" then
        local agent_cfg = agent_logic.get_interactive_agent(agent_name)
        local backend_name = select(1, backend_logic.resolve_backend_for_agent(agent_name, agent_cfg))
        force_delete = not acp_logic.is_acp_backend(backend_name)
      end
      hidden = close_visible_scratch_window(force_delete) or hidden
    end

    for name, session in pairs(state.sessions or {}) do
      if session and session.pane_id and session.pane_id ~= "" then
        hidden = hide_agent_ui(name) or hidden
      end
    end

    for _, view in pairs(state.session_views or {}) do
      if type(view) == "table" then
        view.visible_agents = {}
        view.open_agent = nil
      end
    end

    refresh_acp_command_visibility()
    return hidden
  end

  function module.toggle_session(agent_name, opts)
    agent_name = session_identity.resolve(state, agent_name)
    opts = opts or {}
    local force_toggle_ui = opts.force_toggle_ui == true or opts.close_running == true

    if force_toggle_ui and (not agent_name or agent_name == "") then
      if has_visible_lazyagent_ui() then
        hide_all_visible_lazyagent_ui()
        return
      end
    end

    local function toggle(chosen)
      if not chosen or chosen == "" then return end
      local agent_cfg = agent_logic.get_interactive_agent(chosen)
      local backend_name = select(1, backend_logic.resolve_backend_for_agent(chosen, agent_cfg))
      local preserve_scratch = acp_logic.is_acp_backend(backend_name)

      if force_toggle_ui then
        local session = state.sessions[chosen]
        local _, backend_mod = backend_logic.resolve_backend_for_agent(chosen, agent_cfg)
        local is_open_agent = state.open_agent == chosen and window.is_open()
        if is_open_agent or session_has_visible_pane(session, backend_mod) then
          hide_agent_ui(chosen)
          return
        end
      end

      local initial_input = nil
      local current_mode = vim.fn.mode()
      if current_mode:match("[vV\x16]") then
        local start_pos = vim.fn.getpos("v")
        local cursor = vim.api.nvim_win_get_cursor(0)
        local start_line = start_pos and start_pos[2] or nil
        local end_line = cursor and cursor[1] or nil

        local file_path = vim.api.nvim_buf_get_name(0)
        if file_path and file_path ~= "" then
          file_path = vim.fn.fnamemodify(file_path, ":.")
        end

        if file_path and file_path ~= "" and start_line > 0 and end_line > 0 then
          if start_line == end_line then
            initial_input = string.format("@%s:%d", file_path, start_line)
          else
            initial_input = string.format("@%s:%d-%d", file_path, start_line, end_line)
          end
        end
      end

      if state.open_agent == chosen and window.is_open() then
        local bufnr = window.get_bufnr()
        window.close({ keep_buffer = preserve_scratch })
        if not preserve_scratch and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_delete(bufnr, { force = true })
        end
        state.open_agent = nil

        if state.sessions[chosen] and state.sessions[chosen].pane_id then
          local _, backend_mod = backend_logic.resolve_backend_for_agent(chosen, nil)
          if backend_mod and type(backend_mod.break_pane) == "function" then
            if type(backend_mod.get_pane_info) == "function" then
              backend_mod.get_pane_info(state.sessions[chosen].pane_id, function(info)
                if info then
                  state.sessions[chosen].last_size = info
                end
                backend_mod.break_pane(state.sessions[chosen].pane_id)
                state.sessions[chosen].hidden = true
              end)
            else
              backend_mod.break_pane(state.sessions[chosen].pane_id)
              state.sessions[chosen].hidden = true
            end
          end
        end

        if not initial_input then
          return
        end
      end

      start_interactive_session({ agent_name = chosen, reuse = true, initial_input = initial_input, stay_hidden = false })
    end

    agent_logic.resolve_target_agent(agent_name, nil, toggle)
  end

  function module.open_instant(agent_name)
    local function open(chosen)
      if not chosen or chosen == "" then return end

      if state.open_agent == chosen and window.is_open() then
        local bufnr = window.get_bufnr()
        if bufnr then
          local winid = vim.fn.bufwinid(bufnr)
          if winid ~= -1 then
            vim.api.nvim_set_current_win(winid)
            vim.cmd("startinsert")
            return
          end
        end
      end

      start_interactive_session({
        agent_name = chosen,
        reuse = true,
        stay_hidden = true,
        mode = "instant",
        title = " " .. chosen .. " (Instant) ",
        window_opts = {
          height = 3,
          width_ratio = 0.4,
        },
      })

      if state.sessions[chosen] then
        state.sessions[chosen].mode = "instant"
      end
    end

    agent_logic.resolve_target_agent(agent_name, nil, open)
  end

  function module.resume_conversation(agent_name)
    local function start_with_path(path)
      if vim.fn.filereadable(path) == 0 then
        vim.notify("LazyAgentResume: file not found: " .. path, vim.log.levels.ERROR)
        return
      end

      local rel_path = vim.fn.fnamemodify(path, ":.")
      if not rel_path or rel_path == "" then rel_path = path end
      local metadata = cache_logic.read_conversation_metadata(path)
      local content = metadata and build_resume_prompt(rel_path, metadata) or ("@" .. rel_path)

      local function start_for_agent(chosen_agent)
        if not chosen_agent or chosen_agent == "" then return end
        start_interactive_session({ agent_name = chosen_agent, reuse = true, initial_input = content })
      end

      if agent_name and agent_name ~= "" then
        start_for_agent(agent_name)
      else
        agent_logic.resolve_target_agent(nil, nil, start_for_agent)
      end
    end

    select_saved_conversation("Resume LazyAgent conversation:", start_with_path)
  end

  function module.attach_session(agent_name, pane_id)
    agent_name = session_identity.resolve(state, agent_name)
    local function list_panes()
      local fmt = "#{pane_id}\t#{pane_current_command}\t#{session_name}:#{window_name}"
      local ok, lines = pcall(vim.fn.systemlist, "tmux list-panes -a -F " .. vim.fn.shellescape(fmt))
      if not ok or not lines then return {} end
      local panes = {}
      for _, line in ipairs(lines) do
        local id, cmd, loc = line:match("^([^\t]+)\t([^\t]*)\t(.*)$")
        if id and id ~= "" then
          table.insert(panes, { id = id, cmd = cmd or "", loc = loc or "" })
        end
      end
      return panes
    end

    local function do_attach(chosen_agent, chosen_pane_id)
      if not chosen_agent or chosen_agent == "" then
        vim.notify("LazyAgentAttach: no agent selected", vim.log.levels.WARN)
        return
      end
      if not chosen_pane_id or chosen_pane_id == "" then
        vim.notify("LazyAgentAttach: no pane selected", vim.log.levels.WARN)
        return
      end

      local backend_name, backend_mod = backend_logic.resolve_backend_for_agent(chosen_agent, nil)
      if acp_logic.is_acp_backend(backend_name) then
        vim.notify("LazyAgentAttach: ACP sessions cannot be reattached after Neovim restart", vim.log.levels.WARN)
        return
      end

      if backend_mod and type(backend_mod.pane_exists) == "function" then
        if not backend_mod.pane_exists(chosen_pane_id) then
          vim.notify("LazyAgentAttach: pane " .. chosen_pane_id .. " not found", vim.log.levels.ERROR)
          return
        end
      end

      local agent_cfg = agent_logic.get_interactive_agent(chosen_agent) or {}
      state.sessions[chosen_agent] = {
        pane_id = chosen_pane_id,
        last_output = "",
        backend = backend_name,
        watch_enabled = (agent_cfg.watch ~= false),
        launch_cmd = nil,
        cwd = vim.fn.getcwd(),
        hidden = true,
        force_resume = true,
        session_scope = current_editor_session_name(),
      }

      persistence.update_session(chosen_agent, chosen_pane_id, vim.fn.getcwd())

      vim.notify(
        "LazyAgentAttach: agent '" .. chosen_agent .. "' attached to pane " .. chosen_pane_id,
        vim.log.levels.INFO
      )

      start_interactive_session({ agent_name = chosen_agent, reuse = true })
    end

    local function pick_pane_then_attach(chosen_agent)
      if pane_id and pane_id ~= "" then
        do_attach(chosen_agent, pane_id)
        return
      end

      local panes = list_panes()
      if not panes or #panes == 0 then
        vim.notify("LazyAgentAttach: no running tmux panes found", vim.log.levels.WARN)
        return
      end

      local items = {}
      for _, p in ipairs(panes) do
        table.insert(items, string.format("%-12s  %-20s  %s", p.id, p.cmd, p.loc))
      end

      vim.ui.select(items, { prompt = "Select tmux pane to attach to agent '" .. chosen_agent .. "':" }, function(sel, idx)
        if not sel or not idx then return end
        do_attach(chosen_agent, panes[idx].id)
      end)
    end

    if agent_name and agent_name ~= "" then
      pick_pane_then_attach(agent_name)
    else
      local agents = agent_logic.available_agents()
      if not agents or #agents == 0 then
        vim.notify("LazyAgentAttach: no interactive agents configured", vim.log.levels.WARN)
        return
      end
      vim.ui.select(agents, { prompt = "Select agent to attach:" }, function(chosen)
        if not chosen then return end
        pick_pane_then_attach(chosen)
      end)
    end
  end

  module.cleanup_agent_external_configs = cleanup_agent_external_configs

  return module
end

return M
