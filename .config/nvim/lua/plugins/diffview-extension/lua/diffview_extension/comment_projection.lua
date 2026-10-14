-- Project only unchanged, unambiguous code; never clamp a stale GitHub line.
local M = {}
local function equal_at(reference, current, first, last, offset)
  if first + offset < 1 or last + offset > #current then return false end
  for row = first, last do if reference[row] ~= current[row + offset] then return false end end
  return true
end
local function unique(reference, current, first, last)
  local count = 0
  for at = 1, #current - (last - first) do
    if equal_at(reference, current, first, last, at - first) then
      count = count + 1
      if count > 1 then return false end
    end
  end
  return count == 1
end
function M.prepare(reference, current)
  local identical = vim.deep_equal(reference, current)
  local changes = not identical and vim.diff(table.concat(reference, '\n') .. '\n', table.concat(current, '\n') .. '\n',
    { result_type = 'indices', algorithm = 'histogram' }) or {}
  return { reference = reference, current = current, identical = identical, changes = changes }
end
function M.range(plan, first, last)
  local reference, current = plan.reference, plan.current
  if type(first) ~= 'number' or type(last) ~= 'number' or first % 1 ~= 0 or last % 1 ~= 0
    or first < 1 or last < first or last > #reference then return end
  local offset = 0
  for _, change in ipairs(plan.changes) do
    local at, removed, added = change[1], change[2], change[4]
    if removed == 0 then
      if at < first then offset = offset + added
      elseif at < last then return end -- Insertions inside a multi-line anchor split it.
    elseif at + removed - 1 < first then offset = offset + added - removed
    elseif at <= last then return end
  end
  if not equal_at(reference, current, first, last, offset) then return end
  if not plan.identical then
    local verified = false
    for radius = 0, 2 do
      local a, b = math.max(1, first - radius), math.min(#reference, last + radius)
      if equal_at(reference, current, a, b, offset) and unique(reference, current, a, b) then verified = true; break end
    end
    if not verified then return end
  end
  return first + offset, last + offset
end
return M
