local source = debug.getinfo(1, "S").source:gsub("^@", "")
vim.opt.rtp:prepend(vim.fs.dirname(vim.fs.dirname(source)))
vim.opt.rtp:append(assert(vim.env.HLCHUNK_RTP))
local function count()
  local n = 0
  vim.uv.walk(function(h)
    if tostring(h):find("uv_timer_t", 1, true) and not h:is_closing() then n = n + 1 end
  end)
  return n
end
local before = count()
local patch = require("plugins.hlchunk_util").patch
patch()
local timers = require("hlchunk.utils.timer")
local timeout = timers.setTimeout
patch()
assert(timers.setTimeout == timeout, "the patch is installed once")
local calls, args = 0
local token = timers.setTimeout(function(...) calls = calls + 1; args = { n = select("#", ...), ... } end,
  1, "value", nil, "tail", nil)
assert(vim.wait(1000, function() return calls == 1 end))
token:stop()
assert(args.n == 4 and args[1] == "value" and args[3] == "tail", "timeout arguments retain nils")
local cancelled = timers.setTimeout(function() error("cancelled callback ran") end, 1)
cancelled:stop(); cancelled:stop()
local last
local debounced = timers.debounce(function(value) calls = calls + 1; last = value end, 5)
for i = 1, 2000 do debounced(i) end
assert(vim.wait(1000, function() return calls == 2 end))
assert(last == 2000, "debounce executes only the latest call")
local throttled_calls = 0
local throttled = timers.throttle(function() throttled_calls = throttled_calls + 1 end, 5)
for _ = 1, 100 do throttled() end
assert(vim.wait(1000, function() return throttled_calls == 1 end))
local both_calls = 0
local both = timers.debounce_throttle(function() both_calls = both_calls + 1 end, 5)
for _ = 1, 100 do both() end
assert(vim.wait(1000, function() return both_calls == 2 end))
local Task = require("hlchunk.utils.loopTask")
local steps = 0
local task = Task(function() steps = steps + 1 end, "linear", 10, { 1, 2, 3, 4, 5 })
task:start()
assert(vim.wait(1000, function() return steps == 5 end))
task:stop()
vim.wait(20, function() return false end)
collectgarbage("collect"); collectgarbage("collect")
assert(count() == before, "completed and cancelled timers release every libuv handle")
print("hlchunk timer lifecycle passed (2,000 debounce cancellations, timeouts, throttle, animation)")
