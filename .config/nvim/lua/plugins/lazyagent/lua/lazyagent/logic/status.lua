local M = {}
local agent_logic = require("lazyagent.logic.agent")
local backend_logic = require("lazyagent.logic.backend")
local state = require("lazyagent.logic.state")
local session_identity = require("lazyagent.logic.session.identity")
local agentmux = require("lazyagent.integrations.agentmux")

local transient_tasks = {}
local next_task_id = 0

local function refresh_transcript_footers(agent_names)
  pcall(function()
    local view = require("lazyagent.acp.view_buffer")
    if type(agent_names) == "table" and #agent_names > 0 then
      for _, agent_name in ipairs(agent_names) do
        view.refresh_agent_footers(agent_name)
      end
      return
    end
    view.refresh_all_footers()
  end)
end

local function refresh_ui(agent_names)
  refresh_transcript_footers(agent_names)
end

local function active_task_ids()
  local ids = {}
  for id, _ in pairs(transient_tasks) do
    table.insert(ids, id)
  end
  table.sort(ids)
  return ids
end

local icons = {
  Claude = "󰛨", -- 󰛨 (lightbulb/spark) or similar
  Codex = "", --  (chip)
  Gemini = "󰠠", -- 󰠠 (star/sparkle)
  Copilot = "", --  (github copilot icon usually)
  Cursor = "", --  (edit/cursor)
  -- Fallback
  Default = "",
}
local team_icon = ""

local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function grouped_active_sessions(active)
  local groups = {}
  for _, session_key in ipairs(active) do
    local session = state.sessions[session_key] or {}
    local team = type(session.lazyagent_team) == "table" and session.lazyagent_team or nil
    local provider_id = session_identity.provider_id(session_key, session)
    local team_id = team and (team.id or team.instance_id or team.team_id or team.name) or nil
    local key = team and ("team:" .. tostring(team_id or "active"))
      or ("provider:" .. tostring(provider_id))
    local group = groups[key]
    if not group then
      group = {
        key = key,
        icon = team and team_icon or (icons[provider_id] or icons.Default),
        is_team = team ~= nil,
        count = 0,
        thinking = false,
        waiting = false,
      }
      groups[key] = group
    end
    group.count = group.count + 1
    group.waiting = group.waiting or session.agent_status == "waiting"
    group.thinking = group.thinking
      or session.monitor_timer ~= nil
      or session.agent_status == "thinking"
  end

  local ordered = vim.tbl_values(groups)
  table.sort(ordered, function(left, right)
    if left.is_team ~= right.is_team then
      return left.is_team
    end
    return left.key < right.key
  end)
  return ordered
end

function M.get_status()
  local active = agent_logic.get_active_agents()
  local tasks = active_task_ids()
  if #active == 0 and #tasks == 0 then return "" end

  local status_parts = {}
  local frame_idx = math.floor(vim.loop.now() / 50) % #spinner_frames + 1
  for _, group in ipairs(grouped_active_sessions(active)) do
    local icon = group.icon
    if not group.is_team and group.count > 1 then
      icon = icon .. tostring(group.count)
    end
    if group.waiting then
      icon = icon .. " ?"
    elseif group.thinking then
      icon = icon .. " " .. spinner_frames[frame_idx]
    end
    table.insert(status_parts, icon)
  end

  for _, id in ipairs(tasks) do
    local task = transient_tasks[id]
    if task then
      local icon = task.icon or icons.Default
      local label = task.label and (" " .. task.label) or ""
      table.insert(status_parts, icon .. " " .. spinner_frames[frame_idx] .. label)
    end
  end

  return table.concat(status_parts, " ")
end

function M.start_task(label, opts)
  opts = opts or {}
  next_task_id = next_task_id + 1
  local id = next_task_id
  transient_tasks[id] = {
    label = label or opts.label or "Task",
    icon = opts.icon or "",
  }
  refresh_ui()
  return id
end

function M.stop_task(id)
  if not id then return end
  transient_tasks[id] = nil
  refresh_ui()
end

-- ────────────────────────────────────────────────
-- MCP-callable state transitions
-- ────────────────────────────────────────────────

local function stop_monitor_timer(s)
  if s.monitor_timer then
    pcall(function() s.monitor_timer:stop(); s.monitor_timer:close() end)
    s.monitor_timer = nil
  end
end

local function capture_for_session(agent_name, session)
  if not session or not session.pane_id then
    return nil
  end
  local _, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, nil)
  if not backend_mod or type(backend_mod.capture_pane_sync) ~= "function" then
    return nil
  end
  return backend_mod.capture_pane_sync(session.pane_id, 300)
end

function M.session_display_name(agent_name)
  local session = state.sessions[agent_name]
  local source = session and session.acp_thread_title_source or nil
  local title = session and vim.trim(tostring(session.acp_thread_title or "")) or ""
  if title ~= "" and (source == "manual" or source == "configured") then
    return title
  end
  return agent_name
end

function M.refresh_session_title(agent_name)
  local session = state.sessions[agent_name]
  if not session then return end
  require("lazyagent.window").set_title(" lazyagent ")
end

-- Mark an agent as idle (called by MCP notify_done tool or internally)
function M.set_idle(agent_name)
  local s = state.sessions[agent_name]
  if not s then return end
  stop_monitor_timer(s)
  s.agent_status = "idle"
  s.agent_status_message = "Ready"
  agentmux.sync()
  M.refresh_session_title(agent_name)
  refresh_ui()
  pcall(function()
    local transport = require("lazyagent.mcp.transport")
    local capture = capture_for_session(agent_name, s)
    transport.push_event({ event = "done", agent = agent_name, capture = capture })
  end)

  -- Execute and clear any pending on_idle callback for this agent
  if s.on_idle_callback then
    local cb = s.on_idle_callback
    s.on_idle_callback = nil
    vim.schedule(cb)
  end
end

-- Mark an agent as waiting for input (called by MCP notify_waiting tool)
function M.set_waiting(agent_name, msg)
  local s = state.sessions[agent_name]
  if not s then return end
  stop_monitor_timer(s)
  s.agent_status = "waiting"
  s.agent_status_message = msg or "Waiting..."
  agentmux.sync()
  M.refresh_session_title(agent_name)
  refresh_ui()
  pcall(function()
    local capture = capture_for_session(agent_name, s)
    require("lazyagent.mcp.transport").push_event({
      event = "waiting", agent = agent_name, message = msg or "Waiting...", capture = capture,
    })
  end)
end

function M.start_monitor(agent_name)
  local s = state.sessions[agent_name]
  if not s then return end

  s.agent_status = "thinking"
  s.agent_status_message = "Thinking..."
  agentmux.sync()
  M.refresh_session_title(agent_name)
  pcall(function()
    require("lazyagent.mcp.transport").push_event({ event = "start", agent = agent_name })
  end)
  refresh_ui()

  if s.backend == "buffer_acp" then
    return
  end

  if s.monitor_timer then
    pcall(function() s.monitor_timer:stop() end)
    pcall(function() s.monitor_timer:close() end)
    s.monitor_timer = nil
  end

  local timer = vim.loop.new_timer()
  s.monitor_timer = timer

  -- Spinner stops when agent calls notify_done via MCP.
  local ticks = 0

  timer:start(1000, 1000, vim.schedule_wrap(function()
    if not state.sessions[agent_name] then
      pcall(function() timer:stop(); timer:close() end)
      return
    end
    ticks = ticks + 1
  end))
end

function M.setup()
  return agentmux.setup()
end

return M
