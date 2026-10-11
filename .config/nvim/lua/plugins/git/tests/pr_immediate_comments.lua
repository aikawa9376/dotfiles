local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local ui = require('helpers.pr_ui').new(f)
local view = require('git.features.pr')
ui.open(); ui.expand_files(); ui.wait(function() return pcall(ui.row, '+TWO') end)
local function compose(body)
  ui.key('gC', ui.row('+TWO')); ui.key('c')
  return ui.body({ body })
end
local function writes()
  local count = 0
  for _, call in ipairs(f.calls) do if vim.tbl_contains(call.argv, 'POST') then count = count + 1 end end
  return count
end
-- Thread failure leaves one private, empty review and the local text intact.
local buf = compose('Do not lose my immediate comment')
f.graphql_error = true
ui.failed(buf, 'GraphQL rejected thread')
assert(#f.reviews == 1 and f.reviews[1].state == 'PENDING' and #f.reviews[1].comments == 0)
assert(vim.bo[buf].modified and vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == 'Do not lose my immediate comment')
local count = writes()
f.graphql_error = false
ui.failed(buf, 'A pending review exists')
assert(writes() == count, 'Retry created or published another review')
ui.close_draft(buf)
-- Discarding is explicit. A subsequent immediate post may safely create anew.
local confirm = vim.fn.confirm
vim.fn.confirm = function() return 1 end
ui.menu('gr'); ui.key('x'); ui.wait(function() return #f.reviews == 0 end); ui.loaded()
vim.fn.confirm = confirm
-- Submission failure preserves the one saved comment; recovery does not duplicate it.
buf = compose('Saved before submission failed')
f.api_before = function(path, method) return method == 'POST' and path:match('/events$') ~= nil end
ui.failed(buf, 'Immediate comment stopped')
local pending = f.reviews[1]
assert(pending.state == 'PENDING' and #pending.comments == 1 and not f.last_event)
count = writes(); ui.failed(buf, 'A pending review exists'); assert(writes() == count)
ui.close_draft(buf); f.api_before = nil
ui.menu('gr'); ui.key('m'); buf = ui.body({ '' }); ui.send(buf)
assert(pending.state == 'COMMENTED' and #pending.comments == 1 and f.last_event == 'COMMENT')
local found = 0
for _, comment in ipairs(f.comments[1]) do if comment.body == 'Saved before submission failed' then found = found + 1 end end
assert(found == 1 and not view.model(ui.buf).review.pending)
-- Unseen edits/additions after thread creation are never submitted along with it.
buf = compose('Only this comment may be submitted')
f.api_after = function(path, method, payload)
  if path == 'graphql' and payload.variables.input then
    local review = f.reviews[#f.reviews]
    review.comments[#review.comments + 1] = { id = 999999, body = 'Added in another client', path = 'file name.txt' }
  end
end
ui.failed(buf, 'immediate review changed')
pending = f.reviews[#f.reviews]
assert(pending.state == 'PENDING' and #pending.comments == 2)
ui.close_draft(buf); f.api_after = nil
-- An uncertain create response cannot lead to an automatic second create.
vim.fn.confirm = function() return 1 end
ui.menu('gr'); ui.key('x'); ui.loaded(); assert(not view.model(ui.buf).review.pending)
vim.fn.confirm = confirm
buf = compose('Uncertain creation')
f.api_after = function(path, method) return path == 'repos/org/repo/pulls/7/reviews' and method == 'POST' end
ui.failed(buf, 'Immediate comment stopped')
pending = f.reviews[#f.reviews]
assert(pending.state == 'PENDING' and #pending.comments == 0)
f.api_after = nil; count = writes()
ui.failed(buf, 'A pending review exists'); assert(writes() == count)
ui.close_draft(buf)
vim.api.nvim_buf_delete(ui.buf, { force = true }); f.cleanup()
print('PASS: immediate comments publish isolated GraphQL drafts and preserve/recover partial or uncertain writes without duplicate posting')
