local M = {}

-- Normalize the view's whitespace bridges and clip native EOF positions.
-- This is test-only: sharing the production comparison would hide regressions.
function M.mask(ranges, line)
  local bytes, previous = {}, nil
  for _, range in ipairs(ranges or {}) do
    for col = range[1], math.min(range[2], #line) do bytes[col] = true end
  end
  for col = 1, #line do
    if bytes[col] then
      if previous and line:sub(previous + 1, col - 1):match('^%s*$') then
        for gap = previous + 1, col - 1 do bytes[gap] = true end
      end
      previous = col
    end
  end
  return bytes
end

return M
