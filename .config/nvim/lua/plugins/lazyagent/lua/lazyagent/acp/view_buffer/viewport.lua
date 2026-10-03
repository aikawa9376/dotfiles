local M = {}

-- Zero-based, half-open ranges, merged so split windows cannot duplicate marks.
function M.ranges(bufnr, margin, stop)
  stop = stop or vim.api.nvim_buf_line_count(bufnr)
  local ranges = {}
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    local info = vim.fn.getwininfo(win)[1]
    if info then
      local top = math.max(1, info.topline or 1)
      local bottom = math.max(top, info.botline or top)
      ranges[#ranges + 1] = { math.max(0, top - 1 - margin), math.min(stop, bottom + margin) }
    end
  end
  table.sort(ranges, function(a, b) return a[1] < b[1] end)
  local merged = {}
  for _, range in ipairs(ranges) do
    local previous = merged[#merged]
    if previous and range[1] <= previous[2] then
      previous[2] = math.max(previous[2], range[2])
    elseif range[1] < range[2] then
      merged[#merged + 1] = range
    end
  end
  return merged
end

function M.contains(painted, visible)
  for _, range in ipairs(visible) do
    local found = false
    for _, cached in ipairs(painted) do
      if range[1] >= cached[1] and range[2] <= cached[2] then
        found = true
        break
      end
    end
    if not found then return false end
  end
  return true
end

return M
