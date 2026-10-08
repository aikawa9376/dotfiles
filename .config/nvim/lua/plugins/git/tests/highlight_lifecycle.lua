local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local jobs = require('git.features.highlight_jobs')
local order = {}
jobs.schedule(function()
  order[#order + 1] = 1
  jobs.schedule(function() order[#order + 1] = 4 end)
end)
jobs.schedule(function() order[#order + 1] = 2 end)
jobs.schedule(function() order[#order + 1] = 3 end)
assert(vim.wait(1000, function() return #order == 4 end, 1))
assert(vim.deep_equal(order, { 1, 2, 3, 4 }), 'reentrant scheduling changed FIFO order')

local scheduled, schedules = {}, 0
jobs.schedule = function(callback)
  schedules = schedules + 1
  scheduled[#scheduled + 1] = callback
end
local function drain()
  while #scheduled > 0 do table.remove(scheduled, 1)() end
end
local sources = require('git.features.highlight_sources')
local loader = sources.new()
local completed = 0
for index = 1, 64 do
  loader.request({ old = { text = 'old ' .. index }, new = { text = 'new ' .. index } },
    function() return true end, function(pair)
      completed = completed + 1
      assert(pair.old[1] == 'old ' .. completed, 'source requests lost their ordering')
    end)
end
assert(schedules == 1 and completed == 0, 'request burst scheduled duplicate pumps or started inline')
drain()
assert(completed == 64 and schedules <= 2, 'completed batch flooded the shared scheduler')
loader.close()

local system, pending, killed = vim.system, {}, 0
vim.system = function(_, _, callback)
  pending[#pending + 1] = callback
  return { kill = function() killed = killed + 1 end }
end
loader = sources.new()
local active, old_calls, new_calls = true, 0, 0
local spec = { root = '/tmp', old = { object = 'HEAD:old' }, new = { object = 'HEAD:new' } }
loader.request(spec, function() return active end, function() old_calls = old_calls + 1 end)
drain(); assert(#pending == 1)
active = false; loader.prune(); assert(killed == 1)
-- A reused validity flag cannot resurrect canceled work after a view reopens.
active = true
loader.request(spec, function() return active end, function(pair)
  assert(pair.old[1] == 'fresh old' and pair.new[1] == 'fresh new')
  new_calls = new_calls + 1
end)
drain(); assert(#pending == 2)
pending[1]({ code = 0, stdout = 'stale old' })
vim.wait(20, function() return false end)
assert(#pending == 2, 'canceled read started its second Git process')
pending[2]({ code = 0, stdout = 'fresh old' })
assert(vim.wait(1000, function() return #pending == 3 end, 1))
pending[3]({ code = 0, stdout = 'fresh new' })
assert(vim.wait(1000, function() return new_calls == 1 end, 1))
drain(); assert(old_calls == 0 and loader.count == 0)
loader.close()
-- Cancellation before the first slice must also remain final on reentry.
loader = sources.new(); active = true
loader.request(spec, function() return active end, function() error('retired request published') end)
active = false; loader.prune(); active = true
drain(); assert(#pending == 3 and loader.count == 0, 'queued cancellation was resurrected')
loader.close(); vim.system = system
print('PASS: FIFO scheduler, coalesced source loading and permanent queued/in-flight cancellation')
