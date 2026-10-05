-- One scheduled slice at a time across all views. Starting every hunk's
-- coroutine in the same refresh still blocks input for their combined budget.
local M = {}
local queue, pending = {}, false
local pump
pump = function()
  if pending or #queue == 0 then return end
  pending = true
  vim.defer_fn(function()
    pending = false
    local next_callback = table.remove(queue, 1)
    pump()
    next_callback()
  end, 1)
end
function M.schedule(callback)
  queue[#queue + 1] = callback
  pump()
end

function M.run(work, valid, done)
  local deadline
  local thread = coroutine.create(function()
    return work(function()
      if vim.uv.hrtime() >= deadline then coroutine.yield() end
    end)
  end)
  local function step()
    if valid and not valid() then if done then done(nil, 'cancelled') end; return end
    deadline = vim.uv.hrtime() + 3e6
    local ok, result = coroutine.resume(thread)
    if not ok then if done then done(nil, result) else error(result) end
    elseif coroutine.status(thread) == 'dead' then if done then done(result) end
    else M.schedule(step) end
  end
  M.schedule(step)
end
return M
