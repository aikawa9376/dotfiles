local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
vim.o.columns, vim.o.lines = 150, 60
local f = require('helpers.issue_fixture').new()
local view, actions = require('git.features.issue'), require('git.features.github_actions')
local buf = view.open(f.ctx)
local win = vim.api.nvim_get_current_win()
local function source() assert(vim.api.nvim_win_is_valid(win)); vim.api.nvim_set_current_win(win) end
local function lines() return vim.api.nvim_buf_get_lines(buf, 0, -1, false) end
local function row(text)
  for index, line in ipairs(lines()) do if line:find(text, 1, true) then return index end end
  error('Missing row: ' .. text .. '\n' .. table.concat(lines(), '\n'))
end
local function key(key, at)
  source(); if at then vim.api.nvim_win_set_cursor(win, { at, 0 }) end
  local mapping = vim.fn.maparg(key, 'n', false, true)
  assert(type(mapping.callback) == 'function', 'Missing key: ' .. key); mapping.callback()
end
local function settle() vim.wait(40, function() return false end, 2) end
f.wait(function() return view.model(buf) ~= nil end)
assert(vim.bo[buf].filetype == 'gitissue' and vim.bo[buf].buftype == 'acwrite' and not vim.bo[buf].modified)
assert(vim.api.nvim_buf_get_name(buf):find('ghe.example.test/org/repo/issues/7', 1, true))
assert(not table.concat(lines(), '\n'):find('Changes (', 1, true))
assert(view.conversation_at(buf, row('M fake.lua')).id == 11, 'Header-like comment text misrouted')
local at = row('Second line')
vim.api.nvim_buf_set_lines(buf, at, at, false, { 'Local paragraph', 'Extra line' })
settle()
assert(view.conversation_at(buf, row('M fake.lua')).id == 11, 'Draft growth broke semantic rows')
local accepted = lines()
vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 'Tampered header' }); settle()
assert(vim.deep_equal(lines(), accepted) and vim.bo[buf].modified, 'Edit guard lost draft')
key('<', row('Conversation (')); assert(not pcall(row, 'M fake.lua') and row('Local paragraph'))
key('>', row('Conversation (')); assert(row('M fake.lua') and row('Local paragraph'))
key('<', 1); assert(not pcall(row, 'Assignees:') and row('Local paragraph'))
key('>', 1)
local previous = view.model(buf)
f.issue.labels[#f.issue.labels + 1] = { name = 'external' }
view.refresh(buf); f.wait(function() return view.model(buf) ~= previous end)
assert(row('external') and row('Local paragraph') and vim.bo[buf].modified, 'Refresh erased draft or hid fresh header')
source(); view.write(buf)
f.wait(function() return f.issue.body:find('Local paragraph', 1, true) and not vim.bo[buf].modified end)
assert(f.writes[#f.writes].payload.title == nil, 'Body save sent unedited title')
f.wait(function() return view.model(buf).issue.body:find('Local paragraph', 1, true) ~= nil end)
-- A local draft remains tied to its original baseline across remote refreshes.
at = row('Issue title'); vim.api.nvim_buf_set_lines(buf, at - 1, at, false, { 'Local title' }); settle()
f.issue.title = 'Remote title'
previous = view.model(buf); view.refresh(buf); f.wait(function() return view.model(buf) ~= previous end)
local writes = #f.writes
view.write(buf); f.wait(function() return #f.notifications > 0 and f.notifications[#f.notifications].message:find('changed on GitHub', 1, true) end)
assert(row('Local title') and vim.bo[buf].modified and #f.writes == writes, 'Refresh silently rebased stale metadata')
-- Replacing the title with its original value lets a later refresh accept remote metadata.
at = row('Local title'); vim.api.nvim_buf_set_lines(buf, at - 1, at, false, { 'Issue title' }); settle()
previous = view.model(buf); view.refresh(buf); f.wait(function() return view.model(buf) ~= previous end)
assert(row('Remote title') and not vim.bo[buf].modified)
-- A title-only save adopts a concurrent remote body that was never edited.
f.issue.body = 'Concurrent remote body'
at = row('Remote title'); vim.api.nvim_buf_set_lines(buf, at - 1, at, false, { 'Saved title' }); settle()
view.write(buf)
f.wait(function() return f.issue.title == 'Saved title' and not vim.bo[buf].modified end)
assert(row('Concurrent remote body') and f.writes[#f.writes].payload.body == nil)
f.wait(function() return view.model(buf).issue.title == 'Saved title' end)
-- Preserve a second edit made after sending the first body edit.
f.delay = 20
at = row('Concurrent remote body'); vim.api.nvim_buf_set_lines(buf, at - 1, at, false, { 'First local body' }); settle()
view.write(buf)
vim.api.nvim_buf_set_lines(buf, at - 1, at, false, { 'Second local body' })
f.wait(function() return f.issue.body == 'First local body' and view.model(buf).issue.body == 'First local body' end)
assert(row('Second local body') and vim.bo[buf].modified)
f.delay = 2; view.write(buf)
f.wait(function() return f.issue.body == 'Second local body' and not vim.bo[buf].modified end)
f.wait(function() return view.model(buf).issue.body == 'Second local body' end)
-- Menu ownership and keys target the Issue, with no PR/review/CI operations.
local menu, show = nil, require('git.features.transient_menu').show
require('git.features.transient_menu').show = function(spec) menu = spec end
key('N', row('Own reply')); assert(menu.kind == 'issue-actions')
local function entry(key)
  for _, group in ipairs(menu.groups) do for _, item in ipairs(group.actions) do if item.key == key then return item end end end
end
assert(entry('M') and entry('x') and not entry('m') and not entry('w') and not entry('k'))
local edit = entry('e'); vim.api.nvim_win_set_cursor(win, { 1, 0 }); edit.run()
assert(f.notifications[#f.notifications].message:find('view changed', 1, true))
key('gE', 1); assert(menu.kind == 'issue-metadata' and #menu.groups[1].actions == 2)
-- Browser routing uses the semantic comment even after title/body changes.
local opened, open = nil, vim.ui.open
vim.ui.open = function(url) opened = url end
key('gx', row('Own reply')); assert(opened:find('#issuecomment-10', 1, true))
vim.ui.open = open
-- Composer keeps sent text separate from immutable history, preserving failed input.
source(); local input = view.comment(buf)
assert(vim.bo[input].buftype == 'acwrite' and vim.api.nvim_buf_get_name(input):find('git-issue-compose://', 1, true))
local history = vim.b[input].git_pr_context
assert(vim.b[input].git_issue_ctx.resource_kind == 'issue' and not vim.bo[history].modifiable)
vim.api.nvim_buf_set_lines(input, 0, -1, false, { 'New Issue reply' })
f.fail = 'repos/org/repo/issues/7/comments'
vim.api.nvim_buf_call(input, function() vim.cmd('write') end)
f.wait(function() return vim.bo[input].modifiable end)
assert(vim.api.nvim_buf_is_valid(input) and vim.bo[input].modified and vim.api.nvim_buf_get_lines(input, 0, -1, false)[1] == 'New Issue reply')
f.fail = nil
vim.api.nvim_buf_call(input, function() vim.cmd('write') end)
f.wait(function() return not vim.api.nvim_buf_is_valid(input) end)
assert(not vim.api.nvim_buf_is_valid(history) and f.comments[#f.comments].body == 'New Issue reply')
f.wait(function() return #view.model(buf).conversation.entries == 4 end)
-- Own-comment edit/reaction paths are shared with PRs, but stay on Issue endpoints.
source(); key('gA', row('Own reply'))
f.wait(function() return menu.kind == 'pr-comment-actions' end)
entry('1').run(); f.wait(function() return #f.reactions == 1 end)
assert(f.reactions[1].user.login == 'other', 'Removed another viewer reaction')
source(); key('gA', row('Own reply')); settle()
entry('e').run()
local editbuf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(editbuf, 0, -1, false, { 'Edited reply' })
vim.cmd('write'); f.wait(function() return not vim.api.nvim_buf_is_valid(editbuf) end)
assert(f.comments[1].body == 'Edited reply')
-- Event rows cannot mutate a comment.
source(); key('gA', row('added label'))
assert(f.notifications[#f.notifications].message:find('no comment actions', 1, true))
-- Reopening equivalent selectors reuses the same root/host/repo/number identity.
assert(view.open({ root = f.root, url = f.ctx.url .. '#issuecomment-10' }) == buf)
-- Late completion never steals focus or overwrites a replacement buffer.
local other = vim.api.nvim_create_buf(true, false)
f.delay = 20
view.refresh(buf); vim.api.nvim_win_set_buf(win, other)
settle(); assert(vim.api.nvim_get_current_buf() == other)
source(); vim.api.nvim_win_set_buf(win, buf); view.refresh(buf)
key('q'); settle()
assert(not vim.api.nvim_win_is_valid(win), 'Issue q must close its owned window')
assert(view.model(buf) == nil)
require('git.features.transient_menu').show = show
f.cleanup()
print('PASS: Issue buffer, semantic conversation rows, draft/edit guards, folds/refresh/stale saves, contextual menu, failed composer recovery, comment edits/reactions and late callback ownership')
