-- logic/commands.lua
-- This module contains functions for registering user commands.
local M = {}

local state = require("lazyagent.logic.state")
local agent_logic = require("lazyagent.logic.agent")
local session_logic = require("lazyagent.logic.session")
local cache_logic = require("lazyagent.logic.cache")
local summary_logic = require("lazyagent.logic.summary")

-- Helper to create commands safely
local function try_create_user_command(name, fn, cmd_opts)
  pcall(function() vim.api.nvim_create_user_command(name, fn, cmd_opts) end)
end

function M.setup_commands()
  -- Register convenience scratch starter command
  try_create_user_command("LazyAgentScratch", function(cmdargs)
    local explicit = (cmdargs and cmdargs.args and cmdargs.args ~= "") and cmdargs.args or nil
    agent_logic.resolve_target_agent(explicit, nil, function(chosen)
      if not chosen then return end
      session_logic.start_interactive_session({ agent_name = chosen, reuse = true })
    end)
  end, { nargs = "?", desc = "Open a scratch buffer for sending instructions to AI agent" })

  try_create_user_command("LazyAgentClose", function(cmdargs)
    local explicit = (cmdargs and cmdargs.args and cmdargs.args ~= "") and cmdargs.args or nil

    if explicit then
      session_logic.close_session(explicit)
      return
    end

    local active = agent_logic.get_active_agents()
    if #active == 0 then
      vim.notify("LazyAgentClose: no active agents found", vim.log.levels.INFO)
      return
    end

    if #active == 1 then
      session_logic.close_session(active[1])
      return
    end

    vim.ui.select(active, { prompt = "Choose agent to close:" }, function(chosen)
      if not chosen then return end
      session_logic.close_session(chosen)
    end)
  end, { nargs = "?", desc = "Close an agent tmux pane by name (optional agent name)" })

  try_create_user_command("LazyAgentToggle", function(cmdargs)
    local explicit = (cmdargs and cmdargs.args and cmdargs.args ~= "") and cmdargs.args or nil
    agent_logic.resolve_target_agent(explicit, nil, function(chosen)
      if not chosen then return end
      session_logic.toggle_session(chosen)
    end)
  end, {
      nargs = "?",
      desc = "Toggle the floating agent input buffer (open/close)",
      complete = function()
        return agent_logic.available_agents()
      end,
    })

  try_create_user_command("LazyAgentInstant", function(cmdargs)
    local explicit = (cmdargs and cmdargs.args and cmdargs.args ~= "") and cmdargs.args or nil
    session_logic.open_instant(explicit)
  end, {
      nargs = "?",
      desc = "Open an instant query window for an agent (runs in background pool)",
      complete = function()
        return agent_logic.available_agents()
      end,
    })

  try_create_user_command("LazyAgentRestart", function(cmdargs)
    local explicit = (cmdargs and cmdargs.args and cmdargs.args ~= "") and cmdargs.args or nil
    session_logic.restart_session(explicit)
  end, {
      nargs = "?",
      desc = "Restart an agent session (close and reopen)",
      complete = function()
        return agent_logic.available_agents()
      end,
    })

  try_create_user_command("LazyAgentRestore", function(cmdargs)
    local explicit = (cmdargs and cmdargs.args and cmdargs.args ~= "") and cmdargs.args or nil
    agent_logic.resolve_target_agent(explicit, nil, function(chosen)
      if not chosen then return end
      session_logic.start_interactive_session({ agent_name = chosen, reuse = true, resume = true })
    end)
  end, {
      nargs = "?",
      desc = "Restore a persisted agent session even if resume is disabled in config",
      complete = function()
        return agent_logic.available_agents()
      end,
    })

  try_create_user_command("LazyAgentDetach", function(cmdargs)
    local explicit = (cmdargs and cmdargs.args and cmdargs.args ~= "") and cmdargs.args or nil
    session_logic.detach_session(explicit)
  end, {
      nargs = "?",
      desc = "Detach and persist an agent session (keep alive in background)",
      complete = function()
        return agent_logic.available_agents()
      end,
    })

  -- User command to open history logs saved by lazyagent (from cache).
  try_create_user_command("LazyAgentHistoryList", function(cmdargs)
    local explicit = (cmdargs and cmdargs.args and cmdargs.args ~= "") and cmdargs.args or nil
    local dir = cache_logic.get_cache_dir()
    if explicit then
      local path = dir .. "/" .. explicit
      if vim.fn.filereadable(path) == 1 then
        vim.cmd("edit " .. vim.fn.fnameescape(path))
      else
        vim.notify("LazyAgentHistoryList: file not found: " .. path, vim.log.levels.ERROR)
      end
      return
    end
    cache_logic.open_history()
  end, { nargs = "?", desc = "Open a lazyagent history file (scratch logs). If no arg is provided, pick from UI." })

  -- User command to open conversation captures saved by LazyAgentOpenConversation.
  try_create_user_command("LazyAgentConversationList", function(cmdargs)
    local explicit = (cmdargs and cmdargs.args and cmdargs.args ~= "") and cmdargs.args or nil
    local dir = cache_logic.get_cache_dir()
    if explicit then
      local path = dir .. "/" .. explicit
      if vim.fn.filereadable(path) == 1 then
        vim.cmd("edit " .. vim.fn.fnameescape(path))
        vim.cmd("setlocal nowrap")
      else
        vim.notify("LazyAgentConversationList: file not found: " .. path, vim.log.levels.ERROR)
      end
      return
    end
    cache_logic.open_conversations()
  end, { nargs = "?", desc = "Open a lazyagent conversation capture. If no arg is provided, pick from UI." })

  -- Resume a conversation from a saved snapshot and preload it into a new session scratch buffer.
  try_create_user_command("LazyAgentResumeConversation", function(cmdargs)
    local explicit = (cmdargs and cmdargs.args and cmdargs.args ~= "") and cmdargs.args or nil
    session_logic.resume_conversation(explicit)
  end, { nargs = "?", desc = "Select a saved conversation log and start a session with it preloaded." })

  try_create_user_command("LazyAgentStack", function(cmdargs)
    local bufnr = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local has_content = false
    for _, line in ipairs(lines) do
      if line:match("%S") then
        has_content = true
        break
      end
    end

    if has_content then
      cache_logic.write_scratch_to_cache(bufnr)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
      vim.notify("LazyAgentStack: content stacked to history", vim.log.levels.INFO)
    else
      vim.notify("LazyAgentStack: buffer is empty", vim.log.levels.INFO)
    end
  end, { nargs = 0, desc = "Stack (save and clear) current scratch buffer content to history" })

  -- User command to open history logs saved by lazyagent (from cache).
  try_create_user_command("LazyAgentHistory", function(cmdargs)
    local explicit = (cmdargs and cmdargs.args and cmdargs.args ~= "") and cmdargs.args or nil
    local dir = cache_logic.get_cache_dir()
    if explicit then
      local path = dir .. "/" .. explicit
      if vim.fn.filereadable(path) == 1 then
        vim.cmd("edit " .. vim.fn.fnameescape(path))
      else
        vim.notify("LazyAgentHistory: file not found: " .. path, vim.log.levels.ERROR)
      end
      return
    end

    -- No explicit arg: compute the cache file for the current buffer (or its source if scratch).
    local bufnr = vim.api.nvim_get_current_buf()
    local src_buf = (vim.b[bufnr] and vim.b[bufnr].lazyagent_source_bufnr) or nil
    if src_buf and src_buf > 0 and vim.api.nvim_buf_is_valid(src_buf) then
      bufnr = src_buf
    end

    -- Try current branch/project history file first
    local filename = cache_logic.build_cache_filename(bufnr)
    local path = dir .. "/" .. filename
    if vim.fn.filereadable(path) == 1 then
      vim.cmd("edit " .. vim.fn.fnameescape(path))
      return
    end

    -- Fall back to choose the most recent matching cache file for this branch+project.
    local entries = cache_logic.list_cache_files()
    local prefix = cache_logic.build_cache_prefix(bufnr)
    for _, e in ipairs(entries) do
      if e.name:match("^" .. prefix .. ".*%.log$") then
        vim.cmd("edit " .. vim.fn.fnameescape(e.path))
        return
      end
    end

    vim.notify("LazyAgentHistory: no cache history found for current buffer", vim.log.levels.INFO)
  end, { nargs = "?", desc = "Open a lazyagent cache history file here." })

  -- Open a running agent's pane capture into a buffer for inspection.
  try_create_user_command("LazyAgentOpenConversation", function(cmdargs)
    local explicit = (cmdargs and cmdargs.args and cmdargs.args ~= "") and cmdargs.args or nil
    agent_logic.resolve_target_agent(explicit, nil, function(chosen)
      if not chosen or chosen == "" then return end

      local session = state.sessions[chosen]
      if not session or not session.pane_id or session.pane_id == "" then
        vim.notify("LazyAgentOpenConversation: no active session found for '" .. tostring(chosen) .. "'", vim.log.levels.ERROR)
        return
      end

      -- Reuse centralized capture implementation (session logic)
      session_logic.capture_and_save_session(chosen, true)
    end)
  end, { nargs = "?", desc = "Open the live pane capture for a running interactive agent in a buffer." })

  try_create_user_command("LazyAgentSummary", function(cmdargs)
    local action = (cmdargs and cmdargs.args and cmdargs.args ~= "") and cmdargs.args or nil
    summary_logic.pick(action)
  end, { nargs = "?", desc = "Open or copy a lazyagent summary file (action: open|copy, default asks)." })

  -- Attach nvim to an already-running tmux pane (e.g. after nvim restart).
  -- Usage: LazyAgentAttach [AgentName [%pane_id]]
  try_create_user_command("LazyAgentAttach", function(cmdargs)
    local args = vim.split((cmdargs and cmdargs.args or ""), "%s+", { trimempty = true })
    local agent = args[1] or nil
    local pane  = args[2] or nil
    session_logic.attach_session(agent, pane)
  end, {
    nargs = "*",
    desc = "Attach a running tmux pane to an agent session (usage: LazyAgentAttach [AgentName [pane_id]])",
    complete = function()
      return agent_logic.available_agents()
    end,
  })

  -- Register commands for each interactive agent
  if state.opts.interactive_agents then
    for _, name in ipairs(agent_logic.available_agents()) do
      local agent_opts = state.opts.interactive_agents[name]
      try_create_user_command(name, function(cmdargs)
        local explicit = (cmdargs and cmdargs.args and cmdargs.args ~= "") and cmdargs.args or nil
        if explicit then
          session_logic.start_interactive_session({
            agent_name = explicit,
            reuse = true,
            pane_size = agent_opts.pane_size,
            scratch_filetype = agent_opts.scratch_filetype,
            stay_hidden = false,
          })
          return
        end

        -- No explicit agent passed; use selection rules:
        agent_logic.resolve_target_agent(nil, name, function(chosen)
          if not chosen then return end
          session_logic.start_interactive_session({
            agent_name = chosen,
            reuse = true,
            pane_size = agent_opts.pane_size,
            scratch_filetype = agent_opts.scratch_filetype,
            stay_hidden = false,
          })
        end)
      end, {
          nargs = "?",
          desc = "Start interactive agent: " .. name,
        })
    end
  end
end

return M
