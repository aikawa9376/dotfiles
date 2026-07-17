local M = {}

local acp_logic = require("lazyagent.logic.acp")
local command = require("lazyagent.commands.util")
local session_logic = require("lazyagent.logic.session")
local state = require("lazyagent.logic.state")
local cache_logic = require("lazyagent.logic.cache")

local create_command
local delete_command
local registered = {}
local autocmd_initialized = false

local function available_acp_agents()
  local active = {}
  for name, session in pairs(state.sessions or {}) do
    if type(session) == "table"
      and session.pane_id and session.pane_id ~= ""
      and acp_logic.is_acp_backend(session.backend)
    then
      active[#active + 1] = name
    end
  end
  table.sort(active)
  return active
end

local function available_switch_targets()
  return session_logic.available_acp_switch_targets()
end

local function blob_gc()
  return require("lazyagent.acp.blob_gc").new({ base_dir = cache_logic.get_cache_dir() .. "/acp" })
end

local function blob_gc_scan()
  local gc = blob_gc()
  local report, err = gc:scan()
  if not report then
    vim.notify("LazyAgent ACP blob GC scan failed: " .. vim.inspect(err), vim.log.levels.ERROR)
    return nil
  end
  gc:open_report(report)
  return gc, report
end

local always_commands = {
  {
    name = "LazyAgentACPCockpit",
    desc = "Open the project-grouped LazyAgent ACP Session Cockpit",
    handler = session_logic.open_acp_cockpit,
  },
  {
    name = "LazyAgentACPRegistry",
    desc = "Browse and register agents from the official ACP Registry",
    handler = function() require("lazyagent.acp.registry").browse() end,
  },
  {
    name = "LazyAgentACPPermissionAudit",
    desc = "Open the LazyAgent ACP permission audit log",
    handler = function() require("lazyagent.acp.permission_store").open_audit() end,
  },
  {
    name = "LazyAgentACPThreads",
    desc = "Browse persisted LazyAgent ACP threads",
    handler = session_logic.pick_acp_threads,
  },
  {
    name = "LazyAgentACPBlobGCDryRun",
    desc = "Report unreferenced ACP blobs without deleting them",
    handler = blob_gc_scan,
  },
  {
    name = "LazyAgentACPBlobGC",
    desc = "Review and delete confirmed unreferenced ACP blobs",
    handler = function()
      local gc, report = blob_gc_scan()
      if not gc then return end
      if report.blocked then
        vim.notify("LazyAgent ACP blob GC is blocked; see the dry-run report", vim.log.levels.WARN)
        return
      end
      if report.eligible_count == 0 then
        vim.notify("LazyAgent ACP blob GC: no eligible orphaned blobs", vim.log.levels.INFO)
        return
      end
      local label = string.format(
        "Delete %d unreferenced blob(s), %s",
        report.eligible_count,
        require("lazyagent.acp.blob_gc").format_bytes(report.eligible_bytes)
      )
      vim.ui.select({ "Cancel", label }, { prompt = "Confirm LazyAgent ACP blob GC:" }, function(choice)
        if choice ~= label then return end
        local confirmed = {}
        for _, candidate in ipairs(report.candidates) do
          if candidate.eligible then confirmed[#confirmed + 1] = candidate.hash end
        end
        local result, sweep_err = gc:sweep(confirmed)
        if not result then
          vim.notify("LazyAgent ACP blob GC stopped safely: " .. vim.inspect(sweep_err), vim.log.levels.ERROR)
          return
        end
        vim.notify(string.format(
          "LazyAgent ACP blob GC deleted %d blob(s), %s; skipped %d",
          result.deleted_count,
          require("lazyagent.acp.blob_gc").format_bytes(result.deleted_bytes),
          result.skipped_count
        ), #result.failures > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
      end)
    end,
  },
  {
    name = "LazyAgentACPThreadNew",
    desc = "Create a new LazyAgent ACP thread",
    handler = session_logic.new_acp_thread,
    complete = function()
      return require("lazyagent.logic.agent").available_acp_agents()
    end,
  },
  {
    name = "LazyAgentACPWorktreeNew",
    desc = "Create an opt-in isolated git worktree ACP thread",
    handler = session_logic.new_acp_worktree_thread,
    complete = function() return require("lazyagent.logic.agent").available_acp_agents() end,
  },
  {
    name = "LazyAgentACPWorktreeCleanup",
    desc = "Remove a stopped clean managed ACP worktree",
    handler = session_logic.cleanup_acp_worktree,
    nargs = 1,
  },
  {
    name = "LazyAgentACPThreadOpen",
    desc = "Open a LazyAgent ACP thread UUID",
    handler = session_logic.open_acp_thread,
    nargs = 1,
  },
  {
    name = "LazyAgentACPChanges",
    desc = "Review persisted LazyAgent ACP file changes",
    handler = session_logic.show_acp_thread_changes,
  },
  {
    name = "LazyAgentACPRestart",
    desc = "Restart Neovim and rehydrate the current ACP session",
    handler = function(target_agent)
      session_logic.restart_acp_session(target_agent)
    end,
    complete = available_acp_agents,
  },
  {
    name = "LazyAgentACPMobileStart",
    desc = "Start ACP mobile web UI server",
    handler = function()
      require("lazyagent.acp.mobile").notify_url()
    end,
  },
  {
    name = "LazyAgentACPMobileStop",
    desc = "Stop ACP mobile web UI server",
    handler = function()
      require("lazyagent.acp.mobile").stop()
      vim.notify("[lazyagent ACP mobile] stopped", vim.log.levels.INFO)
    end,
  },
  {
    name = "LazyAgentACPMobileQR",
    desc = "Show ACP mobile web UI QR code",
    handler = function()
      require("lazyagent.acp.mobile").show_qr()
    end,
  },
  {
    name = "LazyAgentACPRestoreRestartState",
    desc = "Restore ACP state after an internal restart",
    handler = function(bundle_path)
      session_logic.restore_acp_restart_state(bundle_path)
    end,
    nargs = 1,
    complete = "file",
  },
  {
    name = "LazyAgentACPQuickfixPopup",
    desc = "Show the LazyAgent ACP quickfix note for the current line",
    handler = function()
      require("lazyagent.acp.qf_annotations").show_at_cursor()
    end,
  },
  {
    name = "LazyAgentACPQuickfixRefresh",
    desc = "Refresh LazyAgent ACP quickfix line notes",
    handler = function()
      require("lazyagent.acp.qf_annotations").refresh()
    end,
  },
  {
    name = "LazyAgentACPQuickfixClear",
    desc = "Clear LazyAgent ACP quickfix line notes",
    handler = function()
      require("lazyagent.acp.qf_annotations").clear()
    end,
  },
}

local commands = {
  {
    name = "LazyAgentACPSwitch",
    desc = "Switch ACP providers mid-conversation",
    handler = function(target_agent)
      session_logic.switch_acp_provider(nil, target_agent)
    end,
    complete = available_switch_targets,
  },
  {
    name = "LazyAgentACPResumeConversation",
    desc = "Resume a saved ACP conversation with carryover restore",
    handler = function(target_agent)
      session_logic.resume_acp_conversation(target_agent)
    end,
  },
  {
    name = "LazyAgentACPSessions",
    desc = "Browse native ACP provider sessions",
    handler = session_logic.pick_acp_sessions,
  },
  {
    name = "LazyAgentACPConfig",
    desc = "Open ACP config picker for an ACP-enabled agent",
    handler = session_logic.pick_acp_config,
  },
  {
    name = "LazyAgentACPModel",
    desc = "Open ACP model picker for an ACP-enabled agent",
    handler = session_logic.pick_acp_model,
  },
  {
    name = "LazyAgentACPMode",
    desc = "Open ACP mode picker for an ACP-enabled agent",
    handler = session_logic.pick_acp_mode,
  },
  {
    name = "LazyAgentACPReopen",
    desc = "Reopen the ACP transcript window for an ACP-enabled agent",
    handler = session_logic.reopen_acp_window,
  },
  {
    name = "LazyAgentACPRawTranscript",
    desc = "Open the uncompacted ACP transcript for an ACP-enabled agent",
    handler = session_logic.open_raw_acp_transcript,
  },
  {
    name = "LazyAgentACPFullTranscript",
    desc = "Open the uncompacted ACP transcript in a fullscreen tab",
    handler = session_logic.open_full_acp_transcript,
  },
  {
    name = "LazyAgentACPCommands",
    desc = "Open ACP slash command palette for an ACP-enabled agent",
    handler = session_logic.pick_acp_commands,
  },
  {
    name = "LazyAgentACPTools",
    desc = "Open ACP tool call timeline for an ACP-enabled agent",
    handler = session_logic.show_acp_tool_timeline,
  },
  {
    name = "LazyAgentACPResources",
    desc = "Open ACP resource browser for an ACP-enabled agent",
    handler = session_logic.pick_acp_resources,
  },
  {
    name = "LazyAgentACPCapabilities",
    desc = "Open ACP capability summary for an ACP-enabled agent",
    handler = session_logic.show_acp_capabilities,
  },
  {
    name = "LazyAgentACPDoctor",
    desc = "Open ACP health diagnostics for an ACP-enabled agent",
    handler = session_logic.show_acp_doctor,
  },
  {
    name = "LazyAgentACPProtocolLog",
    desc = "Open the redacted ACP protocol flight recorder",
    handler = session_logic.show_acp_protocol_log,
  },
  {
    name = "LazyAgentACPReplay",
    desc = "Replay transcript and runtime state from the ACP event log",
    handler = session_logic.show_acp_replay,
  },
  {
    name = "LazyAgentACPContext",
    desc = "Open ACP context budget details for an ACP-enabled agent",
    handler = session_logic.show_acp_context_budget,
  },
  {
    name = "LazyAgentACPReview",
    desc = "Open ACP tool and edit review for an ACP-enabled agent",
    handler = session_logic.show_acp_tool_review,
  },
  {
    name = "LazyAgentACPFollow",
    desc = "Toggle following the current ACP tool location or changed file",
    handler = session_logic.toggle_acp_follow,
  },
}

local function has_active_acp_sessions()
  return #available_acp_agents() > 0
end

function M.refresh()
  if not create_command or not delete_command then
    return
  end

  for _, spec in ipairs(always_commands) do
    if not registered[spec.name] then
      local command_spec = spec
      create_command(command_spec.name, function(cmdargs)
        command_spec.handler(command.arg(cmdargs))
      end, {
        nargs = command_spec.nargs or "?",
        desc = command_spec.desc,
        complete = command_spec.complete,
      })
      registered[command_spec.name] = true
    end
  end

  if has_active_acp_sessions() then
    for _, spec in ipairs(commands) do
      if not registered[spec.name] then
        local command_spec = spec
        create_command(command_spec.name, function(cmdargs)
          command_spec.handler(command.arg(cmdargs))
        end, {
          nargs = "?",
          desc = command_spec.desc,
          complete = command_spec.complete or available_acp_agents,
        })
        registered[command_spec.name] = true
      end
    end
    return
  end

  for _, spec in ipairs(commands) do
    if registered[spec.name] then
      delete_command(spec.name)
      registered[spec.name] = nil
    end
  end
end

local function ensure_autocmds()
  if autocmd_initialized then
    return
  end
  autocmd_initialized = true

  local group = vim.api.nvim_create_augroup("LazyAgentACPCommands", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = {
      "LazyAgentSessionStarted",
      "LazyAgentSessionStopped",
    },
    callback = function()
      M.refresh()
    end,
  })
end

function M.register(create, delete)
  create_command = create
  delete_command = delete
  ensure_autocmds()
  M.refresh()
end

return M
