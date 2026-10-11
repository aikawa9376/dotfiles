local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local view = require('git.features.pr')
local b = assert(view.open({ root = f.root, url = f.pr.url }))
assert(vim.wait(5000, function() return view.model(b) ~= nil end, 10), table.concat(f.notifications, '\n'))
local function lines() return vim.api.nvim_buf_get_lines(b, 0, -1, false) end
local function row(value)
  for i, line in ipairs(lines()) do if line:find(value, 1, true) then return i end end
  error('Missing row: ' .. value)
end
local function key(name, at, col)
  local win = vim.fn.bufwinid(b)
  vim.api.nvim_set_current_win(win)
  if at then vim.api.nvim_win_set_cursor(win, { at, col or 0 }) end
  vim.fn.maparg(name, 'n', false, true).callback()
end
local opened = {}
vim.ui.open = function(url) opened[#opened + 1] = url end
key('gx', row('CI · test'))
assert(opened[#opened]:find('/job/12', 1, true), 'CI gx did not open exact job')
key('gx', row('CI · external'))
assert(opened[#opened] == 'https://ci.example.test/build/1')
key('gx', row('CI:'))
assert(opened[#opened] == f.pr.url .. '/checks', 'CI summary no longer opens PR checks')
local actions_row = row('[Actions]')
local actions_col = assert(lines()[actions_row]:find('[Actions]', 1, true)) - 1
assert(actions_row == 2 and not table.concat(lines(), '\n'):find('gx opens branch runs', 1, true))
key('gx', actions_row, actions_col)
assert(vim.uri_decode(opened[#opened]):find('/actions?query=branch:topic', 1, true))
key('<CR>', actions_row, actions_col + 2)
assert(vim.uri_decode(opened[#opened]):find('/actions?query=branch:topic', 1, true))
key('gx', actions_row, actions_col - 1)
assert(opened[#opened] == f.pr.url, 'Branch metadata was mistaken for the Actions link')
local action_marks = vim.api.nvim_buf_get_extmarks(b, vim.api.nvim_create_namespace('git_pr_status'),
  { actions_row - 1, actions_col }, { actions_row - 1, -1 }, { details = true })
assert(#action_marks > 0 and action_marks[1][4].hl_group == 'Underlined', 'Actions link is not visually distinguished')
local file = row('M file name.txt')
key('o', file)
assert(vim.wait(5000, function() return vim.tbl_contains(lines(), '+TWO') end, 10), table.concat(f.notifications, '\n'))
local comment_row = row('+TWO')
local _, info = view.entry_at(b, comment_row)
assert(info.threads[1].id == 101)
local marks = vim.api.nvim_buf_get_extmarks(b, vim.api.nvim_create_namespace('git_pr_status'), { comment_row - 1, 0 }, { comment_row - 1, -1 }, { details = true })
assert(#marks > 0 and marks[1][4].virt_text[1][1]:find('💬', 1, true), 'Comment marker absent')
key('gc', comment_row)
local reply = vim.api.nvim_get_current_buf()
assert(vim.bo[reply].filetype == 'markdown')
local reply_lines = vim.api.nvim_buf_get_lines(reply, 0, -1, false)
assert(vim.tbl_contains(reply_lines, 'Existing reply'))
vim.api.nvim_buf_set_lines(reply, #reply_lines - 1, -1, false, { 'Reply `literal` $(never execute)', 'Second line' })
f.reply_error = true
vim.cmd('write')
assert(vim.wait(5000, function() return vim.tbl_contains(f.notifications, 'server rejected write') end, 10))
assert(vim.api.nvim_buf_is_valid(reply) and vim.bo[reply].modified, 'Failed reply lost draft')
f.reply_error = false
vim.wait(80, function() return false end, 10)
vim.cmd('write')
assert(vim.wait(5000, function() return not vim.api.nvim_buf_is_valid(reply) end, 10))
local sent
for _, call in ipairs(f.calls) do if call.opts.stdin and vim.tbl_contains(call.argv, 'repos/org/repo/pulls/7/comments/101/replies') then
  sent = vim.json.decode(call.opts.stdin)
end end
assert(sent.body == 'Reply `literal` $(never execute)\nSecond line', 'Reply body did not preserve bytes')
assert(vim.wait(5000, function() return not require('git.features.async').busy(f.root) end, 10))
vim.wait(80, function() return false end, 10)
key('>', row('Changes ('))
assert(vim.wait(5000, function() return vim.tbl_contains(lines(), '+new') and vim.tbl_contains(lines(), '-delete this') end, 10), 'Expand all missed files')
-- The title/body region can grow while immutable diff row metadata still works.
local title = row('PR title')
vim.api.nvim_buf_set_lines(b, title - 1, title, false, { 'Edited title' })
vim.api.nvim_buf_set_lines(b, title + 1, title + 1, false, { 'Additional body line' })
assert(view.entry_at(b, row('M file name.txt')).path == 'file name.txt')
key('<', row('M file name.txt'))
assert(vim.tbl_contains(lines(), 'Edited title') and vim.tbl_contains(lines(), 'Additional body line'), 'Toggle erased draft')
local save_body
vim.api.nvim_buf_call(b, function() vim.cmd('write') end)
assert(vim.wait(5000, function() return f.pr.title == 'Edited title' and not vim.bo[b].modified end, 10), table.concat(f.notifications, '\n'))
assert(f.pr.body:find('Additional body line', 1, true))
-- Protected edits never reach GitHub.
local count = #f.calls
vim.api.nvim_buf_set_lines(b, 0, 1, false, { 'tampered state' })
local ok = pcall(view.write, b)
assert(not ok and #f.calls == count, 'Protected metadata was submitted')
vim.api.nvim_buf_set_lines(b, 0, 1, false, { 'PR #7 · OPEN' })
-- Split diff and Diffview use fixed PR snapshots, not working-copy revisions.
local commands = {}
vim.api.nvim_create_user_command('DiffviewOpen', function(args) commands[#commands + 1] = args.args end, { nargs = '*' })
key('D', row('Changes ('))
assert(commands[1]:find(f.base .. '..' .. f.head, 1, true))
key('d', row('M file name.txt'))
assert(vim.wo.diff and vim.api.nvim_get_current_line() ~= 'uncommitted')
vim.cmd('tabclose')
-- The Actions target remains available when the PR has no checks at all.
f.pr.statusCheckRollup = vim.NIL
view.refresh(b, true)
assert(vim.wait(5000, function() return (lines()[3] or ''):find('CI: —', 1, true) ~= nil end, 10))
actions_row = row('[Actions]')
actions_col = assert(lines()[actions_row]:find('[Actions]', 1, true)) - 1
assert(actions_row == 2)
key('gx', actions_row, actions_col)
assert(vim.uri_decode(opened[#opened]):find('/actions?query=branch:topic', 1, true))
key('gx', row('CI:'))
assert(opened[#opened] == f.pr.url .. '/checks')
vim.api.nvim_buf_delete(b, { force = true })
f.cleanup()
print('PASS: PR metadata edit/save, protected diffs, lazy expansion, comment icons/replies, failure drafts, contextual gx, split diff and Diffview')
