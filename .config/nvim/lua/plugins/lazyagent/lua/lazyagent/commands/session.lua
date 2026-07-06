local M = {}

local agent_logic = require("lazyagent.logic.agent")
local session_logic = require("lazyagent.logic.session")
local command = require("lazyagent.commands.util")
local state = require("lazyagent.logic.state")

local function available_agents()
  return agent_logic.available_agents()
end

function M.register(create)
  create("LazyAgentScratch", function(cmdargs)
    local explicit = command.arg(cmdargs)
    agent_logic.resolve_target_agent(explicit, nil, function(chosen)
      if not chosen then return end
      session_logic.start_interactive_session({ agent_name = chosen, reuse = true })
    end)
  end, { nargs = "?", desc = "Open a scratch buffer for sending instructions to AI agent" })

  create("LazyAgentClose", function(cmdargs)
    local explicit = command.arg(cmdargs)
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
  end, { nargs = "?", desc = "Close an agent session by name" })

  local function toggle_agent(cmdargs)
    local explicit = command.arg(cmdargs)
    session_logic.toggle_session(explicit, { force_toggle_ui = cmdargs and cmdargs.bang == true })
  end

  create("LazyAgentToggle", toggle_agent, {
    nargs = "?",
    bang = true,
    desc = "Toggle the agent input buffer",
    complete = available_agents,
  })
  create("LazyAgent", toggle_agent, {
    nargs = "?",
    bang = true,
    desc = "Toggle the agent input buffer",
    complete = available_agents,
  })

  create("LazyAgentInstant", function(cmdargs)
    session_logic.open_instant(command.arg(cmdargs))
  end, {
    nargs = "?",
    desc = "Open an instant query window for an agent",
    complete = available_agents,
  })

  create("LazyAgentRestart", function(cmdargs)
    session_logic.restart_session(command.arg(cmdargs))
  end, {
    nargs = "?",
    desc = "Restart an agent session",
    complete = available_agents,
  })

  create("LazyAgentRestore", function(cmdargs)
    local explicit = command.arg(cmdargs)
    agent_logic.resolve_target_agent(explicit, nil, function(chosen)
      if not chosen then return end
      session_logic.start_interactive_session({ agent_name = chosen, reuse = true, resume = true })
    end)
  end, {
    nargs = "?",
    desc = "Restore a persisted agent session even if resume is disabled",
    complete = available_agents,
  })

  create("LazyAgentDetach", function(cmdargs)
    session_logic.detach_session(command.arg(cmdargs))
  end, {
    nargs = "?",
    desc = "Detach and persist an agent session",
    complete = available_agents,
  })

  create("LazyAgentAttach", function(cmdargs)
    local args = vim.split((cmdargs and cmdargs.args or ""), "%s+", { trimempty = true })
    session_logic.attach_session(args[1] or nil, args[2] or nil)
  end, {
    nargs = "*",
    desc = "Attach a running tmux pane to an agent session",
    complete = available_agents,
  })

  if state.opts.interactive_agents then
    for _, name in ipairs(agent_logic.available_agents()) do
      local command_name = name
      local command_agent_opts = state.opts.interactive_agents[command_name]
      create(command_name, function(cmdargs)
        local explicit = command.arg(cmdargs)
        if explicit then
          session_logic.start_interactive_session({
            agent_name = explicit,
            reuse = true,
            pane_size = command_agent_opts.pane_size,
            scratch_filetype = command_agent_opts.scratch_filetype,
            stay_hidden = false,
          })
          return
        end

        agent_logic.resolve_target_agent(nil, command_name, function(chosen)
          if not chosen then return end
          session_logic.start_interactive_session({
            agent_name = chosen,
            reuse = true,
            pane_size = command_agent_opts.pane_size,
            scratch_filetype = command_agent_opts.scratch_filetype,
            stay_hidden = false,
          })
        end)
      end, {
        nargs = "?",
        desc = "Start interactive agent: " .. command_name,
      })
    end
  end
end

return M
