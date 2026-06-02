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

local function open_scratch_then_capture(agent_name)
  session_logic.start_interactive_session({ agent_name = agent_name, reuse = true })

  local attempts = 0
  local function try_capture()
    attempts = attempts + 1
    local bufnr = vim.api.nvim_get_current_buf()
    if is_scratch_buffer(bufnr) then
      local insert_mode = vim.fn.mode():sub(1, 1) == "i"
      if insert_mode then
        pcall(vim.cmd, "stopinsert")
      end
      image_paste.screenshot_into_buffer(bufnr)
      if insert_mode then
        pcall(vim.cmd, "startinsert")
      end
      return
    end

    if attempts < 50 then
      vim.defer_fn(try_capture, 80)
    else
      vim.notify("LazyAgentScreenShot: failed to open scratch buffer", vim.log.levels.ERROR)
    end
  end

  vim.defer_fn(try_capture, 80)
end

function M.register(create)
  create("LazyAgentScreenShot", function(cmdargs)
    local explicit = command.arg(cmdargs)
    local bufnr = vim.api.nvim_get_current_buf()

    if is_scratch_buffer(bufnr) and not explicit then
      image_paste.screenshot_into_buffer(bufnr)
      return
    end

    local target_agent = explicit or state.open_agent
    if target_agent and target_agent ~= "" then
      open_scratch_then_capture(target_agent)
      return
    end

    agent_logic.resolve_target_agent(nil, nil, function(chosen)
      if not chosen or chosen == "" then
        return
      end
      open_scratch_then_capture(chosen)
    end)
  end, {
    nargs = "?",
    desc = "Capture a screen region and insert it into LazyAgent scratch",
  })
end

return M
