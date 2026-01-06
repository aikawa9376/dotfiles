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
           -- Check again inside loop
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
              -- Final redraw to clear spinner
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

    -- Check if session has active monitor timer (implies running/thinking in instant mode)
    local s = state.sessions[name]
    if s and s.monitor_timer then
       -- Simple spinner based on time (50ms per frame)
       local frame_idx = math.floor(vim.loop.now() / 50) % #spinner_frames + 1
       icon = icon .. " " .. spinner_frames[frame_idx]
    end

    table.insert(status_parts, icon)
  end

  return table.concat(status_parts, " ")
end

function M.start_monitor(agent_name, pane_id, backend_mod)
  local s = state.sessions[agent_name]
  if not s then return end

  -- Only start monitor if in instant mode or hidden (background task)
  if not (s.mode == "instant" or s.hidden) then return end

  require("lazyagent.window").set_title(" " .. agent_name .. " (Thinking...) ")

  if s.monitor_timer then
    pcall(function() s.monitor_timer:stop() end)
    pcall(function() s.monitor_timer:close() end)
    s.monitor_timer = nil
  end

  local timer = vim.loop.new_timer()
  s.monitor_timer = timer
  -- Trigger status animation
  check_and_animate()

  local last_content = ""
  local stable_count = 0

  timer:start(500, 500, vim.schedule_wrap(function()
    if not state.sessions[agent_name] then
      if timer then pcall(function() timer:stop(); timer:close() end) end
      return
    end

    backend_mod.capture_pane(pane_id, function(text)
      if text == last_content then
        stable_count = stable_count + 1
      else
        stable_count = 0
        last_content = text
      end

      if stable_count >= 2 then -- 1 second stable
        require("lazyagent.window").set_title(" " .. agent_name .. " (Idle) ")
        if timer then
          pcall(function() timer:stop(); timer:close() end)
          if state.sessions[agent_name] then state.sessions[agent_name].monitor_timer = nil end
          -- Refresh status to clear spinner
          require("lualine").refresh()
        end
      end
    end)
  end))
end

return M
