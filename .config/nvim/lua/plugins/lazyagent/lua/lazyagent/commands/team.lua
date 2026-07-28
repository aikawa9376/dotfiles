local M = {}

local runtime = require("lazyagent.teams.runtime")

local function notify_error(err)
  vim.notify("LazyAgentTeam: " .. tostring(err), vim.log.levels.ERROR)
end

local function start(request)
  local result, err = runtime.start(request)
  if not result then
    notify_error(err)
    return
  end
  if result.selecting then return end
  local config = result.config or (result.config_path and result) or nil
  local name = config and config.name or (runtime.status().name or "team")
  vim.notify("LazyAgentTeam: request sent to " .. name, vim.log.levels.INFO)
end

function M.register(create)
  create("LazyAgentTeam", function(cmdargs)
    local request = cmdargs and cmdargs.args or ""
    if vim.trim(request) ~= "" then
      start(request)
      return
    end
    vim.ui.input({ prompt = "Team request: " }, function(input)
      if input and vim.trim(input) ~= "" then
        start(input)
      end
    end)
  end, {
    nargs = "*",
    desc = "Send a request through the project LazyAgent team",
  })

  create("LazyAgentTeamStatus", function()
    local status = runtime.status()
    if not status.active then
      local message = "LazyAgentTeam: no active team"
      if status.pending then
        message = "LazyAgentTeam: " .. tostring(status.name or "team") .. " is starting"
      end
      vim.notify(message, vim.log.levels.INFO)
      return
    end
    local lines = {
      string.format("%s (lead: %s)", status.name, status.lead),
      status.config_path,
    }
    for _, member in ipairs(status.members) do
      lines[#lines + 1] = string.format(
        "- %s · %s · %s · %s",
        member.id,
        member.role,
        member.agent,
        member.status
      )
    end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "LazyAgent Team" })
  end, {
    desc = "Show active LazyAgent team status",
  })

  create("LazyAgentTeamSelect", function(cmdargs)
    local requested = cmdargs and cmdargs.args ~= "" and cmdargs.args or nil
    runtime.select_team(requested, {}, function(team_id, err, config)
      if not team_id then
        if err ~= "team selection cancelled" then notify_error(err) end
        return
      end
      vim.notify(
        string.format("LazyAgentTeam: selected %s · %s", team_id, config and config.name or team_id),
        vim.log.levels.INFO
      )
    end)
  end, {
    nargs = "?",
    complete = function() return runtime.team_names() end,
    desc = "Select the project LazyAgent team used for the next request",
  })

  create("LazyAgentTeamStop", function()
    if runtime.stop() then
      vim.notify("LazyAgentTeam: stopped", vim.log.levels.INFO)
    else
      vim.notify("LazyAgentTeam: no active team", vim.log.levels.INFO)
    end
  end, {
    desc = "Stop all sessions owned by the active LazyAgent team",
  })
end

return M
