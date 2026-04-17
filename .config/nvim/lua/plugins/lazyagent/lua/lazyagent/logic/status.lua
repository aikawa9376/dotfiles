local M = {}
local agent_logic = require("lazyagent.logic.agent")
local backend_logic = require("lazyagent.logic.backend")
local state = require("lazyagent.logic.state")

local animation_timer = nil
local ANIMATION_INTERVAL_MS = 200

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
  pcall(function() require("lualine").refresh() end)
  pcall(vim.cmd, "redrawstatus")
  refresh_transcript_footers(agent_names)
end

local function active_monitoring_agents()
  local agents = {}
  for agent_name, s in pairs(state.sessions or {}) do
    if s.monitor_timer then
      table.insert(agents, agent_name)
    end
  end
  return agents
end

-- Start animation loop if any session is in monitoring mode
local function check_and_animate()
  local monitoring_agents = active_monitoring_agents()
  local any_active = #monitoring_agents > 0

  if any_active then
      if not animation_timer then
         animation_timer = vim.loop.new_timer()
         animation_timer:start(ANIMATION_INTERVAL_MS, ANIMATION_INTERVAL_MS, vim.schedule_wrap(function()
            local active_agents = active_monitoring_agents()
            local still_active = #active_agents > 0
            if still_active then
                refresh_ui(active_agents)
             else
                if animation_timer then
                   animation_timer:stop()
                   animation_timer:close()
                   animation_timer = nil
                end
                refresh_ui()
              end
           end))
       end
  else
      if animation_timer then
        animation_timer:stop()
         animation_timer:close()
         animation_timer = nil
       end
      refresh_ui()
    end
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

local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

function M.get_status()
  local active = agent_logic.get_active_agents()
  if #active == 0 then return "" end

  local status_parts = {}
  for _, name in ipairs(active) do
    local icon = icons[name] or icons.Default
    local s = state.sessions[name]
    if s and s.monitor_timer then
       local frame_idx = math.floor(vim.loop.now() / 50) % #spinner_frames + 1
       icon = icon .. " " .. spinner_frames[frame_idx]
    elseif s and s.agent_status == "waiting" then
       icon = icon .. " ?"
    end
    table.insert(status_parts, icon)
  end

  return table.concat(status_parts, " ")
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

-- Mark an agent as idle (called by MCP notify_done tool or internally)
function M.set_idle(agent_name)
  local s = state.sessions[agent_name]
  if not s then return end
  stop_monitor_timer(s)
  s.agent_status = "idle"
  s.agent_status_message = "Ready"
  require("lazyagent.window").set_title(" " .. agent_name .. " (Idle) ")
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
  require("lazyagent.window").set_title(" " .. agent_name .. " (" .. (msg or "Waiting...") .. ") ")
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
  require("lazyagent.window").set_title(" " .. agent_name .. " (Thinking...) ")
  pcall(function()
    require("lazyagent.mcp.transport").push_event({ event = "start", agent = agent_name })
  end)
  refresh_ui()

  if s.monitor_timer then
    pcall(function() s.monitor_timer:stop() end)
    pcall(function() s.monitor_timer:close() end)
    s.monitor_timer = nil
  end

  local timer = vim.loop.new_timer()
  s.monitor_timer = timer
  check_and_animate()

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

return M
