local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local async = require('git.features.async')
local original = vim.system
local jobs, killed, published = {}, 0, 0
vim.system = function(argv, _, callback)
  jobs[argv[1]] = callback
  return { kill = function() killed = killed + 1 end }
end
local function read(name)
  return function() return async.system('/tmp', { name }).stdout end
end
local function complete(name, value)
  jobs[name]({ code = 0, stdout = value })
  vim.wait(20, function() return false end)
end
local results
local task = assert(async.run('/tmp', function()
  assert(#async.gather({}) == 0)
  return async.gather({ read('first'), function() error('broken read', 0) end,
    function() return async.gather({ read('nested'), function() return 'immediate' end }) end })
end, function(ok, value)
  assert(ok); results = value; published = published + 1
end, { mutation = true }))
assert(jobs.first and jobs.nested, 'Independent reads were serialized')
assert(async.busy('/tmp'))
complete('nested', 'nested value')
assert(not task.completed and async.busy('/tmp'), 'Parent released ownership before every child finished')
local other, err = async.run('/tmp', function() end, nil, { mutation = true })
assert(not other and err:find('already running', 1, true))
task.cancel(); assert(killed == 0, 'Closing a view interrupted its joined transaction')
complete('first', 'first value')
assert(task.completed and not async.busy('/tmp') and published == 1)
assert(results[1].ok and results[1].value == 'first value')
assert(not results[2].ok and results[2].value == 'broken read')
assert(results[3].value[1].value == 'nested value' and results[3].value[2].value == 'immediate')
-- Cancellation reaches grandchildren and suppresses late results.
local cancelled = assert(async.run('/tmp', function()
  return async.gather({ read('cancelled'), function() return async.gather({ read('grandchild') }) end })
end, function() published = published + 1 end))
cancelled.cancel()
assert(cancelled.completed and killed == 2)
complete('cancelled', 'late'); complete('grandchild', 'late')
assert(published == 1)
-- Exit kills every in-flight leaf even when the parent owns a mutation lock.
assert(async.run('/tmp', function() return async.gather({ read('exit one'), read('exit two') }) end,
  function() published = published + 1 end, { mutation = true }))
vim.api.nvim_exec_autocmds('VimLeavePre', { group = 'GitAsyncWorkflows' })
assert(killed == 4)
complete('exit one', 'late'); complete('exit two', 'late')
assert(published == 1 and not async.busy('/tmp'))
vim.system = original
print('PASS: joined concurrent reads, ordered failures, nested reads, mutation ownership, recursive cancellation and exit')
