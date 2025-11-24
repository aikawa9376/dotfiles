-- logic/commands.lua
-- This module contains functions for registering user commands.
local M = {}

local state = require("logic.state")
local agent_logic = require("logic.agent")
local session_logic = require("logic.session")
local cache_logic = require("logic.cache")

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
    agent_logic.resolve_target_agent(explicit, nil, function(chosen)
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
  end, { nargs = "?", desc = "Toggle the floating agent input buffer (open/close)" })

  -- User command to open history logs saved by lazyagent (from cache).
  try_create_user_command("LazyAgentHistoryList", function(cmdargs)
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
    cache_logic.open_history()
  end, { nargs = "?", desc = "Open a lazyagent cache history file. If no arg is provided, pick from UI." })

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

    -- Try today's file first
    local filename_today = cache_logic.build_cache_filename(bufnr)
    local path_today = dir .. "/" .. filename_today
    if vim.fn.filereadable(path_today) == 1 then
      vim.cmd("edit " .. vim.fn.fnameescape(path_today))
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

  -- Register commands for each interactive agent
  if state.opts.interactive_agents then
    for name, agent_opts in pairs(state.opts.interactive_agents) do
      try_create_user_command(name, function(cmdargs)
        local explicit = (cmdargs and cmdargs.args and cmdargs.args ~= "") and cmdargs.args or nil
        if explicit then
          session_logic.start_interactive_session({
            agent_name = explicit,
            reuse = true,
            pane_size = agent_opts.pane_size,
            scratch_filetype = agent_opts.scratch_filetype,
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
