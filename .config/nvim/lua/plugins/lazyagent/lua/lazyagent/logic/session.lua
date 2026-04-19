-- logic/session.lua
-- This module is responsible for managing agent sessions, including
-- starting, stopping, and toggling interactive sessions.
local M = {}

local state = require("lazyagent.logic.state")
local acp_logic = require("lazyagent.logic.acp")
local agent_logic = require("lazyagent.logic.agent")
local backend_logic = require("lazyagent.logic.backend")
local keymaps_logic = require("lazyagent.logic.keymaps")
local send_logic = require("lazyagent.logic.send")
local cache_logic = require("lazyagent.logic.cache")
local window = require("lazyagent.window")
local persistence = require("lazyagent.logic.persistence")
local util = require("lazyagent.util")
local ok_watch, watch = pcall(require, "lazyagent.watch")

local function call_watch(method, ...)
  if not ok_watch or not watch then
    return false
  end
  local fn = watch[method]
  if type(fn) ~= "function" then
    return false
  end
  return pcall(fn, ...)
end

-- Helper: best-effortly send several interrupt signals (Ctrl-C) to a pane
-- before killing it. Some backends (tmux) accept the literal "C-c" token;
-- builtin terminal needs the actual ASCII ETX (0x03). The behaviour and
-- timing can be tuned via state.opts.interrupt_attempts and
-- state.opts.interrupt_interval_ms.
local function send_interrupts_before_kill(agent_name, pane_id, backend_mod, sync)
  local backend_name = nil
  pcall(function()
    backend_name = (select(1, backend_logic.resolve_backend_for_agent(agent_name or "", nil)))
  end)
  local attempts = (state.opts and state.opts.interrupt_attempts) or 3
  local interval_ms = (state.opts and state.opts.interrupt_interval_ms) or 40
  if not pane_id or pane_id == "" then return end
  if not backend_mod or type(backend_mod.send_keys) ~= "function" then return end
  local key = "C-c"
  if backend_name == "builtin" then
    key = string.char(3)
  end
  for i = 1, attempts do
    pcall(backend_mod.send_keys, pane_id, { key })
    -- When non-sync, use vim.wait with event processing so MCP server can still
    -- receive 'done' signals if the CLI reacts to C-c by finishing gracefully.
    pcall(vim.wait, interval_ms, function() return false end, 10, not sync)
  end
end

-- Wait for the pane's foreground process to exit (best-effort).
-- Returns true if the process exited within timeout_ms; false otherwise.
local function wait_for_pane_process_exit(agent_name, pane_id, backend_mod, timeout_ms, sync)
  timeout_ms = timeout_ms or ((state.opts and state.opts.post_interrupt_wait_ms) or 2000)
  local poll_interval = math.max(40, ((state.opts and state.opts.interrupt_interval_ms) or 40))
  local elapsed = 0
  if not pane_id or pane_id == "" then return false end

  local function pane_process_alive()
    -- Try backend-specific pid function first
    if backend_mod and type(backend_mod.get_pane_pid) == "function" then
      local ok, pid = pcall(backend_mod.get_pane_pid, pane_id)
      if ok and pid and tonumber(pid) then
        local ok_stat, stat = pcall(vim.loop.fs_stat, "/proc/" .. tostring(pid))
        if ok_stat and stat then
          return true
        else
          return false
        end
      end
    end
    -- Fallback: if pane no longer exists, treat as process exited
    if backend_mod and type(backend_mod.pane_exists) == "function" then
      local ok2, exists = pcall(backend_mod.pane_exists, pane_id)
      if not ok2 then return true end
      return exists == true
    end
    -- Unknown backend: assume still alive to avoid skipping kill
    return true
  end

  -- If pane already gone, consider process exited
  if backend_mod and type(backend_mod.pane_exists) == "function" then
     local ok0, exists0 = pcall(backend_mod.pane_exists, pane_id)
     if not ok0 or not exists0 then return true end
  end

  while elapsed < timeout_ms do
    local alive = true
    local ok, res = pcall(pane_process_alive)
    if ok then alive = res else alive = true end
    if not alive then return true end
    -- Use vim.wait with event processing (fourth arg true) when NOT in sync-exit mode,
    -- allowing the MCP server to receive 'notify_done' while we are polling.
    pcall(vim.wait, poll_interval, function() return false end, 10, not sync)
    elapsed = elapsed + poll_interval
  end

  return false
end

local function maybe_kill_pane(agent_name, pane_id, backend_mod, use_sync)
  local backend_name = nil
  pcall(function()
    backend_name = (select(1, backend_logic.resolve_backend_for_agent(agent_name or "", nil)))
  end)

  if acp_logic.is_acp_backend(backend_name) then
    pcall(send_interrupts_before_kill, agent_name, pane_id, backend_mod, use_sync)
    pcall(vim.wait, math.max(40, ((state.opts and state.opts.interrupt_interval_ms) or 40)), function() return false end, 10, not use_sync)
    if use_sync and backend_mod and type(backend_mod.kill_pane_sync) == "function" then
      backend_mod.kill_pane_sync(pane_id)
    elseif backend_mod and type(backend_mod.kill_pane) == "function" then
      backend_mod.kill_pane(pane_id)
    end
    return
  end

  -- Send interrupts and wait briefly for the agent process to exit. If it does not
  -- exit within the configured timeout, fallback to killing the pane (sync if
  -- requested and supported by the backend).
  pcall(send_interrupts_before_kill, agent_name, pane_id, backend_mod, use_sync)
  local ok_wait, exited = pcall(wait_for_pane_process_exit, agent_name, pane_id, backend_mod, (state.opts and state.opts.post_interrupt_wait_ms) or 2000, use_sync)
  if not ok_wait or not exited then
    if use_sync and backend_mod and type(backend_mod.kill_pane_sync) == "function" then
      backend_mod.kill_pane_sync(pane_id)
    elseif backend_mod and type(backend_mod.kill_pane) == "function" then
      backend_mod.kill_pane(pane_id)
    end
  end
end

-- Wait for agent to reach "idle" status before proceeding with closing it.
-- @param agent_name (string) Agent name.
-- @param on_ready (function) Callback to invoke when idle or timeout.
local function wait_for_idle_before_close(agent_name, on_ready)
  local s = state.sessions[agent_name]
  if not s then
    on_ready()
    return
  end

  -- If the pane/process has already exited, we don't need to wait for idle status.
  local _, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, nil)
  if backend_mod and type(backend_mod.pane_exists) == "function" then
    local ok, exists = pcall(backend_mod.pane_exists, s.pane_id)
    if ok and not exists then
      on_ready()
      return
    end
  end

  if s.agent_status ~= "thinking" then
    on_ready()
    return
  end

  -- Max 5 seconds for graceful completion before we give up and interrupt it.
  local timeout = 5000
  local timer = vim.loop.new_timer()
  local done = false

  local function finish()
    if done then return end
    done = true
    if timer then
      pcall(function() timer:stop(); timer:close() end)
    end
    s.on_idle_callback = nil
    on_ready()
  end

  s.on_idle_callback = finish
  timer:start(timeout, 0, vim.schedule_wrap(finish))
end

local function serialize_launch_command(command)
  if type(command) == "table" then
    return vim.json.encode(command)
  end
  return tostring(command or "")
end

local function backend_supports_persistence(backend_name)
  return not acp_logic.is_acp_backend(backend_name)
end

local function merge_env(base, extra)
  local merged = vim.tbl_extend("force", {}, base or {})
  for key, value in pairs(extra or {}) do
    merged[key] = value
  end
  return merged
end

local function resolve_source_bufnr(agent_cfg)
  local bufnr = agent_cfg and (agent_cfg.source_bufnr or agent_cfg.origin_bufnr) or nil
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    return bufnr
  end
  return vim.api.nvim_get_current_buf()
end

local function resolve_root_dir(agent_cfg)
  local source_bufnr = resolve_source_bufnr(agent_cfg)
  local source_path = vim.api.nvim_buf_get_name(source_bufnr)
  return util.git_root_for_path(source_path) or vim.fn.getcwd()
end

local function build_acp_split_opts(agent_name, agent_cfg, launch_spec, split_opts)
  local root_dir = resolve_root_dir(agent_cfg)
  local env = merge_env(agent_cfg and agent_cfg.env, split_opts.env)
  local acp = acp_logic.resolve(agent_name, agent_cfg)

  return {
    agent_name = agent_name,
    agent_cfg = agent_cfg,
    command = launch_spec.command,
    source_bufnr = resolve_source_bufnr(agent_cfg),
    source_winid = agent_cfg and (agent_cfg.source_winid or agent_cfg.origin_winid) or nil,
    cwd = root_dir,
    root_dir = root_dir,
    env = env,
    auto_permission = acp.auto_permission,
    default_mode = acp.default_mode,
    initial_model = acp.initial_model,
    buffer_background = acp.buffer_background,
    buffer_inactive_background = acp.buffer_inactive_background,
    transcript_max_lines = acp.transcript_max_lines,
    permission_rules = acp.permission_rules,
    auto_switch = acp.auto_switch,
  }
end

local function maybe_disable_watchers()
  local cnt = 0
  for _, s in pairs(state.sessions or {}) do
    if s and s.pane_id and s.pane_id ~= "" then
      -- Default to 'watch enabled' for backward compatibility when flag is nil.
      local should_watch = s.watch_enabled
      if should_watch == nil then should_watch = true end
      if should_watch then
        cnt = cnt + 1
      end
    end
  end
  if cnt == 0 then
    call_watch("disable")
    call_watch("stop_follow")
  end
end

M.wait_for_idle_before_close = wait_for_idle_before_close

local function current_editor_session_name()
  local value = state.current_session_name
  if type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

local function session_view(session_name)
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

local function session_agents_for_name(session_name)
  local names = {}
  local view = session_view(session_name)
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

local function resolve_saved_snapshot(agent_name, snapshot)
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

local function mark_session_scope(agent_name, session_name)
  local session = agent_name and state.sessions and state.sessions[agent_name] or nil
  if not session then
    return
  end
  session.session_scope = session_name or current_editor_session_name()
end

local function is_acp_agent(name)
  if not name or name == "" then
    return false
  end

  local agent_cfg = agent_logic.get_interactive_agent(name)
  if not agent_cfg then
    return false
  end

  local backend_name = select(1, backend_logic.resolve_backend_for_agent(name, agent_cfg))
  return acp_logic.is_acp_backend(backend_name)
end

local function current_context_acp_agent()
  local bufnr = vim.api.nvim_get_current_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local candidates = {
    vim.b[bufnr] and vim.b[bufnr].lazyagent_acp_agent or nil,
    vim.b[bufnr] and vim.b[bufnr].lazyagent_agent or nil,
  }

  for _, candidate in ipairs(candidates) do
    if is_acp_agent(candidate) then
      return candidate
    end
  end

  return nil
end

local function active_acp_agents()
  local active = {}
  for _, name in ipairs(agent_logic.get_active_agents()) do
    local session = state.sessions[name]
    if session and session.pane_id and session.pane_id ~= "" and is_acp_agent(name) then
      active[#active + 1] = name
    end
  end
  return active
end

local function preferred_session_agent(session_key)
  local view = session_view(session_key)
  if view and view.last_agent and is_acp_agent(view.last_agent) then
    local snapshot = view.agents and view.agents[view.last_agent] or nil
    if type(snapshot) == "table" and snapshot.pane_id and snapshot.pane_id ~= "" then
      return view.last_agent
    end
  end

  local names = session_agents_for_name(session_key)
  if #names == 1 and is_acp_agent(names[1]) then
    return names[1]
  end

  return nil
end

local function resolve_acp_target_agent(agent_name, callback)
  if agent_name and agent_name ~= "" then
    callback(agent_name)
    return
  end

  local current = current_context_acp_agent()
  if current then
    callback(current)
    return
  end

  local scoped = preferred_session_agent(current_editor_session_name())
  if scoped then
    callback(scoped)
    return
  end

  local active = active_acp_agents()
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

local function with_acp_session(agent_name, callback)
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

    M.ensure_session(chosen, agent_cfg, true, function(pane_id)
      if not pane_id or pane_id == "" then
        vim.notify("LazyAgentACP: failed to obtain a session for '" .. tostring(chosen) .. "'", vim.log.levels.ERROR)
        return
      end
      callback(chosen, pane_id, backend_mod, agent_cfg)
    end)
  end)
end

local function resolve_active_acp_session(agent_name, callback)
  callback = callback or function() end

  local function is_active_acp(name)
    local session = state.sessions[name]
    return session and session.pane_id and session.pane_id ~= "" and is_acp_agent(name) or false
  end

  if agent_name and agent_name ~= "" then
    if not is_active_acp(agent_name) then
      vim.notify("LazyAgentConversation: no active ACP session found for '" .. tostring(agent_name) .. "'", vim.log.levels.WARN)
      return
    end
    callback(agent_name)
    return
  end

  local current = current_context_acp_agent()
  if current and is_active_acp(current) then
    callback(current)
    return
  end

  local scoped = preferred_session_agent(current_editor_session_name())
  if scoped and is_active_acp(scoped) then
    callback(scoped)
    return
  end

  local active = {}
  for _, name in ipairs(active_acp_agents()) do
    if is_active_acp(name) then
      table.insert(active, name)
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

local function lines_start_with(lines, prefix)
  lines = lines or {}
  prefix = prefix or {}
  if #prefix > #lines then
    return false
  end
  for idx = 1, #prefix do
    if lines[idx] ~= prefix[idx] then
      return false
    end
  end
  return true
end

local function merge_conversation_lines(previous, current)
  previous = previous or {}
  current = current or {}

  if #previous == 0 then
    return vim.deepcopy(current)
  end
  if #current == 0 then
    return vim.deepcopy(previous)
  end
  if lines_start_with(current, previous) then
    return vim.deepcopy(current)
  end
  if lines_start_with(previous, current) then
    return vim.deepcopy(previous)
  end

  local overlap = math.min(#previous, #current)
  while overlap > 0 do
    local matched = true
    for idx = 1, overlap do
      if previous[#previous - overlap + idx] ~= current[idx] then
        matched = false
        break
      end
    end
    if matched then
      break
    end
    overlap = overlap - 1
  end

  local merged = vim.deepcopy(previous)
  for idx = overlap + 1, #current do
    merged[#merged + 1] = current[idx]
  end
  return merged
end

local function persist_conversation_capture(agent_name, session, lines, opts)
  opts = opts or {}

  local dir = cache_logic.get_conversation_dir()
  local prefix = cache_logic.build_cache_prefix()
  local sanitized = tostring(agent_name):gsub("[^%w-_]+", "-")
  local path = session.last_save_path
  local saved_lines = lines
  local reuse_path = false

  if path and session.last_save_content then
    if lines_start_with(lines, session.last_save_content) then
      reuse_path = true
    elseif opts.merge_with_last_save then
      reuse_path = true
      saved_lines = merge_conversation_lines(session.last_save_content, lines)
    end
  end

  if not reuse_path or not path then
    local filename = prefix .. sanitized .. "-conversation-" .. os.date("%Y-%m-%d-%H%M%S") .. ".log"
    path = dir .. "/" .. filename
  end

  pcall(vim.fn.writefile, saved_lines, path)
  session.last_save_path = path
  session.last_save_content = saved_lines
  return path, saved_lines
end

function M.reopen_acp_window(agent_name)
  resolve_acp_target_agent(agent_name, function(chosen)
    if not chosen or chosen == "" then
      return
    end
    M.start_interactive_session({
      agent_name = chosen,
      reuse = true,
      stay_hidden = false,
    })
  end)
end

local function hide_session_agent_pane(agent_name)
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

local function show_session_agent_pane(agent_name)
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

local function event_session_name(opts)
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

local function capture_runtime_session(session_name, opts)
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
      local preserved = vim.deepcopy(snapshot)
      if type(live_snapshot) == "table" then
        preserved = vim.tbl_extend("force", preserved, live_snapshot)
      end
      preserved.session_scope = session_name
      view.agents[agent_name] = preserved
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
    local snapshot = vim.deepcopy(session)
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
      hide_session_agent_pane(agent_name)
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

local function restore_captured_session(session_name)
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
        show_session_agent_pane(agent_name)
      end
    else
      view.agents[agent_name] = nil
      view.visible_agents[agent_name] = nil
    end
  end
end

function M.on_session_save_pre(opts)
  local session_name = event_session_name(opts)
  if not session_name then
    return
  end

  state.current_session_name = session_name
  capture_runtime_session(session_name, { hide_visible = false, detach_runtime = false })
end

function M.resession_snapshot()
  local session_name = current_editor_session_name()
  if not session_name then
    return nil
  end
  local view = capture_runtime_session(session_name, { hide_visible = false, detach_runtime = false })
  if not view then
    return nil
  end
  local snapshot = vim.deepcopy(view)
  snapshot.session_name = session_name
  return snapshot
end

function M.resession_pre_load(_data)
  local current = current_editor_session_name()
  if not current then
    return
  end

  capture_runtime_session(current, { hide_visible = true, detach_runtime = true })
end

function M.resession_post_load(data)
  if type(data) ~= "table" then
    return
  end
  local session_name = data.session_name
  if not session_name then
    return
  end

  state.current_session_name = session_name
  state.session_views[session_name] = vim.deepcopy(data)
  restore_captured_session(session_name)
  if data.open_agent and state.sessions[data.open_agent] and state.sessions[data.open_agent].pane_id then
    vim.schedule(function()
      if not (state.sessions[data.open_agent] and state.sessions[data.open_agent].pane_id) then
        return
      end
      M.start_interactive_session({
        agent_name = data.open_agent,
        reuse = true,
        stay_hidden = false,
      })
    end)
  end
end

function M.on_session_load_pre(opts)
  M.resession_pre_load(opts)
end

function M.on_session_load_post(opts)
  local session_name = event_session_name(opts)
  if not session_name then
    return
  end
  state.current_session_name = session_name
end

---
-- Ensures a backend session (e.g., a tmux pane) exists for the agent.
-- @param agent_name (string) The name of the agent.
-- @param agent_cfg (table) The agent's configuration.
-- @param reuse (boolean) Whether to reuse an existing session if available.
-- @param on_ready (function) Callback to execute with the pane_id when ready.
function M.ensure_session(agent_name, agent_cfg, reuse, on_ready)
  local launch_spec, launch_err = agent_logic.resolve_launch_spec(agent_name, agent_cfg)
  local existing_session = state.sessions[agent_name]
  if not launch_spec and not (existing_session and existing_session.pane_id) then
    vim.notify("LazyAgent: " .. tostring(launch_err or "launch command is not configured"), vim.log.levels.ERROR)
    return
  end

  local backend_name, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, agent_cfg)
  local requested_launch_cmd = launch_spec and launch_spec.command or nil
  local requested_launch_key = serialize_launch_command(requested_launch_cmd)

  -- Check for persisted session.
  -- Even if resume is disabled globally, if a persisted session exists (e.g. explicitly Detached),
  -- we should try to restore it.
  if backend_supports_persistence(backend_name)
    and not (state.sessions[agent_name] and state.sessions[agent_name].pane_id)
  then
    local persisted_pane = persistence.get_session(agent_name)
    if persisted_pane and persisted_pane ~= "" then
      -- Verify if pane still exists
      if backend_mod and type(backend_mod.pane_exists) == "function" and backend_mod.pane_exists(persisted_pane) then
        -- Restore session state
        local watch_enabled_val = true
        if agent_cfg and agent_cfg.watch ~= nil then watch_enabled_val = agent_cfg.watch end
        state.sessions[agent_name] = {
          pane_id = persisted_pane,
          last_output = "",
          backend = backend_name,
          watch_enabled = watch_enabled_val,
          launch_cmd = requested_launch_key,
          hidden = true, -- Assume hidden/detached if we are restoring it
          cwd = vim.fn.getcwd(),
          session_scope = current_editor_session_name(),
        }
        -- If this session requested watchers, enable them.
        if watch_enabled_val then
          call_watch("enable")
        end
        -- If auto_follow is configured, start following file changes in cwd.
        local follow_mode = (agent_cfg and agent_cfg.auto_follow) or (state.opts and state.opts.auto_follow)
        if follow_mode then
          call_watch("start_follow", {
            mode = (type(follow_mode) == "string") and follow_mode or "split",
            dir = vim.fn.getcwd(),
          })
        end
        -- Configure pane options (e.g. refocus_on_send) for the restored pane.
        if backend_mod and type(backend_mod.configure_pane) == "function" then
          local refocus = (agent_cfg and agent_cfg.refocus_on_send) or (state.opts and state.opts.refocus_on_send) or false
          backend_mod.configure_pane(persisted_pane, { refocus_on_send = refocus })
        end
        -- If it was hidden, we need to join it? ensure_session logic below handles reuse/hidden.
        -- Just setting state.sessions[agent_name] is enough to trigger the reuse logic block below.
      else
        -- Invalid persisted session, clean it up
        persistence.remove_session(agent_name)
      end
    end
  end

  if reuse and state.sessions[agent_name] and state.sessions[agent_name].pane_id and state.sessions[agent_name].pane_id ~= "" then
    if acp_logic.is_acp_backend(backend_name)
      and backend_name == "buffer_acp"
      and not state.sessions[agent_name].hidden
      and backend_mod
      and type(backend_mod.get_pane_info) == "function"
    then
      local pane_info = backend_mod.get_pane_info(state.sessions[agent_name].pane_id)
      if not pane_info then
        state.sessions[agent_name].hidden = true
      end
    end

    -- If stay_hidden is requested (Instant Mode) and session is NOT hidden, hide it.
    if agent_cfg.stay_hidden and not state.sessions[agent_name].hidden then
       if backend_mod and type(backend_mod.break_pane) == "function" then
          backend_mod.break_pane(state.sessions[agent_name].pane_id)
          state.sessions[agent_name].hidden = true
       end
    end

    -- If the session was hidden, restore it (join-pane)
    if state.sessions[agent_name].hidden then
      -- If stay_hidden is explicitly true, or if it's nil (default) and we are in instant mode, keep it hidden.
      -- If stay_hidden is explicitly false (e.g. toggle/open), we proceed to join (show) it.
      local should_keep_hidden = agent_cfg.stay_hidden
      if should_keep_hidden == nil and state.sessions[agent_name].mode == "instant" then
         should_keep_hidden = true
      end

      if should_keep_hidden then
         on_ready(state.sessions[agent_name].pane_id)
         return
      end

      if backend_mod and type(backend_mod.join_pane) == "function" then
        if backend_mod and type(backend_mod.configure_pane) == "function" then
          local refocus = (agent_cfg and agent_cfg.refocus_on_send) or (state.opts and state.opts.refocus_on_send) or false
          backend_mod.configure_pane(state.sessions[agent_name].pane_id, {
            refocus_on_send = refocus,
            source_winid = agent_cfg and (agent_cfg.source_winid or agent_cfg.origin_winid) or nil,
          })
        end
        local size_arg = agent_cfg.pane_size or 30
        -- Ignore last_size for now to enforce consistent sizing with initial launch
        -- if state.sessions[agent_name].last_size then
        --   if agent_cfg.is_vertical then
        --     if state.sessions[agent_name].last_size.width then
        --       size_arg = tostring(state.sessions[agent_name].last_size.width)
        --     end
        --   else
        --     if state.sessions[agent_name].last_size.height then
        --       size_arg = tostring(state.sessions[agent_name].last_size.height)
        --     end
        --   end
        -- end

        backend_mod.join_pane(state.sessions[agent_name].pane_id, size_arg, agent_cfg.is_vertical or false, function(success)
          if success then
            state.sessions[agent_name].hidden = false
            state.sessions[agent_name].mode = nil
            -- Wait a bit for tmux to resize and vim to update its dimensions before opening the window
            vim.defer_fn(function()
               on_ready(state.sessions[agent_name].pane_id)
            end, 50)
          else
             -- If join failed, we might be in a bad state.
             -- But we shouldn't set hidden=false, so next time we try again.
             -- We should probably still call on_ready? No, if join failed, the pane is not visible.
             -- But if we don't call on_ready, the user gets stuck.
             -- Let's try to call on_ready anyway, maybe the user can see the error and retry.
             -- But if hidden is true, ensure_session logic might loop?
             -- No, ensure_session is called once.
             -- If we return here, the agent window opens but is empty (no pane attached).
             vim.notify("LazyAgent: failed to restore session pane", vim.log.levels.ERROR)
             on_ready(state.sessions[agent_name].pane_id)
          end
        end)
        return
      end
    end

    -- If the caller provided a watch preference, update the existing session's watch flag.
    if agent_cfg and agent_cfg.watch ~= nil then
      state.sessions[agent_name].watch_enabled = agent_cfg.watch
    end

    mark_session_scope(agent_name)

    -- Ensure watchers are enabled if this session wants them.
    if state.sessions[agent_name].watch_enabled then
      call_watch("enable")
    end

    -- If this session no longer wants watching, check whether to disable watchers globally.
    if not state.sessions[agent_name].watch_enabled then
      maybe_disable_watchers()
    end

    -- If an existing session was launched with a different command, don't reuse it.
    if state.sessions[agent_name].launch_cmd and requested_launch_key and state.sessions[agent_name].launch_cmd ~= requested_launch_key then
      -- Intentionally don't reuse; fall through to create a new session
    else
        if backend_mod and type(backend_mod.pane_exists) == "function" then
          if backend_mod.pane_exists(state.sessions[agent_name].pane_id) then
            if backend_mod and type(backend_mod.configure_pane) == "function" then
              local refocus = (agent_cfg and agent_cfg.refocus_on_send) or (state.opts and state.opts.refocus_on_send) or false
              backend_mod.configure_pane(state.sessions[agent_name].pane_id, {
                refocus_on_send = refocus,
                source_winid = agent_cfg and (agent_cfg.source_winid or agent_cfg.origin_winid) or nil,
              })
            end
            on_ready(state.sessions[agent_name].pane_id)
            return
          end
      else
        on_ready(state.sessions[agent_name].pane_id)
        return
      end
    end
  end

  local split_opts
  split_opts = {
    on_split = function(pane_id)
      if not pane_id or pane_id == "" then
        vim.notify("Failed to create pane for agent " .. tostring(agent_name), vim.log.levels.ERROR)
        return
      end

      -- Determine this session's watch preference (default true)
      local watch_enabled_val = true
      if agent_cfg and agent_cfg.watch ~= nil then watch_enabled_val = agent_cfg.watch end

      -- Determine initial mode (e.g. "instant" if stay_hidden is requested)
      local mode = nil
      if agent_cfg and agent_cfg.stay_hidden then mode = "instant" end
      if agent_cfg and agent_cfg.mode then mode = agent_cfg.mode end
      local resolved_acp = acp_logic.resolve(agent_name, agent_cfg)

      state.sessions[agent_name] = {
        pane_id = pane_id,
        last_output = "",
        backend = backend_name,
        watch_enabled = watch_enabled_val,
        launch_cmd = requested_launch_key,
        cwd = resolve_root_dir(agent_cfg),
        session_scope = current_editor_session_name(),
        buffer_background = resolved_acp.buffer_background,
        buffer_inactive_background = resolved_acp.buffer_inactive_background,
        transcript_max_lines = resolved_acp.transcript_max_lines,
        hidden = (agent_cfg.stay_hidden == true),
        mode = mode
      }
      -- If this session requested watchers, enable them.
      if watch_enabled_val then
        call_watch("enable")
      end

      -- If auto_follow is configured, start following file changes in cwd.
      local follow_mode = (agent_cfg and agent_cfg.auto_follow) or (state.opts and state.opts.auto_follow)
      if follow_mode then
        call_watch("start_follow", {
          mode = (type(follow_mode) == "string") and follow_mode or "split",
          dir = vim.fn.getcwd(),
        })
      end

      -- Configure pane options (e.g. refocus_on_send) so send_keys/paste_and_submit behave correctly.
      if backend_mod and type(backend_mod.configure_pane) == "function" then
        local refocus = (agent_cfg and agent_cfg.refocus_on_send) or (state.opts and state.opts.refocus_on_send) or false
        backend_mod.configure_pane(pane_id, {
          refocus_on_send = refocus,
          source_winid = agent_cfg and (agent_cfg.source_winid or agent_cfg.origin_winid) or nil,
        })
      end

      -- Persist session if resume is enabled
      local resume_enabled = (agent_cfg and agent_cfg.resume) or (state.opts and state.opts.resume)
      if resume_enabled and backend_supports_persistence(backend_name) then
        persistence.update_session(agent_name, pane_id, state.sessions[agent_name].cwd)
      end

      -- If stay_hidden is requested (Instant Mode), and we didn't use target_session (fallback),
      -- ensure it's moved to pool.
      if agent_cfg.stay_hidden and not split_opts.target_session then
         if backend_mod and type(backend_mod.break_pane) == "function" then
            backend_mod.break_pane(pane_id)
            state.sessions[agent_name].hidden = true
         end
      end

      -- Send initial_send text after agent startup if configured.
      -- Uses agent_cfg.initial_send if set; falls back to opts.mcp_initial_send when mcp_mode is on.
      -- Only fires on new sessions (not reused ones), with a startup delay to let the CLI initialize.
      local init_send = agent_cfg and agent_cfg.initial_send
      if not acp_logic.is_acp_backend(backend_name) then
        init_send = init_send or (state.opts and state.opts.mcp_mode and state.opts.mcp_initial_send)
      end
      if init_send and init_send ~= "" then
        local delay_ms = (agent_cfg and agent_cfg.initial_send_delay) or (state.opts and state.opts.initial_send_delay) or 3000
        vim.defer_fn(function()
          local s = state.sessions[agent_name]
          if not s or not s.pane_id then return end
          local _, bmod = backend_logic.resolve_backend_for_agent(agent_name, agent_cfg)
          if bmod and type(bmod.paste_and_submit) == "function" then
            bmod.paste_and_submit(s.pane_id, init_send, agent_cfg.submit_keys, {})
          end
        end, delay_ms)
      end

      -- Wait a bit for tmux to resize and vim to update its dimensions before opening the window
      vim.defer_fn(function()
        on_ready(pane_id)
      end, 200)
    end
  }

  if agent_cfg.stay_hidden then
     split_opts.target_session = "lazyagent-pool"
  end

  local function do_split()
    split_opts.env = split_opts.env or {}

    if acp_logic.is_acp_backend(backend_name) then
      split_opts.acp = build_acp_split_opts(agent_name, agent_cfg, launch_spec, split_opts)
      backend_mod.split(nil, agent_cfg.pane_size or 30, agent_cfg.is_vertical or false, split_opts)
      return
    end

    -- Inject MCP URL into agent environment
    if state.opts and state.opts.mcp_mode and state.opts._mcp_url then
      split_opts.env.LAZYAGENT_MCP_URL = state.opts._mcp_url
    end

    local launch_cmd = requested_launch_cmd
    if state.opts and state.opts.mcp_mode then
      local cache_dir = (state.opts.cache and state.opts.cache.dir) or (vim.fn.stdpath("cache") .. "/lazyagent")
      local agent_cache_dir = cache_dir .. "/agents/" .. string.lower(agent_name or "")
      pcall(vim.fn.mkdir, agent_cache_dir, "p")

      local is_gemini = (agent_name == "Gemini")
        or (agent_cfg and agent_cfg.cmd and tostring(agent_cfg.cmd):lower():match("gemini"))

      -- Gemini: write system-defaults.json (MCP config) and system.md (instructions) via env vars
      if is_gemini then
        if state.opts._mcp_type == "http" and state.opts._mcp_url then
          local write_url = state.opts._mcp_url
          local gem_entry = { mcpServers = { lazyagent = { url = write_url, httpUrl = write_url, type = "http" } } }
          local sys_path = agent_cache_dir .. "/system-defaults.json"
          local function try_read(p)
            local fh = io.open(p, "r")
            if not fh then return nil end
            local ok, parsed = pcall(vim.fn.json_decode, fh:read("*a"))
            fh:close()
            if ok and type(parsed) == "table" then return parsed end
            return nil
          end
          local g_system = try_read("/etc/gemini-cli/system-defaults.json")
          local sys_data
          if g_system then
            sys_data = {}
            local user_default = try_read(vim.fn.expand("~/.gemini/settings.json"))
            for k,v in pairs(g_system) do sys_data[k]=v end
            if user_default then for k,v in pairs(user_default) do sys_data[k]=v end end
            sys_data.mcpServers = sys_data.mcpServers or {}
            for k,v in pairs(gem_entry.mcpServers) do sys_data.mcpServers[k]=v end
            if sys_data.general and type(sys_data.general) == "table" then
              sys_data.general.disableAutoUpdate = nil
              sys_data.general.disableUpdateNag = nil
            end
          else
            sys_data = { mcpServers = gem_entry.mcpServers }
          end
          -- Add lazyagent hooks (scripts generated by write_mcp_configs)
          local hooks_dir = agent_cache_dir .. "/hooks"
          sys_data.hooks = {
            BeforeAgent = {{
              matcher = "",
              hooks = {{ name = "notify-start", type = "command", command = hooks_dir .. "/notify-start.sh", timeout = 10000 }},
            }},
            AfterAgent = {{
              matcher = "",
              hooks = {{ name = "notify-done", type = "command", command = hooks_dir .. "/notify-done.sh", timeout = 10000 }},
            }},
            AfterTool = {{
              matcher = "write_file|replace",
              hooks = {{ name = "open-file", type = "command", command = hooks_dir .. "/open-file.sh", timeout = 10000 }},
            }},
          }

          local fw = io.open(sys_path, "w")
          if fw then fw:write(vim.fn.json_encode(sys_data)); fw:close() end
          split_opts.env.GEMINI_CLI_SYSTEM_DEFAULTS_PATH = sys_path
        end

        do
          local function read_text(p)
            local fh = io.open(p, "r")
            if not fh then return nil end
            local s = fh:read("*a")
            fh:close()
            return s
          end
          -- Prefer user-placed AGENTS.md in agent cache dir, fallback to packaged default
          local agent_md = read_text(agent_cache_dir .. "/AGENTS.md") or ""
          local existing_sys = read_text(agent_cache_dir .. "/system.md") or ""
          local sys_content
          if agent_md ~= "" then
            sys_content = agent_md
          else
            sys_content = (existing_sys ~= "" and existing_sys) or (read_text(cache_dir .. "/default_instructions.md") or "")
          end
          local system_md_path = agent_cache_dir .. "/system.md"
          local sf = io.open(system_md_path, "w")
          if sf then sf:write(sys_content); sf:close() end
          vim.notify(string.format("[lazyagent] wrote system.md -> %s (%d bytes)", system_md_path, #sys_content), vim.log.levels.DEBUG)
          split_opts.env.GEMINI_SYSTEM_MD = system_md_path
        end
      end

      -- Copilot: point to agent cache dir for mcp-config.json and AGENTS.md
      if agent_name == "Copilot" or (agent_cfg and agent_cfg.cmd and tostring(agent_cfg.cmd):match("copilot")) then
        split_opts.env.COPILOT_CONFIG_DIR = agent_cache_dir
        split_opts.env.COPILOT_CUSTOM_INSTRUCTIONS_DIRS = agent_cache_dir
        launch_cmd = (launch_cmd or "") .. " --additional-mcp-config " .. vim.fn.shellescape("@" .. agent_cache_dir .. "/mcp-config.json")
        launch_cmd = launch_cmd .. " --plugin-dir " .. vim.fn.shellescape(agent_cache_dir)
      end
    end
    backend_mod.split(launch_cmd, agent_cfg.pane_size or 30, agent_cfg.is_vertical or false, split_opts)
  end

  -- If mcp_mode is enabled but the server is not ready yet, wait for it before launching the agent
  if not acp_logic.is_acp_backend(backend_name) and state.opts and state.opts.mcp_mode and not state.opts._mcp_url then
    local max_attempts = 50 -- up to 5 seconds (50 * 100ms)
    local attempts = 0
    local function wait_for_mcp()
      attempts = attempts + 1
      if state.opts._mcp_url then
        do_split()
      elseif attempts < max_attempts then
        vim.defer_fn(wait_for_mcp, 100)
      else
        vim.notify("[lazyagent] MCP server did not become ready in time; launching agent without MCP URL", vim.log.levels.WARN)
        do_split()
      end
    end
    wait_for_mcp()
  else
    do_split()
  end
end

--- Captures and saves the conversation text for the given agent's session.
-- @param agent_name (string) The name of the agent.
-- @param open_file (boolean) If true, open the saved file in a buffer after saving.
-- @param on_done (function|nil) Optional callback invoked after capture is saved (receives path).
function M.capture_and_save_session(agent_name, open_file, on_done, opts)
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

---
-- Restarts a specific agent's session.
-- @param agent_name (string) The name of the agent.
function M.restart_session(agent_name)
  local function _restart(chosen)
    if not chosen or chosen == "" then return end

    -- Close existing session
    M.close_session(chosen)

    -- Start new session (reuse=false to force new pane)
    -- We use a small delay to ensure cleanup is processed
    vim.defer_fn(function()
      M.start_interactive_session({ agent_name = chosen, reuse = false })
    end, 100)
  end

  if agent_name and agent_name ~= "" then
    _restart(agent_name)
  else
    agent_logic.resolve_target_agent(nil, nil, _restart)
  end
end

-- Removes lazyagent entries from agent-managed external config files (e.g. Cursor's mcp.json/hooks.json).
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

---
-- Closes a specific agent's session.
-- @param agent_name (string) The name of the agent.
function M.close_session(agent_name)
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
    maybe_disable_watchers()
    return
  end

  -- Wait for the agent to finish its current turn before killing it.
  -- This ensures any pending file edits or tool calls finish, and the final capture is complete.
  wait_for_idle_before_close(agent_name, function()
    -- Re-fetch session state as it might have changed during wait
    local s2 = state.sessions[agent_name]
    if not s2 or not s2.pane_id or s2.pane_id == "" then return end

    local agent_cfg = agent_logic.get_interactive_agent(agent_name)
    local save_conv = (agent_cfg and agent_cfg.save_conversation_on_close) or (state.opts and state.opts.save_conversation_on_close)
    local open_conv = (agent_cfg and agent_cfg.open_conversation_on_save) or (state.opts and state.opts.open_conversation_on_save)

    local _, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, nil)

    if save_conv and backend_mod and type(backend_mod.capture_pane) == "function" then
      M.capture_and_save_session(agent_name, open_conv, function()
        local _, backend_mod2 = backend_logic.resolve_backend_for_agent(agent_name, nil)
        if backend_mod2 and type(backend_mod2.kill_pane) == "function" then
          maybe_kill_pane(agent_name, s2.pane_id, backend_mod2, false)
        end
        state.sessions[agent_name] = nil
        maybe_disable_watchers()
        cleanup_agent_external_configs(agent_name)
      end, {
        merge_with_last_save = s2.merge_conversation_on_next_save,
      })
      return
    end

    if backend_mod and type(backend_mod.kill_pane) == "function" then
      maybe_kill_pane(agent_name, s2.pane_id, backend_mod, false)
    end
    if backend_mod and type(backend_mod.clear_pane_config) == "function" then
      backend_mod.clear_pane_config(s2.pane_id)
    end
    state.sessions[agent_name] = nil
    persistence.remove_session(agent_name, s2.cwd)
    maybe_disable_watchers()

    -- Cursor: remove lazyagent from ~/.cursor/mcp.json and ~/.cursor/hooks.json on session close
    cleanup_agent_external_configs(agent_name)

    if backend_mod and type(backend_mod.cleanup_if_idle) == "function" then
      pcall(backend_mod.cleanup_if_idle)
    end
  end)
end

---
-- Closes all active agent sessions.
function M.close_all_sessions(sync)
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
          -- If resume is enabled, do NOT kill the pane.
          -- Instead, ensure it is detached/hidden (break_pane) so it doesn't clutter the current window.
          -- Since we are exiting, we might not need to break_pane if the parent tmux window is closing anyway,
          -- but if we are in a shared tmux session, we should probably move it to the pool.
          if not s.hidden then
             if backend_mod and type(backend_mod.break_pane_sync) == "function" then
                backend_mod.break_pane_sync(s.pane_id)
             elseif backend_mod and type(backend_mod.break_pane) == "function" then
                -- Fallback to async if sync not available (might fail on exit)
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
          M.capture_and_save_session(name, open_conv, function()
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

   for backend_mod, _ in pairs(seen_backends) do
     if backend_mod and type(backend_mod.cleanup_if_idle) == "function" then
       pcall(backend_mod.cleanup_if_idle)
     end
   end
end

---
-- Toggles the floating input window for an agent.
-- If the window is open, it closes it. Otherwise, it starts a new interactive session.
-- @param agent_name (string|nil) The name of the agent.
function M.toggle_session(agent_name)
  local function _toggle(chosen)
    if not chosen or chosen == "" then return end
    local agent_cfg = agent_logic.get_interactive_agent(chosen)
    local backend_name = select(1, backend_logic.resolve_backend_for_agent(chosen, agent_cfg))
    local preserve_scratch = acp_logic.is_acp_backend(backend_name)

    local initial_input = nil
    local current_mode = vim.fn.mode()
    if current_mode:match("[vV\x16]") then
      -- Use current Visual start mark ('v') and cursor to avoid stale '<'/'>' marks.
      local start_pos = vim.fn.getpos("v") -- {bufnum, lnum, col, off}
      local cursor = vim.api.nvim_win_get_cursor(0) -- {lnum, col}
      local start_line = start_pos and start_pos[2] or nil
      local end_line = cursor and cursor[1] or nil

      local file_path = vim.api.nvim_buf_get_name(0)
      if file_path and file_path ~= "" then
        file_path = vim.fn.fnamemodify(file_path, ":.")
      end

      -- Build location header even if selection text is empty; user only wants path+range.
      if file_path and file_path ~= "" and start_line > 0 and end_line > 0 then
        if start_line == end_line then
          initial_input = string.format("@%s:%d", file_path, start_line)
        else
          initial_input = string.format("@%s:%d-%d", file_path, start_line, end_line)
        end
      end

    end

    -- If the floating input is already open for this agent, close it.
    if state.open_agent == chosen and window.is_open() then
      local bufnr = window.get_bufnr()
      window.close({ keep_buffer = preserve_scratch })
      if not preserve_scratch and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
      state.open_agent = nil

      -- Hide the tmux pane (break-pane)
      if state.sessions[chosen] and state.sessions[chosen].pane_id then
        local _, backend_mod = backend_logic.resolve_backend_for_agent(chosen, nil)
        if backend_mod and type(backend_mod.break_pane) == "function" then
          -- Try to save size before breaking
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

      -- if there is no input to show, just close and exit
      if not initial_input then
        return
      end
    end

    -- Otherwise, start an interactive session (reuse = true by default).
    M.start_interactive_session({ agent_name = chosen, reuse = true, initial_input = initial_input, stay_hidden = false })
  end

  agent_logic.resolve_target_agent(agent_name, nil, _toggle)
end

---
-- Opens an "Instant" window for the agent.
-- The agent runs in the background (hidden/pool), and the window is used for quick interactions.
-- @param agent_name (string|nil) The name of the agent.
function M.open_instant(agent_name)
  local function _open(chosen)
    if not chosen or chosen == "" then return end

    -- If the floating input is already open for this agent, focus it.
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

    -- Start session with stay_hidden=true
    M.start_interactive_session({
      agent_name = chosen,
      reuse = true,
      stay_hidden = true,
      mode = "instant",
      title = " " .. chosen .. " (Instant) ",
      -- Minimal window for instant mode
      window_opts = {
         height = 3,
         width_ratio = 0.4,
      }
    })

    -- Mark session as instant mode
    if state.sessions[chosen] then
       state.sessions[chosen].mode = "instant"
    end
  end

  agent_logic.resolve_target_agent(agent_name, nil, _open)
end

---
-- Resume a conversation from a saved conversation log by loading it into a new scratch buffer.
-- Prompts the user to select a snapshot file and an agent (if not provided), then opens a session
-- with the snapshot content preloaded.
-- @param agent_name (string|nil) The name of the agent to use.
function M.resume_conversation(agent_name)
  local entries = cache_logic.list_conversation_files()
  if not entries or #entries == 0 then
    vim.notify("LazyAgentResume: no conversation snapshots found in " .. cache_logic.get_conversation_dir(), vim.log.levels.INFO)
    return
  end

  local dir = cache_logic.get_conversation_dir()

  local function start_with_path(path)
    if vim.fn.filereadable(path) == 0 then
      vim.notify("LazyAgentResume: file not found: " .. path, vim.log.levels.ERROR)
      return
    end

    local rel_path = vim.fn.fnamemodify(path, ":.")
    if not rel_path or rel_path == "" then rel_path = path end
    local content = "@" .. rel_path

    local function start_for_agent(chosen_agent)
      if not chosen_agent or chosen_agent == "" then return end
      M.start_interactive_session({ agent_name = chosen_agent, reuse = true, initial_input = content })
    end

    if agent_name and agent_name ~= "" then
      start_for_agent(agent_name)
    else
      agent_logic.resolve_target_agent(nil, nil, start_for_agent)
    end
  end

  -- Build choices from entries; sort so current project+branch prefix comes first.
  local prefix = (cache_logic.build_cache_prefix and cache_logic.build_cache_prefix()) or ""
  local choices = {}
  if prefix ~= "" then
    local matched, rest = {}, {}
    for _, e in ipairs(entries) do
      if e.name:lower():sub(1, #prefix) == prefix:lower() then
        table.insert(matched, e.name)
      else
        table.insert(rest, e.name)
      end
    end
    for _, n in ipairs(matched) do table.insert(choices, n) end
    for _, n in ipairs(rest)    do table.insert(choices, n) end
  else
    for _, e in ipairs(entries) do table.insert(choices, e.name) end
  end

  vim.ui.select(choices, {
    prompt = "Resume LazyAgent conversation:",
    previewer = "builtin",
    cwd = dir,
  }, function(selected, idx)
    local choice = (idx and choices[idx]) or selected
    if not choice or choice == "" then return end
    start_with_path(dir:gsub("/$", "") .. "/" .. choice)
  end)
end

---
-- Detaches an agent session, persisting it for later restoration even if resume is disabled globally.
-- @param agent_name (string|nil) The name of the agent.
function M.detach_session(agent_name)
  local function _detach(chosen)
    if not chosen or chosen == "" then return end

    local s = state.sessions[chosen]
    if not s or not s.pane_id then
      vim.notify("LazyAgentDetach: no active session for '" .. chosen .. "'", vim.log.levels.WARN)
      return
    end

    local _, backend_mod = backend_logic.resolve_backend_for_agent(chosen, nil)
    local persistable = backend_supports_persistence(s.backend)

    if persistable then
      -- Mark for persistence so close_all_sessions won't kill it
      s.force_resume = true
      persistence.update_session(chosen, s.pane_id, s.cwd)
    end

    -- Close the floating window if it's open for this agent
    if state.open_agent == chosen and window.is_open() then
      local bufnr = window.get_bufnr()
      local preserve_scratch = acp_logic.is_acp_backend(s.backend)
      window.close({ keep_buffer = preserve_scratch })
      if not preserve_scratch and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
      state.open_agent = nil
    end

    -- Hide the pane (break_pane)
    if not s.hidden then
      if backend_mod and type(backend_mod.break_pane) == "function" then
        -- Try to save size before breaking
        if type(backend_mod.get_pane_info) == "function" then
          backend_mod.get_pane_info(s.pane_id, function(info)
            if info then
              s.last_size = info
            end
            backend_mod.break_pane(s.pane_id)
            s.hidden = true
            local label = persistable and "detached and persisted" or "detached for this Neovim session"
            vim.notify("Agent '" .. chosen .. "' " .. label .. ".", vim.log.levels.INFO)
          end)
        else
          backend_mod.break_pane(s.pane_id)
          s.hidden = true
          local label = persistable and "detached and persisted" or "detached for this Neovim session"
          vim.notify("Agent '" .. chosen .. "' " .. label .. ".", vim.log.levels.INFO)
        end
      end
    else
      vim.notify("Agent '" .. chosen .. "' is already detached.", vim.log.levels.INFO)
    end
  end

  agent_logic.resolve_target_agent(agent_name, nil, _detach)
end

function M.pick_acp_config(agent_name, category)
  with_acp_session(agent_name, function(_, pane_id, backend_mod)
    if not backend_mod or type(backend_mod.show_config_picker) ~= "function" then
      vim.notify("LazyAgentACP: backend does not expose config pickers", vim.log.levels.WARN)
      return
    end
    backend_mod.show_config_picker(pane_id, category)
  end)
end

function M.pick_acp_model(agent_name)
  M.pick_acp_config(agent_name, "model")
end

function M.pick_acp_mode(agent_name)
  M.pick_acp_config(agent_name, "mode")
end

function M.pick_acp_commands(agent_name)
  with_acp_session(agent_name, function(_, pane_id, backend_mod)
    if not backend_mod or type(backend_mod.show_command_palette) ~= "function" then
      vim.notify("LazyAgentACP: backend does not expose a command palette", vim.log.levels.WARN)
      return
    end
    backend_mod.show_command_palette(pane_id)
  end)
end

function M.show_acp_tool_timeline(agent_name)
  with_acp_session(agent_name, function(_, pane_id, backend_mod)
    if not backend_mod or type(backend_mod.show_tool_timeline) ~= "function" then
      vim.notify("LazyAgentACP: backend does not expose a tool timeline", vim.log.levels.WARN)
      return
    end
    backend_mod.show_tool_timeline(pane_id)
  end)
end

function M.pick_acp_resources(agent_name)
  with_acp_session(agent_name, function(_, pane_id, backend_mod)
    if not backend_mod or type(backend_mod.show_resource_browser) ~= "function" then
      vim.notify("LazyAgentACP: backend does not expose a resource browser", vim.log.levels.WARN)
      return
    end
    backend_mod.show_resource_browser(pane_id)
  end)
end

function M.show_acp_capabilities(agent_name)
  with_acp_session(agent_name, function(_, pane_id, backend_mod)
    if not backend_mod or type(backend_mod.show_capabilities) ~= "function" then
      vim.notify("LazyAgentACP: backend does not expose a capability report", vim.log.levels.WARN)
      return
    end
    backend_mod.show_capabilities(pane_id)
  end)
end

function M.save_conversation_checkpoint(agent_name)
  resolve_active_acp_session(agent_name, function(chosen)
    local session = state.sessions[chosen]
    if not session or not session.pane_id or session.pane_id == "" then
      vim.notify("LazyAgentConversation: no active ACP session found for '" .. tostring(chosen) .. "'", vim.log.levels.WARN)
      return
    end

    local _, backend_mod = backend_logic.resolve_backend_for_agent(chosen, agent_logic.get_interactive_agent(chosen))
    if not backend_mod or type(backend_mod.capture_pane) ~= "function" then
      vim.notify("LazyAgentConversation: backend cannot capture this ACP session", vim.log.levels.WARN)
      return
    end
    if type(backend_mod.clear_transcript) ~= "function" then
      vim.notify("LazyAgentConversation: backend cannot clear this ACP transcript", vim.log.levels.WARN)
      return
    end

    M.capture_and_save_session(chosen, false, function(path)
      if not path or path == "" then
        return
      end

      local current = state.sessions[chosen]
      if not current or not current.pane_id or current.pane_id == "" then
        return
      end

      if not backend_mod.clear_transcript(current.pane_id) then
        vim.notify("LazyAgentConversation: saved conversation but failed to clear ACP transcript", vim.log.levels.ERROR)
        return
      end

      current.merge_conversation_on_next_save = true
      vim.notify("LazyAgentConversation: saved conversation to " .. path .. " and cleared ACP transcript", vim.log.levels.INFO)
    end, {
      merge_with_last_save = session.merge_conversation_on_next_save,
    })
  end)
end

---
-- Starts an interactive session for a given agent.
-- This typically involves opening a tmux pane and a floating scratch buffer.
-- @param opts (table) Options for the session, including:
--   - agent_name (string): The name of the agent.
--   - reuse (boolean): Whether to reuse an existing session.
--   - initial_input (string): Initial text for the scratch buffer.
function M.start_interactive_session(opts)
  opts = opts or {}
  -- The 'watch' option controls whether file-system watchers should be used for this session (default true).
  -- We will enable watchers only after the session is created (so we can inspect agent_cfg/opts).
  local agent_name = opts.agent_name or opts.name
  if not agent_name or agent_name == "" then
    -- If caller didn't provide an explicit agent name, use resolve_target_agent to select one.
    local hint = opts.name or opts.agent_hint or nil
    agent_logic.resolve_target_agent(nil, hint, function(chosen)
      if not chosen or chosen == "" then return end
      opts.agent_name = chosen
      M.start_interactive_session(opts)
    end)
    return
  end

  local base_agent_cfg = agent_logic.get_interactive_agent(agent_name)
  -- Merge per-call options into the base agent config so opts can override settings
  -- like pane_size, is_vertical, and scratch_filetype.
  local agent_cfg = vim.tbl_deep_extend("force", base_agent_cfg or {}, opts or {})
  local origin_bufnr = opts.source_bufnr or opts.origin_bufnr or vim.api.nvim_get_current_buf()
  local origin_winid = opts.source_winid or opts.origin_winid or vim.api.nvim_get_current_win()
  agent_cfg.source_bufnr = origin_bufnr
  agent_cfg.origin_bufnr = origin_bufnr
  agent_cfg.source_winid = origin_winid
  agent_cfg.origin_winid = origin_winid

  local launch_spec, launch_err = agent_logic.resolve_launch_spec(agent_name, agent_cfg)
  local has_running_session = state.sessions[agent_name] and state.sessions[agent_name].pane_id
  if not launch_spec and not has_running_session then
    vim.notify("interactive agent " .. tostring(agent_name) .. ": " .. tostring(launch_err or "launch command is not configured"), vim.log.levels.ERROR)
    return
  end

  -- Default to reuse sessions unless explicitly disabled. If the agent requests YOLO
  -- (agent_cfg.yolo = true), default to NOT reusing sessions unless the caller explicitly set opts.reuse.
  local reuse = opts.reuse ~= false
  if opts.reuse == nil and agent_cfg and agent_cfg.yolo then
    reuse = false
  end
  local backend_name = select(1, backend_logic.resolve_backend_for_agent(agent_name, agent_cfg))
  local preserve_scratch = acp_logic.is_acp_backend(backend_name)
  M.ensure_session(agent_name, agent_cfg, reuse, function(pane_id)
    -- Handle one-shot sends where no input scratch buffer is opened.
    if opts.open_input == false then
      send_logic.send_and_close_if_needed(agent_name, pane_id, opts.initial_input, agent_cfg, reuse, origin_bufnr)
      return
    end

    -- Create an input buffer and open it in a floating window.
    local bufnr = window.ensure_scratch_buffer(window.get_scratch_bufnr(agent_name), {
      agent_name = agent_name,
      filetype = agent_cfg.scratch_filetype or "lazyagent",
      source_bufnr = origin_bufnr,
    })
    pcall(function() vim.b[bufnr].lazyagent_agent = agent_name end)

    -- Register buffer-local scratch keymaps (include source/origin buffer so placeholders resolve correctly)
    keymaps_logic.register_scratch_keymaps(bufnr, { agent_name = agent_name, agent_cfg = agent_cfg, pane_id = pane_id, reuse = reuse, source_bufnr = origin_bufnr })

    state.open_agent = agent_name
    local open_opts = { window_type = agent_cfg.window_type or state.opts.window_type }
    if agent_cfg and agent_cfg.start_in_insert_on_focus ~= nil then
      open_opts.start_in_insert_on_focus = agent_cfg.start_in_insert_on_focus
    else
      open_opts.start_in_insert_on_focus = (state.opts and state.opts.start_in_insert_on_focus) or false
    end
    open_opts.is_vertical = agent_cfg.is_vertical or false
    open_opts.parent_winid = origin_winid

    -- Pass specific window overrides (size, etc)
    if opts.window_opts then
       open_opts.window_opts = opts.window_opts
    end
    if opts.title then
       open_opts.title = opts.title
    end
    open_opts.agent_name = agent_name
    open_opts.close_on_focus_lost = preserve_scratch
    open_opts.on_close = function()
      if state.open_agent == agent_name then
        state.open_agent = nil
      end
    end

    window.open(bufnr, open_opts)

    -- Set initial content if provided
    if opts.initial_input and opts.initial_input ~= "" then
      vim.schedule(function()
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(opts.initial_input, "\n"))
        end
      end)
    end
  end)
end


---
-- Attaches nvim to an already-running tmux pane (e.g. after nvim was restarted).
-- Lists all live tmux panes, lets the user pick one, then registers it as an agent session.
-- @param agent_name (string|nil) Pre-select the agent name; if nil the user is prompted.
-- @param pane_id    (string|nil) Pre-select the pane ID;   if nil the user is prompted.
function M.attach_session(agent_name, pane_id)
  -- Collect live panes via `tmux list-panes -a`
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

    -- Verify pane is still alive
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
      launch_cmd = nil, -- unknown; launched externally
      cwd = vim.fn.getcwd(),
      hidden = true, -- treat as detached until user opens scratch
      force_resume = true,
      session_scope = current_editor_session_name(),
    }

    -- Persist so the pairing survives future restarts too
    persistence.update_session(chosen_agent, chosen_pane_id, vim.fn.getcwd())

    vim.notify(
      "LazyAgentAttach: agent '" .. chosen_agent .. "' attached to pane " .. chosen_pane_id,
      vim.log.levels.INFO
    )

    -- Open scratch buffer so the user can immediately interact
    M.start_interactive_session({ agent_name = chosen_agent, reuse = true })
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

  -- Resolve agent name first, then pick pane
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

return M
