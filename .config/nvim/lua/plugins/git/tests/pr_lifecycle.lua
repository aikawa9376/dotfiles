local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local view, async = require('git.features.pr'), require('git.features.async')
local function loaded(b)
  assert(vim.wait(5000, function() return view.model(b) and not async.busy(f.root) end, 10), table.concat(f.notifications, '\n'))
end
local function at(b, value)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do if line == value then return i end end
  error('Missing ' .. value)
end
vim.wo.number, vim.wo.list = true, true
local b = view.open({ root = f.root, url = f.pr.url }); loaded(b)
local pr_win = vim.fn.bufwinid(b)
assert(not vim.wo[pr_win].number and not vim.wo[pr_win].list)
local scratch = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(pr_win, scratch)
assert(vim.wo[pr_win].number and vim.wo[pr_win].list, 'PR options leaked to an ordinary buffer')
vim.api.nvim_win_set_buf(pr_win, b)
local b2 = view.open({ root = f.root, number = 7 }); loaded(b2)
local count = #f.calls
vim.wait(150, function() return false end, 10)
assert(#f.calls == count, 'Read-only refreshes caused a GitHubChanged loop')
vim.api.nvim_set_current_win(vim.fn.bufwinid(b))
f.delay = 50
-- A local draft created during an in-flight refresh survives it.
view.refresh(b)
local title = at(b, 'PR title')
vim.api.nvim_buf_set_lines(b, title - 1, title, false, { 'During refresh' })
assert(vim.wait(5000, function() return not async.busy(f.root) end, 10))
assert(at(b, 'During refresh') and vim.bo[b].modified)
-- Failed saves are retryable and preserve the entire draft.
f.write_error = true
view.write(b)
assert(vim.wait(5000, function() return not async.busy(f.root) end, 10))
assert(vim.bo[b].modified and at(b, 'During refresh'))
f.write_error = false
view.write(b)
-- New text typed during a save stays dirty after the earlier version is sent.
vim.api.nvim_buf_set_lines(b, title - 1, title, false, { 'After submit' })
assert(vim.wait(5000, function() return not async.busy(f.root) end, 10))
assert(f.pr.title == 'During refresh' and vim.bo[b].modified and at(b, 'After submit'))
assert(not async.busy(f.root))
view.write(b)
assert(vim.wait(5000, function() return f.pr.title == 'After submit' and not vim.bo[b].modified end, 10))
-- Remote edit conflict never silently overwrites someone else's metadata.
title = at(b, 'After submit')
vim.api.nvim_buf_set_lines(b, title - 1, title, false, { 'Local conflict' })
f.pr.title = 'Remote conflict'
count = #f.calls
view.write(b)
assert(vim.wait(5000, function() return not async.busy(f.root) end, 10))
assert(f.pr.title == 'Remote conflict' and at(b, 'Local conflict') and vim.bo[b].modified)
for i = count + 1, #f.calls do assert(not vim.tbl_contains(f.calls[i].argv, 'PATCH')) end
-- Explicit discard/reload recovers from that conflict.
view.refresh(b, true)
assert(vim.wait(5000, function() return view.model(b).pr.title == 'Remote conflict' and not async.busy(f.root) end, 10))
assert(at(b, 'Remote conflict') and not vim.bo[b].modified)
-- A view closed while fetching cannot be resurrected by its callback.
view.refresh(b)
vim.api.nvim_buf_delete(b, { force = true })
assert(vim.wait(5000, function() return not async.busy(f.root) end, 10))
assert(not view.model(b) and not vim.api.nvim_buf_is_valid(b))
vim.api.nvim_buf_delete(b2, { force = true })
f.cleanup()
print('PASS: no refresh loops, drafts across in-flight refresh/save, retryable failures, remote-edit conflicts, explicit reload and closed-view guards')
