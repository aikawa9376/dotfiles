local M = {}
local agent_logic = require("lazyagent.logic.agent")
local state = require("lazyagent.logic.state")

local animation_timer = nil

-- Start animation loop if any session is in monitoring mode
local function check_and_animate()
  local any_active = false
  for _, s in pairs(state.sessions or {}) do
     if s.monitor_timer then
        any_active = true
        break
     end
  end

  if any_active then
     if not animation_timer then
        animation_timer = vim.loop.new_timer()
        animation_timer:start(100, 100, vim.schedule_wrap(function()
           local still_active = false
           for _, s in pairs(state.sessions or {}) do
              if s.monitor_timer then
                 still_active = true
                 break
              end
           end
           if still_active then
              require("lualine").refresh()
           else
              if animation_timer then
                 animation_timer:stop()
                 animation_timer:close()
                 animation_timer = nil
              end
              require("lualine").refresh()
           end
        end))
     end
  else
     if animation_timer then
        animation_timer:stop()
        animation_timer:close()
        animation_timer = nil
     end
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

-- Mark an agent as idle (called by MCP notify_done tool or internally)
function M.set_idle(agent_name)
  local s = state.sessions[agent_name]
  if not s then return end
  stop_monitor_timer(s)
  s.agent_status = "idle"
  require("lazyagent.window").set_title(" " .. agent_name .. " (Idle) ")
  pcall(function() require("lualine").refresh() end)
  pcall(function()
    local transport = require("lazyagent.mcp.transport")
    local capture = nil
    if s.pane_id then
      capture = require("lazyagent.tmux").capture_pane_sync(s.pane_id, 300)
    end
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
  require("lazyagent.window").set_title(" " .. agent_name .. " (" .. (msg or "Waiting...") .. ") ")
  pcall(function() require("lualine").refresh() end)
  pcall(function()
    local capture = nil
    if s.pane_id then
      capture = require("lazyagent.tmux").capture_pane_sync(s.pane_id, 300)
    end
    require("lazyagent.mcp.transport").push_event({
      event = "waiting", agent = agent_name, message = msg or "Waiting...", capture = capture,
    })
  end)
end

function M.start_monitor(agent_name)
  local s = state.sessions[agent_name]
  if not s then return end

  s.agent_status = "thinking"
  require("lazyagent.window").set_title(" " .. agent_name .. " (Thinking...) ")
  pcall(function()
    require("lazyagent.mcp.transport").push_event({ event = "start", agent = agent_name })
  end)

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
