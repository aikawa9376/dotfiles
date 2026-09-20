local M = {}

-- Order is intentional: everyday actions first, diagnostics and lifecycle last.
-- Only commands whose argument is a session name get target = true.
local actions = {
  { "LazyAgentToggle", "Toggle agent input", "<Space>", target = true },
  { "LazyAgentACPModel", "Change model", "m", acp = true, target = true },
  { "LazyAgentACPFollow", "Follow Agent (tool / changed file)", "f", acp = true, target = true },
  { "LazyAgentACPPlanToggle", "Toggle Plan / Agent mode", "M", acp = true, target = true },
  { "LazyAgentACPMode", "Change mode / permissions", acp = true, target = true },
  { "LazyAgentACPConfig", "Agent configuration", acp = true, target = true },
  { "LazyAgentOpenConversation", "Open agent conversation", "l", target = true, active = true },
  { "LazyAgentInstant", "Instant query", "i", target = true },
  { "LazyAgentImage", "Attach image", target = true },
  { "LazyAgentACPCommands", "Slash commands", acp = true, target = true },
  { "LazyAgentACPSessions", "Browse provider sessions", acp = true, target = true },
  { "LazyAgentResumeConversation", "Resume saved conversation", target = true },
  { "LazyAgentConversationList", "Saved conversation logs" },
  { "LazyAgentHistoryList", "Input history" },
  { "LazyAgentSummary", "Conversation summaries" },
  { "LazyAgentACPRename", "Rename ACP session", acp = true, rename = true },
  { "LazyAgentACPNames", "Named ACP threads", acp = true },
  { "LazyAgentACPCockpit", "ACP cockpit", acp = true },
  { "LazyAgentACPReopen", "Reopen transcript window", acp = true, target = true },
  { "LazyAgentACPRawTranscript", "Raw transcript", acp = true, target = true },
  { "LazyAgentACPFullTranscript", "Fullscreen transcript", acp = true, target = true },
  { "LazyAgentACPTools", "Tool timeline", acp = true, target = true },
  { "LazyAgentACPResources", "Resources", acp = true, target = true },
  { "LazyAgentACPContext", "Context budget", acp = true, target = true },
  { "LazyAgentACPReview", "Tool / edit review", acp = true, target = true },
  { "LazyAgentReviews", "Saved code reviews" },
  { "LazyAgentTeamStatus", "Team status" },
  { "LazyAgentACPCapabilities", "Capabilities", acp = true, target = true },
  { "LazyAgentACPDoctor", "ACP diagnostics", acp = true, target = true },
  { "LazyAgentACPProtocolLog", "Protocol log", acp = true, target = true },
  { "LazyAgentACPReplay", "Replay event log", acp = true, target = true },
  { "LazyAgentRestore", "Restore session", target = true },
  { "LazyAgentDetach", "Detach session", target = true, active = true },
  { "LazyAgentRestart", "Restart session", target = true, active = true },
  { "LazyAgentClose", "Close session", target = true, active = true },
}

local function resolve_target(callback)
  local state = require("lazyagent.logic.state")
  local agent = require("lazyagent.logic.agent")
  local acp = require("lazyagent.logic.session.acp")
  -- Preserve the normal resolver's team lead priority, then buffer context,
  -- including non-ACP buffers (a nil ACP variable must not hide that context).
  local explicit = agent.team_lead_session()
    or vim.b.lazyagent_acp_agent or vim.b.lazyagent_agent
    or acp.preferred_session_agent(acp.current_editor_session_name())
  agent.resolve_target_agent(explicit, nil, function(chosen)
    if chosen then
      callback(require("lazyagent.logic.session.identity").resolve(state, chosen))
    end
  end)
end

function M.items(target)
  local state = require("lazyagent.logic.state")
  local session = state.sessions[target]
  local is_acp = require("lazyagent.logic.session.acp").is_acp_agent(target)
  local commands = vim.api.nvim_get_commands({ builtin = false })
  local items = {}
  for _, action in ipairs(actions) do
    if commands[action[1]] and (not action.acp or is_acp)
      and (not action.active or (session and session.pane_id)) then
      items[#items + 1] = action
    end
  end
  return items
end

local function execute(action, target)
  -- The rename command takes a title, not a session. Its API also accepts the
  -- captured target so opening the picker cannot change which thread is renamed.
  if action.rename then
    require("lazyagent.logic.session").rename_acp_session(nil, target)
    return
  end
  vim.api.nvim_cmd({ cmd = action[1], args = action.target and { target } or {} }, {})
end

-- Direct keys and the picker use exactly the same target and availability rules.
function M.run(command)
  resolve_target(function(target)
    for _, action in ipairs(M.items(target)) do
      if action[1] == command then
        execute(action, target)
        return
      end
    end
    vim.notify(command .. " is unavailable for " .. target, vim.log.levels.INFO)
  end)
end

function M.open()
  resolve_target(function(target)
    vim.ui.select(M.items(target), {
      prompt = "LazyAgent [" .. target .. "]:",
      kind = "lazyagent-menu",
      format_item = function(action)
        local key = action[3] and ("c<Space>" .. action[3]) or ""
        return string.format("%-18s %s  :%s", key, action[2], action[1])
      end,
    }, function(action)
      if action then execute(action, target) end
    end)
  end)
end

return M
