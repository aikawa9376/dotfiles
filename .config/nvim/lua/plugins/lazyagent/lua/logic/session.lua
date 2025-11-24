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

---
-- Ensures a backend session (e.g., a tmux pane) exists for the agent.
-- @param agent_name (string) The name of the agent.
-- @param agent_cfg (table) The agent's configuration.
-- @param reuse (boolean) Whether to reuse an existing session if available.
-- @param on_ready (function) Callback to execute with the pane_id when ready.
function M.ensure_session(agent_name, agent_cfg, reuse, on_ready)
  local backend_name, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, agent_cfg)

  if reuse and state.sessions[agent_name] and state.sessions[agent_name].pane_id and state.sessions[agent_name].pane_id ~= "" then
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

  backend_mod.split(agent_cfg.cmd, agent_cfg.pane_size or 30, agent_cfg.is_vertical or false, function(pane_id)
    if not pane_id or pane_id == "" then
      vim.notify("Failed to create pane for agent " .. tostring(agent_name), vim.log.levels.ERROR)
      return
    end
    state.sessions[agent_name] = { pane_id = pane_id, last_output = "", backend = backend_name }
    on_ready(pane_id)
  end)
end

---
-- Closes a specific agent's session.
-- @param agent_name (string) The name of the agent.
function M.close_session(agent_name)
  if not agent_name or agent_name == "" then
    return
  end
  local s = state.sessions[agent_name]
  if s and s.pane_id and s.pane_id ~= "" then
    local _, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, nil)
    backend_mod.kill_pane(s.pane_id)
  end
  state.sessions[agent_name] = nil
end

---
-- Closes all active agent sessions.
function M.close_all_sessions()
  for name, s in pairs(state.sessions) do
    if s and s.pane_id and s.pane_id ~= "" then
      local _, backend_mod = backend_logic.resolve_backend_for_agent(name, nil)
      backend_mod.kill_pane(s.pane_id)
    end
    state.sessions[name] = nil
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

  -- Require an interactive agent configuration with a 'cmd' to start an interactive session
  if not (agent_cfg and agent_cfg.cmd) then
    vim.notify("interactive agent " .. tostring(agent_name) .. " is not configured", vim.log.levels.ERROR)
    return
  end

  -- Default to reuse sessions unless explicitly disabled
  local reuse = opts.reuse ~= false
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
    -- Attach cache auto-save to this buffer (if enabled).
    pcall(function()
      local cache_logic = require("logic.cache")
      if cache_logic.attach_cache_to_buf then cache_logic.attach_cache_to_buf(bufnr) end
    end)

    -- Register buffer-local scratch keymaps (include source/origin buffer so placeholders resolve correctly)
    keymaps_logic.register_scratch_keymaps(bufnr, { agent_name = agent_name, agent_cfg = agent_cfg, pane_id = pane_id, reuse = reuse, source_bufnr = origin_bufnr })

    state.open_agent = agent_name
    local open_opts = { window_type = agent_cfg.window_type or state.opts.window_type }
    if agent_cfg and agent_cfg.start_in_insert_on_focus ~= nil then
      open_opts.start_in_insert_on_focus = agent_cfg.start_in_insert_on_focus
    else
      open_opts.start_in_insert_on_focus = (state.opts and state.opts.start_in_insert_on_focus) or false
    end
    window.open(bufnr, open_opts)

    -- Set initial content if provided
    if opts.initial_input and opts.initial_input ~= "" then
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(opts.initial_input, "\n"))
    end
  end)
end


return M
