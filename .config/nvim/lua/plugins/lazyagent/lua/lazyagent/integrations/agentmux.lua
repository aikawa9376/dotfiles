local M = {}

local state = require("lazyagent.logic.state")

local initialized = false
local running = false
local pending = nil

local function enclosing_tmux_pane()
  local pane = tostring(vim.env.TMUX_PANE or "")
  return pane:match("^%%%d+$") and pane or nil
end

local function executable()
  if vim.fn.executable("agentmux") ~= 1 then
    return nil
  end
  local path = vim.fn.exepath("agentmux")
  return path ~= "" and path or "agentmux"
end

local function run_next()
  if running or not pending then
    return
  end
  local argv = pending
  pending = nil
  running = true
  local ok, job = pcall(vim.fn.jobstart, argv, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_exit = vim.schedule_wrap(function(_, code)
      running = false
      if code ~= 0 and state.opts and state.opts.debug then
        vim.notify("LazyAgent: agentmux status bridge failed", vim.log.levels.DEBUG)
      end
      run_next()
    end),
  })
  if not ok or type(job) ~= "number" or job <= 0 then
    running = false
    run_next()
  end
end

-- Keep only the newest unpublished state. If a command is already running,
-- the newest state is sent immediately after it exits, preserving ordering.
local function enqueue(argv)
  pending = argv
  run_next()
end

local function hosted_sessions()
  local sessions = {}
  for name, session in pairs(state.sessions or {}) do
    if session and session.backend == "buffer_acp" then
      sessions[#sessions + 1] = { name = tostring(name), session = session }
    end
  end
  table.sort(sessions, function(left, right) return left.name < right.name end)
  return sessions
end

local function aggregate_status(sessions)
  local selected = { rank = 0, status = "idle", message = "Ready", session = nil }
  local ranks = { idle = 1, thinking = 2, waiting = 3 }

  for _, item in ipairs(sessions) do
    local status = tostring(item.session.agent_status or "idle"):lower()
    if item.session.monitor_timer then
      status = "thinking"
    end
    local rank = ranks[status] or ranks.idle
    if rank > selected.rank then
      selected.rank = rank
      selected.status = status == "thinking" and "working" or (status == "waiting" and "blocked" or "idle")
      selected.message = tostring(item.session.agent_status_message or "")
      selected.session = item.session
    end
  end

  return selected.status, selected.message, selected.session
end

function M.sync()
  local binary = executable()
  local pane = enclosing_tmux_pane()
  if not binary or not pane then
    return false
  end

  local sessions = hosted_sessions()
  if #sessions == 0 then
    enqueue({ binary, "withdraw", pane, "--owner", "lazyagent" })
    return true
  end

  local names = {}
  for _, item in ipairs(sessions) do
    names[#names + 1] = item.name
  end
  local status, message, selected_session = aggregate_status(sessions)
  local kind = #names == 1 and names[1]:lower() or "lazyagent"
  local label = #names == 1 and (names[1] .. " (ACP)") or ("LazyAgent: " .. table.concat(names, "+"))
  local argv = {
    binary,
    "publish",
    pane,
    "--kind",
    kind,
    "--name",
    label,
    "--state",
    status,
    "--message",
    message,
    "--owner",
    "lazyagent",
    "--owner-pid",
    tostring(vim.fn.getpid()),
  }
  local preview_path = selected_session
      and (selected_session.acp_transcript_path or selected_session.transcript_path)
    or nil
  if type(preview_path) == "string" and preview_path ~= "" then
    argv[#argv + 1] = "--preview-path"
    argv[#argv + 1] = preview_path
  end
  enqueue(argv)
  return true
end

function M.clear_sync()
  local binary = executable()
  local pane = enclosing_tmux_pane()
  if not binary or not pane then
    return false
  end
  pcall(vim.fn.system, { binary, "withdraw", pane, "--owner", "lazyagent" })
  return vim.v.shell_error == 0
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
    callback = function() vim.schedule(M.sync) end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = M.clear_sync,
  })
  vim.schedule(M.sync)
end

return M
