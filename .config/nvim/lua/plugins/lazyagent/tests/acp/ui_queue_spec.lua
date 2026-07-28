local M = {}

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local queue = require("lazyagent.acp.ui_queue")
  queue._reset()
  local started = {}
  local finishers = {}

  for index = 1, 3 do
    queue.enqueue(function(finish)
      started[#started + 1] = index
      finishers[index] = finish
    end, { kind = "permission", label = "request-" .. tostring(index) })
  end

  assert_equal(#started, 1, "only the first interactive request starts")
  assert_equal(started[1], 1, "the first request starts first")
  assert_equal(#queue.snapshot().pending, 2, "later requests remain queued")
  finishers[1]()
  assert(vim.wait(1000, function() return #started == 2 end, 10), "second request should start after first")
  assert_equal(#started, 2, "only two requests have started")
  assert_equal(started[2], 2, "interactive requests preserve FIFO order")
  finishers[2]()
  assert(vim.wait(1000, function() return #started == 3 end, 10), "third request should start after second")
  assert_equal(started[3], 3, "the third request starts last")
  finishers[3]()
  assert(vim.wait(1000, function() return queue.snapshot().active == nil end, 10), "queue should become idle")
  assert_equal(#queue.snapshot().pending, 0, "queue drains all requests")
  queue._reset()
end

return M
