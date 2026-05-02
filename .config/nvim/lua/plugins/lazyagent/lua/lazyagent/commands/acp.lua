local M = {}

local agent_logic = require("lazyagent.logic.agent")
local acp_logic = require("lazyagent.logic.acp")
local command = require("lazyagent.commands.util")
local session_logic = require("lazyagent.logic.session")
local state = require("lazyagent.logic.state")

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

local commands = {
  {
    name = "LazyAgentACPSwitch",
    desc = "Switch ACP providers mid-conversation",
    handler = function(target_agent)
      session_logic.switch_acp_provider(nil, target_agent)
    end,
  },
  {
    name = "LazyAgentACPResumeConversation",
    desc = "Resume a saved ACP conversation with carryover restore",
    handler = function(target_agent)
      session_logic.resume_acp_conversation(target_agent)
    end,
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
}

local function has_active_acp_sessions()
  return #available_acp_agents() > 0
end

function M.refresh()
  if not create_command or not delete_command then
    return
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
          complete = available_acp_agents,
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
