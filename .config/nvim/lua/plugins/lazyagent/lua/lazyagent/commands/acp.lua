local M = {}

local agent_logic = require("lazyagent.logic.agent")
local command = require("lazyagent.commands.util")
local session_logic = require("lazyagent.logic.session")

local function available_acp_agents()
  return agent_logic.available_acp_agents()
end

local commands = {
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

function M.register(create)
  for _, spec in ipairs(commands) do
    local command_spec = spec
    create(command_spec.name, function(cmdargs)
      command_spec.handler(command.arg(cmdargs))
    end, {
      nargs = "?",
      desc = command_spec.desc,
      complete = available_acp_agents,
    })
  end
end

return M
