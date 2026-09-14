local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local uv = vim.uv
local fs_factory, timer_factory = uv.new_fs_event, uv.new_timer
local fs_live, timers_live, created = 0, 0, 0
local function factory(original, timer)
  return function()
    local handle = assert(original())
    local caller = debug.getinfo(2, 'S').source
    local tracked = caller:find('/features/status_watch.lua', 1, true) ~= nil
    if tracked then
      if timer then timers_live = timers_live + 1 else fs_live = fs_live + 1 end
      created = created + 1
    end
    return {
      is_closing = function() return handle == nil or handle:is_closing() end,
      start = function(_, ...) return handle:start(...) end,
      stop = function() return handle:stop() end,
      close = function()
        assert(handle, 'watch handle closed twice')
        local closing = handle
        handle = nil
        if tracked then
          if timer then timers_live = timers_live - 1 else fs_live = fs_live - 1 end
        end
        closing:close()
      end,
    }
  end
end
uv.new_fs_event, uv.new_timer = factory(fs_factory, false), factory(timer_factory, true)
local watch = require('features.status_watch')
local root = vim.fn.tempname()
vim.fn.mkdir(root .. '/refs/heads', 'p')
vim.fn.writefile({ 'ref: refs/heads/main' }, root .. '/HEAD')
vim.fn.writefile({ 'one' }, root .. '/refs/heads/main')
local events, second_events = 0, 0
local stop = watch.subscribe(root, function() events = events + 1 end)
assert(vim.wait(1000, function() return fs_live == 3 end, 10))
local stop_second = watch.subscribe(root, function() second_events = second_events + 1 end)
vim.wait(150, function() return false end)
assert(fs_live == 3, 'same repository duplicated OS watches')
local before = created
vim.wait(1300, function() return false end)
assert(created == before and timers_live == 0 and events == 0, 'idle monitor created periodic work')
local function replace(path, text)
  vim.fn.writefile({ text }, path .. '.lock')
  assert(uv.fs_rename(path .. '.lock', path))
end
replace(root .. '/refs/heads/main', 'two')
assert(vim.wait(1000, function() return events > 0 and second_events > 0 end, 10))
local previous = events
vim.fn.mkdir(root .. '/refs/heads/feature', 'p')
replace(root .. '/refs/heads/feature/topic', 'three')
replace(root .. '/HEAD', 'ref: refs/heads/feature/topic')
assert(vim.wait(1000, function() return events > previous and fs_live == 4 end, 10))
previous = events
replace(root .. '/refs/heads/feature/topic', 'four')
assert(vim.wait(1000, function() return events > previous end, 10), 'atomic ref replacement lost the watcher')
stop()
assert(fs_live > 0, 'removing one subscriber stopped another')
stop_second(); stop_second()
assert(fs_live == 0 and timers_live == 0)
for _ = 1, 20 do
  local cancel = watch.subscribe(root, function() error('callback after unsubscribe') end)
  cancel(); cancel()
end
vim.wait(200, function() return false end)
assert(fs_live == 0 and timers_live == 0, 'rapid reopen/wipe leaked native handles')
-- Close while a filesystem event or one-shot debounce is pending.
stop = watch.subscribe(root, function() end)
assert(vim.wait(1000, function() return fs_live == 4 end, 10))
replace(root .. '/index', 'changed')
assert(vim.wait(1000, function() return timers_live > 0 end, 1))
stop()
vim.wait(150, function() return false end)
assert(fs_live == 0 and timers_live == 0)
uv.new_fs_event, uv.new_timer = fs_factory, timer_factory
vim.fn.delete(root, 'rf')
print('PASS: event-driven idle, shared watches, ref replacement/branch switch, repeated cleanup, pending debounce cleanup')
