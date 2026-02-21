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
  backend_mod.paste_and_submit(pane_id, text, agent_cfg.submit_keys, {
    submit_delay = config.pref(agent_cfg, "submit_delay", state.opts.submit_delay),
    submit_retry = config.pref(agent_cfg, "submit_retry", state.opts.submit_retry),
    debug = state.opts.debug,
    move_to_end = _move_to_end,
    use_bracketed_paste = _use_bracketed_paste,
  })

  -- For one-shot (non-interactive) sends, close the session after a delay if it's not meant to be reused.
  local session_logic = require("lazyagent.logic.session")
  vim.defer_fn(function()
    if not reuse then
      session_logic.close_session(agent_name)
    end
  end, config.pref(agent_cfg, "capture_delay", 800))
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
      backend_mod.paste_and_submit(pane_id, text, agent_cfg.submit_keys, {
        submit_delay = config.pref(agent_cfg, "submit_delay", state.opts.submit_delay),
        submit_retry = config.pref(agent_cfg, "submit_retry", state.opts.submit_retry),
        debug = state.opts.debug,
        move_to_end = _move_to_end,
        use_bracketed_paste = _use_bracketed_paste,
      })
      local session_logic = require("lazyagent.logic.session")
      if not reuse then
        vim.defer_fn(function()
          session_logic.close_session(agent_name)
        end, config.pref(agent_cfg, "capture_delay", 800))
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

      backend_mod.paste_and_submit(pane_id, text, agent_cfg.submit_keys, {
        submit_delay = config.pref(agent_cfg, "submit_delay", state.opts.submit_delay),
        submit_retry = config.pref(agent_cfg, "submit_retry", state.opts.submit_retry),
        debug = state.opts.debug,
      })
      pcall(function() vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {}) end)

      -- Monitor if instant mode or hidden
      status.start_monitor(agent_name, pane_id, backend_mod)
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

function M.send_key(key)
  local active_agents = agent_logic.get_active_agents()
  if #active_agents == 0 then
    vim.notify("No active agent found", vim.log.levels.INFO)
    return
  end
  
  -- If there's an open agent (scratch buffer focused or last used), prefer it
  local target_agent = state.open_agent
  if not target_agent or not state.sessions[target_agent] then
     target_agent = active_agents[1]
  end

  local session = state.sessions[target_agent]
  if not session or not session.pane_id then return end
  
  local _, backend_mod = backend_logic.resolve_backend_for_agent(target_agent, nil)
  if key == "C-c" then
    backend_mod.send_keys(session.pane_id, { "C-c" })
  elseif key:match("^%d$") then
    -- Send digits as literal keys (-l) to avoid tmux interpreting them weirdly or if special handling is needed
    -- We use a special flag "--literal" that our modified tmux.send_keys understands to inject -l
    backend_mod.send_keys(session.pane_id, { "--literal", key })
  else
    backend_mod.send_keys(session.pane_id, { key })
  end
end

function M.send_enter()
  local active_agents = agent_logic.get_active_agents()
  if #active_agents == 0 then
    -- vim.notify("No active agent found", vim.log.levels.INFO)
    return
  end

  local target_agent = state.open_agent
  if not target_agent or not state.sessions[target_agent] then
     target_agent = active_agents[1]
  end

  local session = state.sessions[target_agent]
  if not session or not session.pane_id then return end

  local backend_name, backend_mod = backend_logic.resolve_backend_for_agent(target_agent, nil)
  if backend_name == "tmux" then
    -- 0D is CR (Enter)
    backend_mod.run({ "send-keys", "-t", session.pane_id, "-H", "0D" })
    -- Fallback to piping raw bytes if hex mode fails/ignored
    -- local cmd = "printf '\\x0d' | tmux load-buffer - && tmux paste-buffer -d -t " .. session.pane_id
    -- vim.fn.system(cmd)
  else
    M.send_key("Enter")
  end
end

function M.send_down()
  M.send_key("Down")
end

function M.send_up()
  M.send_key("Up")
end

function M.send_interrupt()
  M.send_key("C-c")
end

function M.send_raw_keys(keys)
  local active_agents = agent_logic.get_active_agents()
  if #active_agents == 0 then
    -- vim.notify("No active agent found", vim.log.levels.INFO)
    return
  end

  -- If there's an open agent (scratch buffer focused or last used), prefer it
  local target_agent = state.open_agent
  if not target_agent or not state.sessions[target_agent] then
     target_agent = active_agents[1]
  end

  local session = state.sessions[target_agent]
  if not session or not session.pane_id then return end

  local _, backend_mod = backend_logic.resolve_backend_for_agent(target_agent, nil)
  backend_mod.send_keys(session.pane_id, keys)
end

function M.clear_input()
  local active_agents = agent_logic.get_active_agents()
  if #active_agents == 0 then
    vim.notify("No active agent found", vim.log.levels.INFO)
    return
  end
  
  -- If there's an open agent (scratch buffer focused or last used), prefer it
  local target_agent = state.open_agent
  if not target_agent or not state.sessions[target_agent] then
     target_agent = active_agents[1]
  end

  local session = state.sessions[target_agent]
  if not session or not session.pane_id then return end
  
  local backend_name, backend_mod = backend_logic.resolve_backend_for_agent(target_agent, nil)
  
  if backend_name == "tmux" then
    -- Send hex codes for control keys to ensure they bypass TUI input filters
    -- Use printf and load-buffer/paste-buffer trick to force raw byte injection
    -- because send-keys (even with -H) can be intercepted by some TUI layers.
    -- We construct a sequence for C-e (05), C-u (15), BS (7F)
    -- local raw_cmd = "printf '\\x05\\x15\\x7f' | tmux load-buffer - && tmux paste-buffer -d -t " .. session.pane_id
    for _ = 1, 20 do
      backend_mod.run({ "send-keys", "-t", session.pane_id, "-H", "05" })
      vim.wait(5)
      backend_mod.run({ "send-keys", "-t", session.pane_id, "-H", "15" })
      vim.wait(5)
      backend_mod.run({ "send-keys", "-t", session.pane_id, "-H", "7F" })
      vim.wait(5)
    end
  else
    -- ASCII 5 is C-e, 21 is C-u, 8 is Backspace
    for _ = 1, 20 do
      backend_mod.send_keys(session.pane_id, { string.char(5), string.char(21), string.char(8) })
    end
  end
end

return M
