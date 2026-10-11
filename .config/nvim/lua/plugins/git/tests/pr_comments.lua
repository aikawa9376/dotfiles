local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local ui = require('helpers.pr_ui').new(f)
local before = f.git({ 'status', '--porcelain' })
ui.open()
ui.expand_files()
ui.wait(function() return pcall(ui.row, '+TWO') end)
-- PR conversation comments preserve literal text and captured worktree context.
ui.key('gC', 1); ui.key('p')
local buf = ui.body({ 'Comment `literal` $(do not execute)', 'Second line' })
vim.cmd('lcd /tmp')
f.comment_error = true
f.api_error_stderr = 'gh: Invalid request. (HTTP 422)'
f.api_error_response = vim.json.encode({ message = 'Invalid request.', errors = {
  'No subschema in "oneOf" matched.', '"line" is not a permitted key.' } })
ui.failed(buf, '"line" is not a permitted key.')
assert(vim.bo[buf].modified)
f.comment_error = false; f.api_error_response = nil; f.api_error_stderr = nil
ui.send(buf)
assert(f.discussion[1].body == 'Comment `literal` $(do not execute)\nSecond line')
local function comment(row, lines, key)
  ui.key('gC', row); ui.key(key or 'c')
  local draft = ui.body(lines)
  ui.send(draft)
  return f.comments[1][#f.comments[1]]
end
local added = comment(ui.row('+TWO'), { 'Added line' })
assert(added.path == 'file name.txt' and added.line == 2 and added.side == 'RIGHT')
local removed = comment(ui.row('-two'), { 'Removed line' })
assert(removed.line == 2 and removed.side == 'LEFT')
local file = comment(ui.row('M file name.txt'), { 'Whole file' })
assert(file.line == vim.NIL and file.path == 'file name.txt')
local file_payload
for _, call in ipairs(f.calls) do if call.opts.stdin and vim.tbl_contains(call.argv, 'repos/org/repo/pulls/7/reviews') then
  local payload = vim.json.decode(call.opts.stdin)
  assert(payload.commit_id == f.head, 'Diff comment used a working-copy or stale revision')
elseif call.opts.stdin and vim.tbl_contains(call.argv, 'graphql') then
  local input = vim.json.decode(call.opts.stdin).variables.input
  if input and input.body == 'Whole file' then file_payload = input end
end
  assert(not (vim.tbl_contains(call.argv, 'repos/org/repo/pulls/7/comments') and vim.tbl_contains(call.argv, 'POST')),
    'Immediate comment still used the rejected REST endpoint')
end
assert(file_payload.subjectType == 'FILE' and file_payload.line == nil)
assert(f.last_event == 'COMMENT' and require('git.features.pr').model(ui.buf).review.pending == nil)
-- Exercise the actual Visual mapping and modern line/side range fields.
ui.source(); vim.api.nvim_win_set_cursor(0, { ui.row('+TWO'), 0 }); vim.cmd('normal! Vj')
vim.fn.maparg('gC', 'x', false, true).callback(); ui.key('c')
buf = ui.body({ 'Two new-side lines' }); ui.send(buf)
local range = f.comments[1][#f.comments[1]]
assert(range.line == 3 and range.start_line == 2 and range.side == 'RIGHT')
-- Mixed additions/deletions cannot silently become the wrong review side.
ui.source(); vim.api.nvim_win_set_cursor(0, { ui.row('-two'), 0 }); vim.cmd('normal! Vj')
local count = #f.calls
vim.fn.maparg('gC', 'x', false, true).callback()
assert(vim.api.nvim_get_current_buf() == ui.buf and #f.calls == count)
assert(f.notifications[#f.notifications]:find('one diff side', 1, true))
-- Context protection fails before a request; head drift fails before a POST.
ui.key('gC', ui.row('+TWO')); ui.key('c'); buf = ui.body({ 'Keep my draft' })
local context = assert(vim.b[buf].git_pr_context)
count = #f.calls
assert(not pcall(vim.api.nvim_buf_set_lines, context, 0, 1, false, { 'tampered' }) and #f.calls == count)
f.pr.headRefOid = f.base
count = #f.calls
ui.failed(buf, 'PR head changed')
for i = count + 1, #f.calls do assert(not vim.tbl_contains(f.calls[i].argv, 'POST')) end
assert(vim.bo[buf].modified and vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == 'Keep my draft')
f.pr.headRefOid = f.head
f.pr.baseRefOid = f.base
ui.failed(buf, 'PR base changed')
f.pr.baseRefOid = f.base_head
-- Duplicate :w and q during submission do not close or duplicate a request.
f.delay = 30
vim.cmd('write')
assert(pcall(vim.cmd, 'write'), 'A duplicate save raised an error while the first send was still running')
ui.key('q')
assert(vim.api.nvim_buf_is_valid(buf) and not vim.bo[buf].modifiable)
ui.wait(function() return not vim.api.nvim_buf_is_valid(buf) end); ui.loaded()
for _, call in ipairs(f.calls) do assert(call.opts.cwd == f.root, 'Comment request followed changed cwd') end
assert(f.git({ 'status', '--porcelain' }) == before and f.git({ 'rev-parse', 'HEAD' }) == f.head)
vim.api.nvim_buf_delete(ui.buf, { force = true }); f.cleanup()
print('PASS: literal PR/line/file comments, Visual ranges, diff sides, captured root, protected context, head drift and retryable drafts')
