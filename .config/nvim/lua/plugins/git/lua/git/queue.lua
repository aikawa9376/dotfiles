-- FIFO without shifting all remaining entries on each dequeue.
local M = {}

function M.new()
  local items, first, last = {}, 1, 0
  local queue = {}
  function queue.push(value)
    last = last + 1
    items[last] = value
  end
  function queue.pop()
    if first > last then return nil end
    local value = items[first]
    items[first] = nil
    first = first + 1
    if first > last then first, last = 1, 0 end
    return value
  end
  function queue.empty() return first > last end
  return queue
end

return M
