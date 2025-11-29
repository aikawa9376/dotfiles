-- logic/session.lua
-- This module is responsible for managing agent sessions, including
-- starting, stopping, and toggling interactive sessions.
local M = {}

local state = require("logic.state")
local agent_logic = require("logic.agent")
local backend_logic = require("logic.backend")
local keymaps_logic = require("logic.keymaps")
local send_logic = require("logic.send")
local util = require("lazyagent.util")
local window = require("lazyagent.window")
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

  if reuse and state.sessions[agent_name] and state.sessions[agent_name].pane_id and state.sessions[agent_name].pane_id ~= "" then
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

        state.sessions[agent_name] = { pane_id = pane_id, last_output = "", backend = backend_name, watch_enabled = watch_enabled_val, launch_cmd = requested_launch_cmd }
        -- If this session requested watchers, enable them.
        if watch_enabled_val and ok_watch and watch and type(watch.enable) == "function" then
          pcall(watch.enable)
        end
    on_ready(pane_id)
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
      local cache_logic = require("logic.cache")
      local dir = cache_logic.get_cache_dir()
      local sanitized = tostring(agent_name):gsub("[^%w-_]+", "-")
      local filename = sanitized .. "-conversation-" .. os.date("%Y-%m-%d-%H%M%S") .. ".log"
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
-- Closes a specific agent's session.
-- @param agent_name (string) The name of the agent.
function M.close_session(agent_name)
  if not agent_name or agent_name == "" then
    return
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
  maybe_disable_watchers()
end

---
-- Closes all active agent sessions.
function M.close_all_sessions()
  for name, s in pairs(state.sessions) do
    if s and s.pane_id and s.pane_id ~= "" then
      local agent_cfg = agent_logic.get_interactive_agent(name)
      local save_conv = (agent_cfg and agent_cfg.save_conversation_on_close) or (state.opts and state.opts.save_conversation_on_close)
      local open_conv = (agent_cfg and agent_cfg.open_conversation_on_save) or (state.opts and state.opts.open_conversation_on_save)
      local _, backend_mod = backend_logic.resolve_backend_for_agent(name, nil)
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
    else
      state.sessions[name] = nil
    end
  end
  if ok_watch and watch and type(watch.disable) == "function" then
    pcall(watch.disable)
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
      local text = util.get_visual_selection()
      -- If selection was lost, try to reselect with 'gv' and fetch again
      if not text or #text == 0 then
        vim.cmd("silent! normal! gv")
        text = util.get_visual_selection()
      end

      if text and #text > 0 then
        local start_pos = vim.fn.getpos("'<")
        local end_pos = vim.fn.getpos("'>")
        local start_line = start_pos[2]
        local end_line = end_pos[2]
        local file_path = vim.api.nvim_buf_get_name(0)
        if file_path and file_path ~= "" then
          file_path = vim.fn.fnamemodify(file_path, ":.")
        end

        local location_str = ""
        if file_path and file_path ~= "" and start_line > 0 and end_line > 0 then
          if start_line == end_line then
            location_str = string.format("@%s:%d", file_path, start_line)
          else
            location_str = string.format("@%s:%d-%d", file_path, start_line, end_line)
          end
        end

        if location_str ~= "" then
          initial_input = location_str
        end
      end

      -- Exit visual mode
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    end

    -- If the floating input is already open for this agent, close it.
    if state.open_agent == chosen and window.is_open() then
      local bufnr = window.get_bufnr()
      window.close()
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
      state.open_agent = nil
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
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].modifiable = true
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].filetype = agent_cfg.scratch_filetype or "lazyagent"
    -- Record the source/origin buffer so transforms and completion can resolve context.
    pcall(function() vim.b[bufnr].lazyagent_source_bufnr = origin_bufnr end)

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
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(opts.initial_input, "\n"))
    end
  end)
end


return M
