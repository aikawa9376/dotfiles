-- logic/commands.lua
-- This module contains functions for registering user commands.
local M = {}

local state = require("lazyagent.logic.state")
local agent_logic = require("lazyagent.logic.agent")
local session_logic = require("lazyagent.logic.session")
local cache_logic = require("lazyagent.logic.cache")
local util = require("lazyagent.util")
local summary_logic = require("lazyagent.logic.summary")

-- Helper to create commands safely
local function try_create_user_command(name, fn, cmd_opts)
  pcall(function() vim.api.nvim_create_user_command(name, fn, cmd_opts) end)
end

local function available_acp_agents()
  return agent_logic.available_acp_agents()
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

  try_create_user_command("LazyAgent", function(cmdargs)
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

  try_create_user_command("LazyAgentACPConfig", function(cmdargs)
    local explicit = (cmdargs and cmdargs.args and cmdargs.args ~= "") and cmdargs.args or nil
    session_logic.pick_acp_config(explicit)
  end, {
      nargs = "?",
      desc = "Open ACP config picker for an ACP-enabled agent",
      complete = available_acp_agents,
    })

  try_create_user_command("LazyAgentACPModel", function(cmdargs)
    local explicit = (cmdargs and cmdargs.args and cmdargs.args ~= "") and cmdargs.args or nil
    session_logic.pick_acp_model(explicit)
  end, {
      nargs = "?",
      desc = "Open ACP model picker for an ACP-enabled agent",
      complete = available_acp_agents,
    })

  try_create_user_command("LazyAgentACPMode", function(cmdargs)
    local explicit = (cmdargs and cmdargs.args and cmdargs.args ~= "") and cmdargs.args or nil
    session_logic.pick_acp_mode(explicit)
  end, {
      nargs = "?",
      desc = "Open ACP mode picker for an ACP-enabled agent",
      complete = available_acp_agents,
    })

  try_create_user_command("LazyAgentACPReopen", function(cmdargs)
    local explicit = (cmdargs and cmdargs.args and cmdargs.args ~= "") and cmdargs.args or nil
    session_logic.reopen_acp_window(explicit)
  end, {
      nargs = "?",
      desc = "Reopen the ACP transcript window for an ACP-enabled agent",
      complete = available_acp_agents,
    })

  try_create_user_command("LazyAgentACPCommands", function(cmdargs)
    local explicit = (cmdargs and cmdargs.args and cmdargs.args ~= "") and cmdargs.args or nil
    session_logic.pick_acp_commands(explicit)
  end, {
      nargs = "?",
      desc = "Open ACP slash command palette for an ACP-enabled agent",
      complete = available_acp_agents,
    })

  try_create_user_command("LazyAgentACPTools", function(cmdargs)
    local explicit = (cmdargs and cmdargs.args and cmdargs.args ~= "") and cmdargs.args or nil
    session_logic.show_acp_tool_timeline(explicit)
  end, {
      nargs = "?",
      desc = "Open ACP tool call timeline for an ACP-enabled agent",
      complete = available_acp_agents,
    })

  try_create_user_command("LazyAgentACPResources", function(cmdargs)
    local explicit = (cmdargs and cmdargs.args and cmdargs.args ~= "") and cmdargs.args or nil
    session_logic.pick_acp_resources(explicit)
  end, {
      nargs = "?",
      desc = "Open ACP resource browser for an ACP-enabled agent",
      complete = available_acp_agents,
    })

  try_create_user_command("LazyAgentACPCapabilities", function(cmdargs)
    local explicit = (cmdargs and cmdargs.args and cmdargs.args ~= "") and cmdargs.args or nil
    session_logic.show_acp_capabilities(explicit)
  end, {
      nargs = "?",
      desc = "Open ACP capability summary for an ACP-enabled agent",
      complete = available_acp_agents,
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
        util.open_in_normal_win(path)
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
        util.open_in_normal_win(path)
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
        util.open_in_normal_win(path)
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
      util.open_in_normal_win(path)
      return
    end

    -- Fall back to choose the most recent matching cache file for this branch+project.
    local entries = cache_logic.list_cache_files()
    local prefix = cache_logic.build_cache_prefix(bufnr)
    for _, e in ipairs(entries) do
      if e.name:match("^" .. prefix .. ".*%.log$") then
        util.open_in_normal_win(e.path)
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

  -- Toggle hooks flags at runtime
  -- Usage: LazyAgentHooks [flag] (no arg = show current status)
  -- Flags: open_on_edit | quickfix_on_edit | notify_on_done | git_checkpoint_on_done
  try_create_user_command("LazyAgentHooks", function(cmdargs)
    local flag = cmdargs and cmdargs.args ~= "" and cmdargs.args or nil
    local hopts = state.opts and state.opts.hooks
    if not hopts then
      vim.notify("LazyAgentHooks: hooks not configured", vim.log.levels.WARN)
      return
    end
    if flag then
      if hopts[flag] == nil then
        vim.notify("LazyAgentHooks: unknown flag '" .. flag .. "'", vim.log.levels.WARN)
        return
      end
      hopts[flag] = not hopts[flag]
      vim.notify("LazyAgentHooks: " .. flag .. " = " .. tostring(hopts[flag]), vim.log.levels.INFO)
    else
      local lines = {}
      for k, v in pairs(hopts) do
        table.insert(lines, string.format("  %-30s %s", k, tostring(v)))
      end
      table.sort(lines)
      vim.notify("LazyAgentHooks:\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
    end
  end, {
    nargs = "?",
    desc = "Toggle or show lazyagent hook flags (open_on_edit, quickfix_on_edit, notify_on_done, git_checkpoint_on_done)",
    complete = function()
      local hopts = state.opts and state.opts.hooks or {}
      local keys = {}
      for k in pairs(hopts) do table.insert(keys, k) end
      return keys
    end,
  })

  -- Show web UI URL as QR code in a float window (requires qrencode)
  try_create_user_command("LazyAgentQR", function()
    -- Resolve LAN IP
    local ip = vim.fn.system("ip route get 1.1.1.1 2>/dev/null | awk '/src/{print $7}'"):gsub("%s+$", "")
    if ip == "" then
      ip = vim.fn.system("hostname -I 2>/dev/null | awk '{print $1}'"):gsub("%s+$", "")
    end
    if ip == "" then ip = "127.0.0.1" end

    -- Resolve port from MCP URL
    local mcp_url = state.opts and state.opts._mcp_url or ""
    local port = mcp_url:match(":(%d+)/")
    if not port then
      vim.notify("LazyAgentQR: MCP server not ready yet", vim.log.levels.WARN)
      return
    end

    local url = "http://" .. ip .. ":" .. port .. "/"

    -- Generate QR via qrencode
    if vim.fn.executable("qrencode") == 0 then
      vim.notify("LazyAgentQR: qrencode not found (brew/apt install qrencode)", vim.log.levels.ERROR)
      return
    end
    local qr_raw = vim.fn.system("qrencode -t UTF8 -m 1 -o - " .. vim.fn.shellescape(url))
    if vim.v.shell_error ~= 0 or qr_raw == "" then
      vim.notify("LazyAgentQR: qrencode failed", vim.log.levels.ERROR)
      return
    end

    local qr_lines = vim.split(qr_raw, "\n", { plain = true })
    if qr_lines[#qr_lines] == "" then table.remove(qr_lines) end

    -- Measure QR width (all QR lines should be the same)
    local qr_w = 0
    for _, l in ipairs(qr_lines) do qr_w = math.max(qr_w, vim.fn.strdisplaywidth(l)) end

    -- Helper: center a string within qr_w
    local function center(s)
      local sw = vim.fn.strdisplaywidth(s)
      local lpad = math.max(0, math.floor((qr_w - sw) / 2))
      local rpad = math.max(0, qr_w - sw - lpad)
      return string.rep(" ", lpad) .. s .. string.rep(" ", rpad)
    end

    local hint1 = "To enable mic on Android Chrome:"
    local hint2 = "chrome://flags/#unsafely-treat-insecure-origin-as-secure"
    local hint3 = "Add the URL above, then Relaunch"

    -- Expand qr_w if hints are wider
    for _, s in ipairs({ url, hint1, hint2, hint3 }) do
      qr_w = math.max(qr_w, vim.fn.strdisplaywidth(s))
    end

    local lines = {}
    table.insert(lines, center(url))
    table.insert(lines, "")
    for _, l in ipairs(qr_lines) do
      local lw = vim.fn.strdisplaywidth(l)
      local lpad = math.max(0, math.floor((qr_w - lw) / 2))
      table.insert(lines, string.rep(" ", lpad) .. l)
    end
    table.insert(lines, "")
    table.insert(lines, center(hint1))
    table.insert(lines, center(hint2))
    table.insert(lines, center(hint3))

    local width  = qr_w
    local height = #lines

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden  = "wipe"

    local ui = vim.api.nvim_list_uis()[1] or { width = 80, height = 24 }
    local win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width    = width,
      height   = height,
      row      = math.floor((ui.height - height) / 2),
      col      = math.floor((ui.width  - width)  / 2),
      style    = "minimal",
      border   = "rounded",
      title    = " LazyAgent Web UI ",
      title_pos = "center",
    })
    vim.wo[win].wrap = false

    -- Close on any key
    vim.keymap.set("n", "q",      "<cmd>close<cr>", { buffer = buf, silent = true })
    vim.keymap.set("n", "<Esc>",  "<cmd>close<cr>", { buffer = buf, silent = true })
    vim.keymap.set("n", "<CR>",   "<cmd>close<cr>", { buffer = buf, silent = true })
  end, { nargs = 0, desc = "Show web UI QR code in a float window" })


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
