local M = {}

local agent_logic = require("lazyagent.logic.agent")
local cache_logic = require("lazyagent.logic.cache")
local command = require("lazyagent.commands.util")
local session_logic = require("lazyagent.logic.session")
local state = require("lazyagent.logic.state")
local summary_logic = require("lazyagent.logic.summary")
local util = require("lazyagent.util")

local function open_cache_file(command_name, filename, configure, dir)
  dir = dir or cache_logic.get_cache_dir()
  local path = dir .. "/" .. filename
  if vim.fn.filereadable(path) == 1 then
    util.open_in_normal_win(path)
    if configure then
      configure()
    end
    return true
  end

  vim.notify(command_name .. ": file not found: " .. path, vim.log.levels.ERROR)
  return false
end

function M.register(create)
  create("LazyAgentHistoryList", function(cmdargs)
    local explicit = command.arg(cmdargs)
    if explicit then
      open_cache_file("LazyAgentHistoryList", explicit, nil, cache_logic.get_history_dir())
      return
    end
    cache_logic.open_history()
  end, { nargs = "?", desc = "Open a lazyagent history file" })

  create("LazyAgentConversationList", function(cmdargs)
    local explicit = command.arg(cmdargs)
    if explicit then
      open_cache_file("LazyAgentConversationList", explicit, function()
        vim.cmd("setlocal nowrap")
      end, cache_logic.get_conversation_dir())
      return
    end
    cache_logic.open_conversations()
  end, { nargs = "?", desc = "Open a lazyagent conversation capture" })

  create("LazyAgentConversation", function(cmdargs)
    local args = vim.split((cmdargs and cmdargs.args or ""), "%s+", { trimempty = true })
    session_logic.save_conversation_checkpoint(unpack(args))
  end, { nargs = "*", desc = "Save the active ACP conversation and clear its live transcript buffer" })

  create("LazyAgentResumeConversation", function(cmdargs)
    session_logic.resume_conversation(command.arg(cmdargs))
  end, { nargs = "?", desc = "Select a saved conversation log and start a session with it preloaded" })

  create("LazyAgentStack", function()
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
  end, { nargs = 0, desc = "Stack current scratch buffer content to history" })

  create("LazyAgentHistory", function(cmdargs)
    local explicit = command.arg(cmdargs)
    local dir = cache_logic.get_history_dir()
    if explicit then
      open_cache_file("LazyAgentHistory", explicit, nil, dir)
      return
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local src_buf = (vim.b[bufnr] and vim.b[bufnr].lazyagent_source_bufnr) or nil
    if src_buf and src_buf > 0 and vim.api.nvim_buf_is_valid(src_buf) then
      bufnr = src_buf
    end

    local filename = cache_logic.build_cache_filename(bufnr)
    local path = dir .. "/" .. filename
    if vim.fn.filereadable(path) == 1 then
      util.open_in_normal_win(path)
      return
    end

    local entries = cache_logic.list_cache_files()
    local prefix = cache_logic.build_cache_prefix(bufnr)
    local prefix_lower = prefix:lower()
    for _, entry in ipairs(entries) do
      if (entry.name or ""):lower():sub(1, #prefix_lower) == prefix_lower then
        util.open_in_normal_win(entry.path)
        return
      end
    end

    vim.notify("LazyAgentHistory: no cache history found for current buffer", vim.log.levels.INFO)
  end, { nargs = "?", desc = "Open a lazyagent cache history file here" })

  create("LazyAgentOpenConversation", function(cmdargs)
    local explicit = command.arg(cmdargs)
    agent_logic.resolve_target_agent(explicit, nil, function(chosen)
      if not chosen or chosen == "" then return end

      local session = state.sessions[chosen]
      if not session or not session.pane_id or session.pane_id == "" then
        vim.notify("LazyAgentOpenConversation: no active session found for '" .. tostring(chosen) .. "'", vim.log.levels.ERROR)
        return
      end

      session_logic.capture_and_save_session(chosen, true)
    end)
  end, { nargs = "?", desc = "Open the live pane capture for a running interactive agent" })

  create("LazyAgentSummary", function(cmdargs)
    summary_logic.pick(command.arg(cmdargs))
  end, { nargs = "?", desc = "Open or copy a lazyagent summary file" })
end

return M
