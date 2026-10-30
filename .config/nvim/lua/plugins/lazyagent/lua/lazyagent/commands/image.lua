local M = {}

local command = require("lazyagent.commands.util")
local agent_logic = require("lazyagent.logic.agent")
local image_paste = require("lazyagent.logic.image_paste")
local session_logic = require("lazyagent.logic.session")
local state = require("lazyagent.logic.state")

local function is_scratch_buffer(bufnr)
  return bufnr
    and vim.api.nvim_buf_is_valid(bufnr)
    and vim.b[bufnr]
    and vim.b[bufnr].lazyagent_is_scratch == true
end

local function open_scratch_then(agent_name, action, command_name)
  session_logic.start_interactive_session({ agent_name = agent_name, reuse = true })

  local attempts = 0
  local function try_action()
    attempts = attempts + 1
    local bufnr = vim.api.nvim_get_current_buf()
    if is_scratch_buffer(bufnr) then
      action(bufnr)
      return
    end

    if attempts < 50 then
      vim.defer_fn(try_action, 80)
    else
      vim.notify(command_name .. ": failed to open scratch buffer", vim.log.levels.ERROR)
    end
  end

  vim.defer_fn(try_action, 80)
end

local function run_for_scratch_or_agent(cmdargs, action, command_name)
  local explicit = command.arg(cmdargs)
  local bufnr = vim.api.nvim_get_current_buf()

  if is_scratch_buffer(bufnr) and not explicit then
    action(bufnr)
    return
  end

  local target_agent = explicit or state.open_agent
  if target_agent and target_agent ~= "" then
    open_scratch_then(target_agent, action, command_name)
    return
  end

  agent_logic.resolve_target_agent(nil, nil, function(chosen)
    if not chosen or chosen == "" then
      return
    end
    open_scratch_then(chosen, action, command_name)
  end)
end

function M.register(create)
  create("LazyAgentImage", function(cmdargs)
    run_for_scratch_or_agent(cmdargs, function(bufnr)
      image_paste.choose_into_buffer(bufnr)
    end, "LazyAgentImage")
  end, {
    nargs = "?",
    desc = "Choose and attach an image to LazyAgent scratch",
  })

  create("LazyAgentScreenShot", function(cmdargs)
    local args = vim.split(cmdargs.args or "", "%s+", { trimempty = true })
    local agent, delay
    if #args > 2 then
      vim.notify("Usage: LazyAgentScreenShot [seconds] [agent]", vim.log.levels.ERROR)
      return
    elseif #args == 2 then
      if tonumber(args[1]) then
        delay, agent = args[1], args[2]
      else
        agent, delay = args[1], args[2]
      end
    elseif #args == 1 then
      if tonumber(args[1]) then delay = args[1] else agent = args[1] end
    end
    local seconds = image_paste.screenshot_delay_seconds(delay)
    if seconds == nil then return end
    run_for_scratch_or_agent({ args = agent or "" }, function(bufnr)
      image_paste.screenshot_into_buffer(bufnr, seconds)
    end, "LazyAgentScreenShot")
  end, {
    nargs = "*",
    desc = "Capture a screen region into scratch after optional seconds: [seconds] [agent]",
  })
end

return M
