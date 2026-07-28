local M = {}

local pending = {}
local active = nil
local sequence = 0

local function drain()
  if active or #pending == 0 then return end
  active = table.remove(pending, 1)
  local entry = active
  local finished = false
  local function finish()
    if finished then return false end
    finished = true
    if active == entry then active = nil end
    vim.schedule(drain)
    return true
  end
  local ok, err = pcall(entry.run, finish)
  if not ok then
    if entry.on_error then pcall(entry.on_error, err) end
    finish()
  end
end

function M.enqueue(run, opts)
  if type(run) ~= "function" then
    return nil, "UI queue entry must be a function"
  end
  sequence = sequence + 1
  local entry = {
    id = sequence,
    run = run,
    kind = opts and opts.kind or nil,
    label = opts and opts.label or nil,
    on_error = opts and opts.on_error or nil,
  }
  pending[#pending + 1] = entry
  drain()
  return entry.id
end

function M.snapshot()
  return {
    active = active and {
      id = active.id,
      kind = active.kind,
      label = active.label,
    } or nil,
    pending = vim.tbl_map(function(entry)
      return {
        id = entry.id,
        kind = entry.kind,
        label = entry.label,
      }
    end, pending),
  }
end

function M._reset()
  pending = {}
  active = nil
  sequence = 0
end

return M
