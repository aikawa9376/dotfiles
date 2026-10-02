local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local async = require('git.features.async')
local original = vim.system
local calls, killed, callbacks = {}, 0, 0
vim.system = function(argv, opts, cb)
  calls[#calls + 1] = cb
  return { kill = function() killed = killed + 1 end }
end
local read = assert(async.run('/tmp', function() return async.git('/tmp', { 'status' }) end,
  function() callbacks = callbacks + 1 end))
read.cancel(); assert(killed == 1 and read.completed)
calls[1]({ code = 0, stdout = 'late' })
vim.wait(20, function() return false end)
assert(callbacks == 0, 'Cancelled read published a late result')
local write = assert(async.run('/tmp', function() return async.git('/tmp', { 'commit' }) end,
  function() callbacks = callbacks + 1 end, { mutation = true }))
write.cancel(); assert(killed == 1, 'Closing a view interrupted its transaction')
local other, err = async.run('/tmp', function() end, nil, { mutation = true })
assert(not other and err:find('already running', 1, true))
calls[2]({ code = 0, stdout = 'done' })
assert(vim.wait(1000, function() return write.completed end))
assert(callbacks == 1)
local hanging = assert(async.run('/tmp', function() return async.git('/tmp', { 'fetch' }) end,
  function() callbacks = callbacks + 1 end))
vim.api.nvim_exec_autocmds('VimLeavePre', { group = 'GitAsyncWorkflows' })
assert(killed == 2)
calls[3]({ code = 0, stdout = 'after exit' }); vim.wait(20, function() return false end)
assert(callbacks == 1)
assert(not async.run('/tmp', function() end))
vim.system = original
print('PASS: read cancellation, mutation ownership, completion release, exit without waiting, late result suppression')
