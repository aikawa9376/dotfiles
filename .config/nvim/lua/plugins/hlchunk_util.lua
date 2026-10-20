local M = {}

function M.patch()
  local timers = require("hlchunk.utils.timer")
  if timers._bounded_timeouts then return end
  timers._bounded_timeouts = true

  -- Upstream never closes one-shot handles, and debounce cancels them with
  -- stop() alone. Use a cancellation token so stop() also releases the handle
  -- and remains safe after a timeout has fired (LoopTask relies on that).
  timers.setTimeout = function(fn, delay, ...)
    local handle = vim.uv.new_timer()
    if not handle then return end
    local args = { n = select("#", ...), ... }
    local cancelled = false
    local function close()
      if not handle:is_closing() then handle:stop(); handle:close() end
    end
    local token = {}
    function token:stop() cancelled = true; close() end
    token.close = token.stop
    handle:start(delay, 0, function()
      close()
      vim.schedule(function()
        if not cancelled then fn(unpack(args, 1, args.n)) end
      end)
    end)
    return token
  end
end

return M
