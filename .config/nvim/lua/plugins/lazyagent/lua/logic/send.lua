-- logic/send.lua
-- This module contains functions for sending text to agents,
-- whether interactive (CLI) or non-interactive (prompts).
local M = {}

local state = require("logic.state")
local agent_logic = require("logic.agent")
local backend_logic = require("logic.backend")
local cache_logic = require("logic.cache")
local transforms = require("lazyagent.transforms")
local util = require("lazyagent.util")

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

  local _, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, agent_cfg)

  local _send_mode = (agent_cfg and agent_cfg.send_mode) or (state.opts and state.opts.send_mode)
  local _move_to_end = (_send_mode == "append")
  local _use_bracketed_paste = (agent_cfg and agent_cfg.use_bracketed_paste) or (state.opts and state.opts.use_bracketed_paste)
  backend_mod.paste_and_submit(pane_id, text, agent_cfg.submit_keys, {
    submit_delay = agent_cfg.submit_delay or state.opts.submit_delay,
    submit_retry = agent_cfg.submit_retry or state.opts.submit_retry,
    debug = state.opts.debug,
    move_to_end = _move_to_end,
    use_bracketed_paste = _use_bracketed_paste,
  })

  -- For one-shot (non-interactive) sends, kill the pane after a delay if it's not meant to be reused.
  vim.defer_fn(function()
    if not reuse then
      backend_mod.kill_pane(pane_id)
      state.sessions[agent_name] = nil
    end
  end, agent_cfg.capture_delay or 800)
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
  local expanded_text, meta = transforms.expand(text, { source_bufnr = source_bufnr })
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
    local session_logic = require("logic.session") -- require here to avoid circular dependency
    session_logic.ensure_session(agent_name, agent_cfg, reuse, function(pane_id)
      if not pane_id or pane_id == "" then
        vim.notify("send_to_cli: failed to obtain pane for " .. tostring(agent_name), vim.log.levels.ERROR)
        return
      end
      cache_logic.write_scratch_to_cache()
      local _, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, agent_cfg)
      local _send_mode = (agent_cfg and agent_cfg.send_mode) or (state.opts and state.opts.send_mode)
      local _move_to_end = (_send_mode == "append")
      local _use_bracketed_paste = (agent_cfg and agent_cfg.use_bracketed_paste) or (state.opts and state.opts.use_bracketed_paste)
      backend_mod.paste_and_submit(pane_id, text, agent_cfg.submit_keys, {
        submit_delay = agent_cfg.submit_delay or state.opts.submit_delay,
        submit_retry = agent_cfg.submit_retry or state.opts.submit_retry,
        debug = state.opts.debug,
        move_to_end = _move_to_end,
        use_bracketed_paste = _use_bracketed_paste,
      })
      if not reuse then
        vim.defer_fn(function()
          backend_mod.kill_pane(pane_id)
          state.sessions[agent_name] = nil
        end, agent_cfg.capture_delay or 800)
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
    if meta and meta.diagnostics and #meta.diagnostics > 0 then
      context.diagnostics = meta.diagnostics
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
  if not text or #text == 0 then
    vim.notify("send_buffer_and_clear: buffer is empty", vim.log.levels.INFO)
    return
  end

  -- Expand placeholders before sending using the send buffer as the source buffer (makes {buffer} behave sensibly).
  local expanded_text, meta = transforms.expand(text, { source_bufnr = bufnr })
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
    local session_logic = require("logic.session") -- require here to avoid circular dependency
    session_logic.ensure_session(agent_name, agent_cfg, true, function(pane_id)
      if not pane_id or pane_id == "" then
        vim.notify("send_buffer_and_clear: failed to obtain pane for " .. tostring(agent_name), vim.log.levels.ERROR)
        return
      end
      -- Save scratch content to cache on send
      cache_logic.write_scratch_to_cache(bufnr)
      local _, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, agent_cfg)
      backend_mod.paste_and_submit(pane_id, text, agent_cfg.submit_keys, {
        submit_delay = agent_cfg.submit_delay or state.opts.submit_delay,
        submit_retry = agent_cfg.submit_retry or state.opts.submit_retry,
        debug = state.opts.debug,
      })
      pcall(function() vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {}) end)
    end)
    return
  end

  -- Not interactive: if there's a prompt handler, call it and clear the buffer afterwards.
  local p = state.opts and state.opts.prompts and state.opts.prompts[agent_name] or nil
  if p then
    local filename = vim.api.nvim_buf_get_name(bufnr) or ""
    local ft = vim.bo[bufnr].filetype or ""
    local context = { filename = filename, text = text, filetype = ft, selection = text }
    -- Add diagnostics meta to context if available (useful to prompts)
    if meta and meta.diagnostics and #meta.diagnostics > 0 then
      context.diagnostics = meta.diagnostics
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
  local expanded_text, meta = transforms.expand(context.text, { source_bufnr = vim.api.nvim_get_current_buf() })
  context.text = expanded_text or context.text
  if meta and meta.diagnostics and #meta.diagnostics > 0 then
    context.diagnostics = meta.diagnostics
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

return M
