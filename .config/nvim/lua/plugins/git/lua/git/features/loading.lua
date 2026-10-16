-- One loading lifetime per view. Producers own tokens; the display never does.
local M = {}
local states, timer = {}, nil
local frames = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
local function now() return vim.uv.hrtime() / 1e6 end
local function refresh()
  local lualine = package.loaded.lualine
  if lualine then lualine.refresh({ place = { 'statusline' } }) end
end
local function stop_if_idle()
  for _, state in pairs(states) do
    if next(state.tasks) or state.visible then return end
  end
  if timer then timer:stop(); timer:close(); timer = nil end
end
local function tick()
  local time, changed = now(), false
  for buf, state in pairs(states) do
    if not vim.api.nvim_buf_is_loaded(buf) then
      states[buf], changed = nil, true
    else
      if next(state.tasks) then
        state.idle_since = nil
        if not state.visible and time - state.started >= 120 then
          state.visible, state.shown = true, time
        end
      else
        state.idle_since = state.idle_since or time
        if state.visible and time - state.shown >= 300 and time - state.idle_since >= 150 then
          state.visible = false
        end
        if not state.visible then state.started = nil end
      end
      local text = state.visible and (frames[math.floor(time / 100) % #frames + 1] .. ' Loading…') or ''
      if text ~= state.text then state.text, changed = text, true end
    end
  end
  if changed then refresh() end
  stop_if_idle()
end
function M.begin(buf, key)
  local state = states[buf]
  if not state then state = { tasks = {}, text = '' }; states[buf] = state end
  if not next(state.tasks) and not state.visible then state.started = state.started or now() end
  local token = {}
  state.tasks[key], state.idle_since = token, nil
  if not timer then
    timer = vim.uv.new_timer()
    timer:start(50, 50, vim.schedule_wrap(tick))
  end
  return function()
    if states[buf] == state and state.tasks[key] == token then state.tasks[key] = nil end
  end
end
function M.busy(buf)
  local state = states[buf]
  return state ~= nil and next(state.tasks) ~= nil
end
function M.status(buf)
  local state = states[buf or vim.api.nvim_get_current_buf()]
  return state and state.text or ''
end
-- A direct Lualine component: ignore the component instance passed by Lualine.
function M.statusline() return M.status() end
function M.cleanup(buf)
  states[buf] = nil
  stop_if_idle()
  refresh()
end
return M
