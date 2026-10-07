local M = {}

local active = {}
local frames = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
local frame = 1
local timer
local labels = {
  fetch = { icon = '󰓅', label = 'Fetching' },
  pull = { icon = '', label = 'Pulling' },
  push = { icon = '', label = 'Pushing' },
  sync = { icon = '󰓅', label = 'Syncing' },
}

local function refresh()
  vim.schedule(function()
    if package.loaded['lualine'] then
      pcall(require('lualine').refresh)
    end
  end)
end

local function stop_timer_if_idle()
  if next(active) then return end
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

local function start_timer()
  if timer then return end
  timer = vim.uv.new_timer()
  timer:start(100, 100, vim.schedule_wrap(function()
    if not next(active) then
      stop_timer_if_idle()
      return
    end
    frame = frame % #frames + 1
    refresh()
  end))
end

---@param work_tree string
---@param kind 'fetch'|'pull'|'push'|'sync'
---@return fun() finish
function M.start(work_tree, kind)
  local utils = require('git.utils')
  local root = utils.normalize_path(work_tree)
  assert(root, 'Git operation needs a worktree')
  assert(labels[kind], 'Unknown Git operation: ' .. tostring(kind))

  active[root] = active[root] or {}
  active[root][kind] = (active[root][kind] or 0) + 1
  start_timer()
  refresh()

  local finished = false
  return function()
    if finished then return end
    finished = true
    local operations = active[root]
    if not operations then return end
    operations[kind] = operations[kind] > 1 and operations[kind] - 1 or nil
    if not next(operations) then active[root] = nil end
    stop_timer_if_idle()
    refresh()
  end
end

---@param work_tree? string Filter by worktree; omitted to report all active operations.
---@return string
function M.status(work_tree)
  local operations
  if work_tree ~= nil then
    local utils = require('git.utils')
    local root = utils.normalize_path(work_tree)
    operations = root and active[root]
  else
    operations = {}
    for _, counts in pairs(active) do
      for kind, count in pairs(counts) do
        operations[kind] = (operations[kind] or 0) + count
      end
    end
  end
  if not operations then return '' end

  local parts = {}
  for _, kind in ipairs({ 'fetch', 'pull', 'push', 'sync' }) do
    local count = operations[kind]
    if count and count > 0 then
      local item = labels[kind]
      parts[#parts + 1] = item.icon .. ' ' .. item.label .. (count > 1 and (' ×' .. count) or '')
    end
  end
  if #parts == 0 then return '' end
  return frames[frame] .. ' ' .. table.concat(parts, '  ')
end

return M
