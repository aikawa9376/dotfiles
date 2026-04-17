-- logic/send.lua
-- This module contains functions for sending text to agents,
-- whether interactive (CLI) or non-interactive (prompts).
local M = {}

local state = require("lazyagent.logic.state")
local agent_logic = require("lazyagent.logic.agent")
local backend_logic = require("lazyagent.logic.backend")
local cache_logic = require("lazyagent.logic.cache")
local transforms = require("lazyagent.transforms")
local util = require("lazyagent.util")
local config = require("lazyagent.logic.config")
local window = require("lazyagent.window")
local status = require("lazyagent.logic.status")

-- Helper to send text to a pane and optionally kill it after a delay.
-- Used for one-shot commands.
-- @param agent_name (string) The name of the agent.
-- @param pane_id (string) The ID of the pane to send to.
-- @param text (string) The text to send.
-- @param agent_cfg (table) The agent's configuration.
-- @param reuse (boolean) Whether the pane should be reused.
-- @param source_bufnr (number|nil) The source buffer number for placeholder expansion.
function M.send_and_close_if_needed(agent_name, pane_id, text, agent_cfg, reuse, source_bufnr)
  if not text or text == "" then
    return
  end

  -- Expand placeholders in one-shot input before sending.
  local expanded_text, _ = transforms.expand(text, { source_bufnr = source_bufnr or vim.api.nvim_get_current_buf() })
  text = expanded_text or text

  -- Persist the one-shot content to the cache (if configured). Use the source_bufnr supplied
  -- by the caller so this write does not rely on the currently focused buffer.
  pcall(function() cache_logic.write_scratch_to_cache(source_bufnr) end)

  local _, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, agent_cfg)

  local _send_mode = config.pref(agent_cfg, "send_mode", nil)
  local _move_to_end = (_send_mode == "append")
  local _use_bracketed_paste = config.pref(agent_cfg, "use_bracketed_paste", nil)
  if text:match("^/") then _use_bracketed_paste = false end
  local submit_result = backend_mod.paste_and_submit(pane_id, text, agent_cfg.submit_keys, {
    submit_delay = config.pref(agent_cfg, "submit_delay", state.opts.submit_delay),
    submit_retry = config.pref(agent_cfg, "submit_retry", state.opts.submit_retry),
    debug = state.opts.debug,
    move_to_end = _move_to_end,
    use_bracketed_paste = _use_bracketed_paste,
  })
  if submit_result == true then
    status.start_monitor(agent_name)
  end

  -- For one-shot (non-interactive) sends, close the session after its turn is finished (status becomes idle or waiting).
  local session_logic = require("lazyagent.logic.session")
  if submit_result == true and not reuse then
    session_logic.close_session(agent_name)
  end
end

-- Sends text to a CLI agent (interactive agent pane).
-- @param agent_name (string) The name of the agent.
-- @param text (string) The text to send.
-- @param opts (table|nil) Options, e.g., source_bufnr for context.
function M.send_to_cli(agent_name, text, opts)
  opts = opts or {}
  if not text or #text == 0 then
    vim.notify("send_to_cli: text is empty", vim.log.levels.ERROR)
    return
  end

  -- Expand placeholders before sending (use a source_bufnr hint if provided).
  local source_bufnr = (opts and opts.source_bufnr) or vim.api.nvim_get_current_buf()
  local expanded_text, _ = transforms.expand(text, { source_bufnr = source_bufnr })
  text = expanded_text or text

  -- Determine the agent_name if not provided
  if not agent_name or agent_name == "" then
    if state.open_agent and state.open_agent ~= "" then
      agent_name = state.open_agent
    else
      local bufnr = vim.api.nvim_get_current_buf()
      local ft = vim.bo[bufnr].filetype
      local settings = (state.opts and state.opts.filetype_settings) and (state.opts.filetype_settings[ft] or state.opts.filetype_settings["*"]) or nil
      if settings and settings.agent then agent_name = settings.agent end
    end
  end

  if not agent_name or agent_name == "" then
    agent_logic.resolve_target_agent(nil, nil, function(chosen)
      if not chosen or chosen == "" then
        vim.notify("send_to_cli: no agent available for sending", vim.log.levels.ERROR)
        return
      end
      M.send_to_cli(chosen, text, opts)
    end)
    return
  end

  local agent_cfg = agent_logic.get_interactive_agent(agent_name)
  -- Interactive (cli) agents: ensure a pane and send to it.
  if agent_cfg then
    local reuse = opts.reuse ~= false
    local session_logic = require("lazyagent.logic.session") -- require here to avoid circular dependency
    session_logic.ensure_session(agent_name, agent_cfg, reuse, function(pane_id)
      if not pane_id or pane_id == "" then
        vim.notify("send_to_cli: failed to obtain pane for " .. tostring(agent_name), vim.log.levels.ERROR)
        return
      end
      cache_logic.write_scratch_to_cache(source_bufnr)
      local _, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, agent_cfg)
      local _send_mode = config.pref(agent_cfg, "send_mode", nil)
      local _move_to_end = (_send_mode == "append")
      local _use_bracketed_paste = config.pref(agent_cfg, "use_bracketed_paste", nil)
      -- Slash commands must not be wrapped in bracketed paste; CLIs treat bracketed
      -- paste as literal text and won't recognise the leading "/" as a command prefix.
      if text:match("^/") then _use_bracketed_paste = false end
      local submit_result = backend_mod.paste_and_submit(pane_id, text, agent_cfg.submit_keys, {
        submit_delay = config.pref(agent_cfg, "submit_delay", state.opts.submit_delay),
        submit_retry = config.pref(agent_cfg, "submit_retry", state.opts.submit_retry),
        debug = state.opts.debug,
        move_to_end = _move_to_end,
        use_bracketed_paste = _use_bracketed_paste,
      })
      if submit_result == true then
        status.start_monitor(agent_name)
      end

      -- For one-shot (non-interactive) sends, close the session after its turn is finished (status becomes idle or waiting).
      local session_logic = require("lazyagent.logic.session")
      if submit_result == true and not reuse then
        session_logic.close_session(agent_name)
      end
    end)
    return
  end

  -- Non-interactive handlers (prompts)
  local p = state.opts and state.opts.prompts and state.opts.prompts[agent_name] or nil
  if p then
    local bufnr = vim.api.nvim_get_current_buf()
    local filename = vim.api.nvim_buf_get_name(bufnr) or ""
    local ft = vim.bo[bufnr].filetype or ""
      local context = { filename = filename, text = text, filetype = ft, selection = text }
      -- Add diagnostics to context if available
      local diags = transforms.gather_diagnostics(source_bufnr)
      if diags and #diags > 0 then
        context.diagnostics = diags
      end
      cache_logic.write_scratch_to_cache(bufnr)
      p(context)
      return
  end

  vim.notify("send_to_cli: agent " .. tostring(agent_name) .. " is not configured", vim.log.levels.ERROR)
end

-- Sends the contents of a buffer to the specified agent and clears the buffer.
-- This function does NOT close the scratch window; it only clears buffer contents.
-- @param agent_name (string|nil) Agent name (Gemini / Claude / etc). If not specified,
--                                uses M.open_agent if available, or falls back to filetype mapping.
-- @param bufnr (number|nil) Buffer to send (defaults to current buffer).
function M.send_buffer_and_clear(agent_name, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    vim.notify("send_buffer_and_clear: invalid buffer", vim.log.levels.ERROR)
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = table.concat(lines, "\n")

  -- Expand placeholders before sending using the send buffer as the source buffer (makes {buffer} behave sensibly).
  local expanded_text, _ = transforms.expand(text, { source_bufnr = bufnr })
  text = expanded_text or text

  -- determine agent_name if not specified
  if not agent_name or agent_name == "" then
    if state.open_agent and state.open_agent ~= "" then
      agent_name = state.open_agent
    else
      local ft = vim.bo[bufnr].filetype
      local settings = (state.opts and state.opts.filetype_settings) and (state.opts.filetype_settings[ft] or state.opts.filetype_settings["*"]) or nil
      if settings and settings.agent then
        agent_name = settings.agent
      end
    end
  end

  -- If agent still isn't determined, prompt the user to pick one.
  if not agent_name or agent_name == "" then
    agent_logic.resolve_target_agent(nil, nil, function(chosen)
      if not chosen or chosen == "" then
        vim.notify("send_buffer_and_clear: no agent available for sending", vim.log.levels.ERROR)
        return
      end
      M.send_buffer_and_clear(chosen, bufnr)
    end)
    return
  end

  local agent_cfg = agent_logic.get_interactive_agent(agent_name)
  if agent_cfg then
    -- For interactive agents (tmux-based), ensure a pane then paste/submit.
    local session_logic = require("lazyagent.logic.session") -- require here to avoid circular dependency
    session_logic.ensure_session(agent_name, agent_cfg, true, function(pane_id)
      if not pane_id or pane_id == "" then
        vim.notify("send_buffer_and_clear: failed to obtain pane for " .. tostring(agent_name), vim.log.levels.ERROR)
        return
      end
      -- Save scratch content to cache on send
      cache_logic.write_scratch_to_cache(bufnr)
      local _, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, agent_cfg)

      if not text or #text == 0 then
        backend_mod.send_keys(pane_id, { "Enter" })
        return
      end

      local submit_result = backend_mod.paste_and_submit(pane_id, text, agent_cfg.submit_keys, {
        submit_delay = config.pref(agent_cfg, "submit_delay", state.opts.submit_delay),
        submit_retry = config.pref(agent_cfg, "submit_retry", state.opts.submit_retry),
        debug = state.opts.debug,
      })
      if submit_result == false then
        return
      end
      pcall(function() vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {}) end)

      -- Start status monitor (spinner in statusline while agent is thinking)
      -- We start it here locally; agents using MCP will subsequently call notify_done when finished.
      if submit_result == true then
        status.start_monitor(agent_name)
      end
    end)
    return
  end

  -- Not interactive: if there's a prompt handler, call it and clear the buffer afterwards.
  local p = state.opts and state.opts.prompts and state.opts.prompts[agent_name] or nil
  if p then
    local filename = vim.api.nvim_buf_get_name(bufnr) or ""
    local ft = vim.bo[bufnr].filetype or ""
    local context = { filename = filename, text = text, filetype = ft, selection = text }
    -- Add diagnostics to context if available (useful to prompts)
    local diags = transforms.gather_diagnostics(bufnr)
    if diags and #diags > 0 then
      context.diagnostics = diags
    end
    -- Save scratch content to cache on send (prompts / non-interactive)
    cache_logic.write_scratch_to_cache(bufnr)
    p(context)
    pcall(function() vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {}) end)
    return
  end

  vim.notify("send_buffer_and_clear: agent " .. tostring(agent_name) .. " is not configured", vim.log.levels.ERROR)
end

-- Convenience wrapper to send and clear the current buffer.
-- @param agent_name (string|nil) The name of the agent.
function M.send_and_clear(agent_name)
  M.send_buffer_and_clear(agent_name, vim.api.nvim_get_current_buf())
end

-- Sends arbitrary text to an agent.
-- Determines the target agent based on filetype or user prompts.
-- @param text (string) The text content to send.
function M.send(text)
  if not text or #text == 0 then
    vim.notify("text is empty", vim.log.levels.ERROR)
    return
  end

  local ft = vim.bo.filetype
  local settings = state.opts.filetype_settings[ft] or state.opts.filetype_settings["*"]
  if not settings then
    vim.notify("filetype " .. ft .. " is not supported", vim.log.levels.ERROR)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local filename = vim.api.nvim_buf_get_name(bufnr)
  if filename == "" then
    filename = "untitled." .. ft
  end

  local context = {
    filename = filename,
    text = text,
    filetype = ft,
    selection = text,
  }

  -- Expand placeholders and compute diagnostics metadata for the context
  local expanded_text, _ = transforms.expand(context.text, { source_bufnr = vim.api.nvim_get_current_buf() })
  context.text = expanded_text or context.text
  local diags = transforms.gather_diagnostics(vim.api.nvim_get_current_buf())
  if diags and #diags > 0 then
    context.diagnostics = diags
  end

  local agent_name = settings.agent
  -- If agent exists as an interactive (tmux/CLI) agent, send via the CLI integration
  if agent_logic.get_interactive_agent(agent_name) then
    M.send_to_cli(agent_name, text)
    return
  end

  -- fallback: "gen" prompt expects user to input prompt text
  if agent_name == "gen" then
    vim.ui.input({ prompt = "Enter prompt: " }, function(input)
      if input and #input > 0 then
        context.prompt = input
        local p = state.opts.prompts and state.opts.prompts["gen"]
        if p then
          p(context)
        else
          vim.notify("gen prompt is not defined", vim.log.levels.ERROR)
        end
      end
    end)
  else
    -- regular prompts table
    local p = state.opts.prompts and state.opts.prompts[agent_name]
    if p then
      p(context)
    else
      vim.notify("prompt for agent " .. agent_name .. " is not defined", vim.log.levels.ERROR)
    end
  end
end

-- Sends the current visual selection to an agent.
function M.send_visual()
  local text = util.get_visual_selection()
  -- If selection was lost, try to reselect with 'gv' and fetch again
  if not text or #text == 0 then
    vim.cmd("silent! normal! gv")
    text = util.get_visual_selection()
  end
  M.send(text)
end

-- Sends the current line to an agent.
function M.send_line()
  local text = vim.api.nvim_get_current_line()
  M.send(text)
end

local function find_session_by_pane_id(pane_id)
  if not pane_id or pane_id == "" then
    return nil, nil
  end

  for agent_name, session in pairs(state.sessions or {}) do
    if session and session.pane_id == pane_id then
      return agent_name, session
    end
  end

  return nil, nil
end

local function resolve_send_target(opts)
  opts = opts or {}

  local agent_name = opts.agent_name
  local pane_id = opts.pane_id
  local backend_name = opts.backend_name
  local backend_mod = opts.backend_mod
  local session = nil

  if agent_name and state.sessions[agent_name] then
    session = state.sessions[agent_name]
    pane_id = pane_id or session.pane_id
  elseif pane_id and pane_id ~= "" then
    agent_name, session = find_session_by_pane_id(pane_id)
  else
    local active_agents = agent_logic.get_active_agents()
    if #active_agents == 0 then
      return nil
    end

    agent_name = state.open_agent
    if not agent_name or not state.sessions[agent_name] then
      agent_name = active_agents[1]
    end

    session = state.sessions[agent_name]
    pane_id = session and session.pane_id or nil
  end

  if (not pane_id or pane_id == "") and session then
    pane_id = session.pane_id
  end
  if not pane_id or pane_id == "" then
    return nil
  end

  if not backend_mod and agent_name then
    backend_name, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, nil)
  end

  backend_name = backend_name or (session and session.backend) or nil
  if not backend_mod and backend_name then
    backend_mod = state.backends and state.backends[backend_name] or nil
  end
  if not backend_mod then
    return nil
  end

  return {
    agent_name = agent_name,
    session = session,
    pane_id = pane_id,
    backend_name = backend_name,
    backend_mod = backend_mod,
  }
end

local function notify_missing_target(opts)
  if not (opts and opts.silent) then
    vim.notify("No active agent found", vim.log.levels.INFO)
  end
end

local function normalized_keys_for_backend(backend_name, key)
  local normalized = tostring(key)
  if normalized == "C-c" and backend_name == "builtin" then
    return { string.char(3) }
  end
  if normalized:match("^%d$") and backend_name == "tmux" then
    return { "--literal", normalized }
  end
  return { normalized }
end

function M.send_key(key, opts)
  local target = resolve_send_target(opts)
  if not target then
    notify_missing_target(opts)
    return
  end

  return target.backend_mod.send_keys(target.pane_id, normalized_keys_for_backend(target.backend_name, key))
end

function M.send_enter(opts)
  return M.send_key("Enter", opts)
end

function M.send_down(opts)
  return M.send_key("Down", opts)
end

function M.send_up(opts)
  return M.send_key("Up", opts)
end

function M.send_interrupt(opts)
  return M.send_key("C-c", opts)
end

function M.send_raw_keys(keys, opts)
  local target = resolve_send_target(opts)
  if not target then
    notify_missing_target(opts)
    return
  end

  return target.backend_mod.send_keys(target.pane_id, keys)
end

function M.clear_input(opts)
  local target = resolve_send_target(opts)
  if not target then
    notify_missing_target(opts)
    return
  end

  if target.backend_name == "tmux" then
    for _ = 1, 20 do
      target.backend_mod.run({ "send-keys", "-t", target.pane_id, "-H", "05" })
      vim.wait(5)
      target.backend_mod.run({ "send-keys", "-t", target.pane_id, "-H", "15" })
      vim.wait(5)
      target.backend_mod.run({ "send-keys", "-t", target.pane_id, "-H", "7F" })
      vim.wait(5)
    end
  else
    for _ = 1, 20 do
      target.backend_mod.send_keys(target.pane_id, { string.char(5), string.char(21), string.char(8) })
    end
  end
end

return M
