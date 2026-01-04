-- logic/session.lua
-- This module is responsible for managing agent sessions, including
-- starting, stopping, and toggling interactive sessions.
local M = {}

local state = require("lazyagent.logic.state")
local agent_logic = require("lazyagent.logic.agent")
local backend_logic = require("lazyagent.logic.backend")
local keymaps_logic = require("lazyagent.logic.keymaps")
local send_logic = require("lazyagent.logic.send")
local cache_logic = require("lazyagent.logic.cache")
local window = require("lazyagent.window")
local persistence = require("lazyagent.logic.persistence")
local ok_watch, watch = pcall(require, "lazyagent.watch")

local function compute_launch_cmd(agent_cfg)
  -- Convert agent_cfg.cmd/cmd_yolo (string or table) to a single string suitable
  -- for backends and append/replace YOLO flags when requested.
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

  local base_cmd = agent_cfg and agent_cfg.cmd or nil
  local agent_yolo_flag = (agent_cfg and agent_cfg.yolo_flag) or (state.opts and state.opts.yolo_flag)
  local use_yolo = agent_cfg and agent_cfg.yolo or false

  -- Priority:
  -- 1) If yolo requested and agent_yolo_flag exists and base_cmd exists, append the flag to the base command
  -- 2) Fall back to base_cmd if present
  if use_yolo and agent_yolo_flag and base_cmd then
    local bc = join_cmd_parts(base_cmd)
    if bc and bc ~= "" then
      return bc .. " " .. tostring(agent_yolo_flag)
    end
  end

  return join_cmd_parts(base_cmd)
end

local function maybe_disable_watchers()
  if not ok_watch or not watch or type(watch.disable) ~= "function" then return end
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
    pcall(watch.disable)
  end
end

---
-- Ensures a backend session (e.g., a tmux pane) exists for the agent.
-- @param agent_name (string) The name of the agent.
-- @param agent_cfg (table) The agent's configuration.
-- @param reuse (boolean) Whether to reuse an existing session if available.
-- @param on_ready (function) Callback to execute with the pane_id when ready.
function M.ensure_session(agent_name, agent_cfg, reuse, on_ready)
  local backend_name, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, agent_cfg)
  local requested_launch_cmd = compute_launch_cmd(agent_cfg)

  -- Check for persisted session.
  -- Even if resume is disabled globally, if a persisted session exists (e.g. explicitly Detached),
  -- we should try to restore it.
  if not (state.sessions[agent_name] and state.sessions[agent_name].pane_id) then
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
          launch_cmd = requested_launch_cmd,
          hidden = true, -- Assume hidden/detached if we are restoring it
          cwd = vim.fn.getcwd()
        }
        -- If it was hidden, we need to join it? ensure_session logic below handles reuse/hidden.
        -- Just setting state.sessions[agent_name] is enough to trigger the reuse logic block below.
      else
        -- Invalid persisted session, clean it up
        persistence.remove_session(agent_name)
      end
    end
  end

  if reuse and state.sessions[agent_name] and state.sessions[agent_name].pane_id and state.sessions[agent_name].pane_id ~= "" then
    -- If the session was hidden, restore it (join-pane)
    if state.sessions[agent_name].hidden then
      if backend_mod and type(backend_mod.join_pane) == "function" then
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
      -- If this session now wants watching enabled, ensure watchers are enabled.
      if state.sessions[agent_name].watch_enabled and ok_watch and watch and type(watch.enable) == "function" then
        pcall(watch.enable)
      end
      -- If this session no longer wants watching, check whether to disable watchers globally.
      if not state.sessions[agent_name].watch_enabled then
        maybe_disable_watchers()
      end
    end

    -- If an existing session was launched with a different command, don't reuse it.
    if state.sessions[agent_name].launch_cmd and requested_launch_cmd and state.sessions[agent_name].launch_cmd ~= requested_launch_cmd then
      -- Intentionally don't reuse; fall through to create a new session
    else
      if backend_mod and type(backend_mod.pane_exists) == "function" then
        if backend_mod.pane_exists(state.sessions[agent_name].pane_id) then
          on_ready(state.sessions[agent_name].pane_id)
          return
        end
      else
        on_ready(state.sessions[agent_name].pane_id)
        return
      end
    end
  end

  backend_mod.split(requested_launch_cmd, agent_cfg.pane_size or 30, agent_cfg.is_vertical or false, function(pane_id)
    if not pane_id or pane_id == "" then
      vim.notify("Failed to create pane for agent " .. tostring(agent_name), vim.log.levels.ERROR)
      return
    end

        -- Determine this session's watch preference (default true)
        local watch_enabled_val = true
        if agent_cfg and agent_cfg.watch ~= nil then watch_enabled_val = agent_cfg.watch end

        state.sessions[agent_name] = { pane_id = pane_id, last_output = "", backend = backend_name, watch_enabled = watch_enabled_val, launch_cmd = requested_launch_cmd, cwd = vim.fn.getcwd() }
        -- If this session requested watchers, enable them.
        if watch_enabled_val and ok_watch and watch and type(watch.enable) == "function" then
          pcall(watch.enable)
        end
        
        -- Persist session if resume is enabled
        local resume_enabled = (agent_cfg and agent_cfg.resume) or (state.opts and state.opts.resume)
        if resume_enabled then
          persistence.update_session(agent_name, pane_id, state.sessions[agent_name].cwd)
        end

    -- Wait a bit for tmux to resize and vim to update its dimensions before opening the window
    vim.defer_fn(function()
      on_ready(pane_id)
    end, 200)
  end)
end

--- Captures and saves the conversation text for the given agent's session.
-- @param agent_name (string) The name of the agent.
-- @param open_file (boolean) If true, open the saved file in a buffer after saving.
-- @param on_done (function|nil) Optional callback invoked after capture is saved (receives path).
function M.capture_and_save_session(agent_name, open_file, on_done)
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
        vim.notify("LazyAgentOpenConversation: captured pane was empty for agent '" .. tostring(agent_name) .. "'", vim.log.levels.INFO)
        on_done()
        return
      end

      local lines = vim.split(text, "\n")
      local dir = cache_logic.get_cache_dir()
      local prefix = cache_logic.build_cache_prefix()
      local sanitized = tostring(agent_name):gsub("[^%w-_]+", "-")
      local filename = prefix .. sanitized .. "-conversation-" .. os.date("%Y-%m-%d-%H%M%S") .. ".log"
      local path = dir .. "/" .. filename

      pcall(vim.fn.writefile, lines, path)

      if open_file then
        vim.cmd("edit " .. vim.fn.fnameescape(path))
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

  local agent_cfg = agent_logic.get_interactive_agent(agent_name)
  local save_conv = (agent_cfg and agent_cfg.save_conversation_on_close) or (state.opts and state.opts.save_conversation_on_close)
  local open_conv = (agent_cfg and agent_cfg.open_conversation_on_save) or (state.opts and state.opts.open_conversation_on_save)

  local _, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, nil)

  if save_conv and backend_mod and type(backend_mod.capture_pane) == "function" then
    M.capture_and_save_session(agent_name, open_conv, function()
      local _, backend_mod2 = backend_logic.resolve_backend_for_agent(agent_name, nil)
      if backend_mod2 and type(backend_mod2.kill_pane) == "function" then
        backend_mod2.kill_pane(s.pane_id)
      end
      state.sessions[agent_name] = nil
      maybe_disable_watchers()
    end)
    return
  end

  if backend_mod and type(backend_mod.kill_pane) == "function" then
    backend_mod.kill_pane(s.pane_id)
  end
  state.sessions[agent_name] = nil
  persistence.remove_session(agent_name, s.cwd)
  maybe_disable_watchers()

  if backend_mod and type(backend_mod.cleanup_if_idle) == "function" then
    pcall(backend_mod.cleanup_if_idle)
  end
end

---
-- Closes all active agent sessions.
function M.close_all_sessions(sync)
  local seen_backends = {}
  for name, s in pairs(state.sessions) do
    if s and s.pane_id and s.pane_id ~= "" then
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
              local dir = cache_logic.get_cache_dir()
              local prefix = cache_logic.build_cache_prefix()
              local sanitized = tostring(name):gsub("[^%w-_]+", "-")
              local filename = prefix .. sanitized .. "-conversation-" .. os.date("%Y-%m-%d-%H%M%S") .. ".log"
              local path = dir .. "/" .. filename
              pcall(vim.fn.writefile, lines, path)
           end
        end
        
        if resume_enabled then
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
             backend_mod.kill_pane_sync(s.pane_id)
          elseif backend_mod and type(backend_mod.kill_pane) == "function" then
             backend_mod.kill_pane(s.pane_id)
          end
          persistence.remove_session(name, s.cwd)
        end
        state.sessions[name] = nil
      else
        if save_conv and backend_mod and type(backend_mod.capture_pane) == "function" then
          M.capture_and_save_session(name, open_conv, function()
            local _, backend_mod2 = backend_logic.resolve_backend_for_agent(name, nil)
            if backend_mod2 and type(backend_mod2.kill_pane) == "function" then
              backend_mod2.kill_pane(s.pane_id)
            end
            state.sessions[name] = nil
          end)
        else
          if backend_mod and type(backend_mod.kill_pane) == "function" then
            backend_mod.kill_pane(s.pane_id)
          end
          state.sessions[name] = nil
        end
      end
    else
      state.sessions[name] = nil
    end
  end
  if ok_watch and watch and type(watch.disable) == "function" then
    pcall(watch.disable)
  end

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
      window.close()
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
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
    M.start_interactive_session({ agent_name = chosen, reuse = true, initial_input = initial_input })
  end

  agent_logic.resolve_target_agent(agent_name, nil, _toggle)
end

---
-- Resume a conversation from a saved conversation log by loading it into a new scratch buffer.
-- Prompts the user to select a snapshot file and an agent (if not provided), then opens a session
-- with the snapshot content preloaded.
-- @param agent_name (string|nil) The name of the agent to use.
function M.resume_conversation(agent_name)
  local dir, choices = cache_logic.list_cache_Conversation()
  if not choices or #choices == 0 then
    local msg = "LazyAgentResume: no conversation snapshots found"
    if dir then msg = msg .. " in " .. dir end
    vim.notify(msg, vim.log.levels.INFO)
    return
  end

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

  vim.ui.select(choices, {
    prompt = "Resume LazyAgent conversation:",
    -- fzf-lua ui.select: show file preview from cache dir
    previewer = "builtin",
    cwd = dir,
  }, function(selected, idx)
    local choice = (idx and choices and choices[idx]) or selected
    if not choice or choice == "" then return end
    local path = ((dir or ""):gsub("/$", "")) .. "/" .. choice
    start_with_path(path)
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

    -- Mark for persistence so close_all_sessions won't kill it
    s.force_resume = true
    persistence.update_session(chosen, s.pane_id, s.cwd)

    -- Close the floating window if it's open for this agent
    if state.open_agent == chosen and window.is_open() then
      local bufnr = window.get_bufnr()
      window.close()
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
      state.open_agent = nil
    end

    -- Hide the pane (break_pane)
    if not s.hidden then
      local _, backend_mod = backend_logic.resolve_backend_for_agent(chosen, nil)
      if backend_mod and type(backend_mod.break_pane) == "function" then
        -- Try to save size before breaking
        if type(backend_mod.get_pane_info) == "function" then
          backend_mod.get_pane_info(s.pane_id, function(info)
            if info then
              s.last_size = info
            end
            backend_mod.break_pane(s.pane_id)
            s.hidden = true
            vim.notify("Agent '" .. chosen .. "' detached and persisted.", vim.log.levels.INFO)
          end)
        else
          backend_mod.break_pane(s.pane_id)
          s.hidden = true
          vim.notify("Agent '" .. chosen .. "' detached and persisted.", vim.log.levels.INFO)
        end
      end
    else
      vim.notify("Agent '" .. chosen .. "' is already detached.", vim.log.levels.INFO)
    end
  end

  agent_logic.resolve_target_agent(agent_name, nil, _detach)
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

  -- Determine whether a launch command is available for this agent (cmd, cmd_yolo, or yolo flag)
  local has_launch = agent_cfg and (agent_cfg.cmd or agent_cfg.cmd_yolo or agent_cfg.yolo_flag or (state.opts and state.opts.yolo_flag))
  if not has_launch then
    vim.notify("interactive agent " .. tostring(agent_name) .. " is not configured with a launch command", vim.log.levels.ERROR)
    return
  end

  -- Default to reuse sessions unless explicitly disabled. If the agent requests YOLO
  -- (agent_cfg.yolo = true), default to NOT reusing sessions unless the caller explicitly set opts.reuse.
  local reuse = opts.reuse ~= false
  if opts.reuse == nil and agent_cfg and agent_cfg.yolo then
    reuse = false
  end
  M.ensure_session(agent_name, agent_cfg, reuse, function(pane_id)
    -- Handle one-shot sends where no input scratch buffer is opened.
    if opts.open_input == false then
      send_logic.send_and_close_if_needed(agent_name, pane_id, opts.initial_input, agent_cfg, reuse, origin_bufnr)
      return
    end

    -- Create an input buffer and open it in a floating window.
    local bufnr = window.ensure_scratch_buffer(nil, {
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


return M
