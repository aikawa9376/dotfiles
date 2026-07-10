local M = {}

local state = require("lazyagent.logic.state")

local option_names = {
  "@agent_kind",
  "@agent_name",
  "@agent_status",
  "@agent_status_at",
  "@agent_status_ttl",
  "@agent_status_message",
  "@agent_status_pid",
  "@agent_status_owner",
}

local initialized = false

local function enclosing_tmux_pane()
  local pane = tostring(vim.env.TMUX_PANE or "")
  if pane:match("^%%%d+$") then
    return pane
  end
  return nil
end

local function run_tmux_commands(commands)
  if #commands == 0 or vim.fn.executable("tmux") ~= 1 then
    return false
  end

  local argv = { "tmux" }
  for index, command in ipairs(commands) do
    if index > 1 then
      argv[#argv + 1] = ";"
    end
    vim.list_extend(argv, command)
  end

  local ok, job = pcall(vim.fn.jobstart, argv, { detach = true })
  return ok and type(job) == "number" and job > 0
end

local function clear_options(pane)
  local commands = {}
  for _, name in ipairs(option_names) do
    commands[#commands + 1] = { "set-option", "-upt", pane, name }
  end
  return run_tmux_commands(commands)
end

local function hosted_sessions()
  local sessions = {}
  for name, session in pairs(state.sessions or {}) do
    if session and session.backend == "buffer_acp" then
      sessions[#sessions + 1] = { name = name, session = session }
    end
  end
  table.sort(sessions, function(left, right)
    return tostring(left.name) < tostring(right.name)
  end)
  return sessions
end

local function aggregate_status(sessions)
  local selected_status = "idle"
  local selected_message = "Ready"
  local rank = { idle = 1, thinking = 2, waiting = 3 }
  local selected_rank = 0

  for _, item in ipairs(sessions) do
    local session = item.session
    local status = tostring(session.agent_status or "idle"):lower()
    if session.monitor_timer then
      status = "thinking"
    end
    if not rank[status] then
      status = "idle"
    end
    if rank[status] > selected_rank then
      selected_rank = rank[status]
      selected_status = status == "thinking" and "working" or (status == "waiting" and "blocked" or "idle")
      selected_message = tostring(session.agent_status_message or "")
    end
  end

  return selected_status, selected_message
end

function M.sync()
  local pane = enclosing_tmux_pane()
  if not pane then
    return false
  end

  local sessions = hosted_sessions()
  if #sessions == 0 then
    return clear_options(pane)
  end

  local names = {}
  for _, item in ipairs(sessions) do
    names[#names + 1] = tostring(item.name)
  end

  local status, message = aggregate_status(sessions)
  local kind = #names == 1 and names[1]:lower() or "lazyagent"
  local label = #names == 1 and (names[1] .. " (ACP)") or ("LazyAgent: " .. table.concat(names, "+"))
  local values = {
    ["@agent_kind"] = kind,
    ["@agent_name"] = label,
    ["@agent_status"] = status,
    ["@agent_status_at"] = tostring(os.time()),
    ["@agent_status_ttl"] = "0",
    ["@agent_status_message"] = message,
    ["@agent_status_pid"] = tostring(vim.fn.getpid()),
    ["@agent_status_owner"] = "lazyagent",
  }

  local commands = {}
  for _, name in ipairs(option_names) do
    commands[#commands + 1] = { "set-option", "-pt", pane, name, values[name] }
  end
  return run_tmux_commands(commands)
end

function M.clear()
  local pane = enclosing_tmux_pane()
  if not pane then
    return false
  end
  return clear_options(pane)
end

function M.setup()
  if initialized then
    return
  end
  initialized = true

  local group = vim.api.nvim_create_augroup("LazyAgentAgentmuxStatus", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "LazyAgentSessionStarted", "LazyAgentSessionStopped" },
    callback = function()
      vim.schedule(M.sync)
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = M.clear,
  })

  -- The integration may be loaded after sessions were restored or while
  -- reloading lazyagent during development. Publish the current state without
  -- waiting for the next status transition.
  vim.schedule(M.sync)
end

return M
