local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
vim.o.columns, vim.o.lines = 150, 60
local f = require('helpers.issue_fixture').new()
local view = require('git.features.issue')
local issue_actions, actions = require('git.features.issue_actions'), require('git.features.github_actions')
local comment_actions = require('git.features.pr_comment_actions')
local ctx = vim.deepcopy(f.ctx)
local item = vim.tbl_extend('force', vim.deepcopy(f.comments[1]), { kind = 'comment' })
local foreign = vim.tbl_extend('force', vim.deepcopy(f.comments[2]), { kind = 'comment' })
f.run(function() return comment_actions.edit(ctx, foreign, 'Forged edit') end, 'Only your own')
f.run(function() return comment_actions.remove(ctx, foreign) end, 'Only your own')
f.comments[1].body = 'Edited elsewhere'
f.run(function() return comment_actions.edit(ctx, item, 'Stale edit') end, 'changed on GitHub')
item.body = f.comments[1].body
local parent = f.comments[1].issue_url
f.comments[1].issue_url = 'https://ghe.example.test/api/v3/repos/other/repo/issues/7'
f.run(function() return comment_actions.edit(ctx, item, 'Wrong repository') end, 'another resource')
f.comments[1].issue_url = parent
f.run(function() return comment_actions.edit(ctx, vim.tbl_extend('force', item, { kind = 'inline' }), 'Inline') end, 'ordinary comments')
assert(#f.writes == 0)
f.run(function() return comment_actions.toggle_reaction(ctx, item, '+1') end)
assert(#f.reactions == 1 and f.reactions[1].user.login == 'other')
f.run(function() return comment_actions.toggle_reaction(ctx, item, '+1') end)
assert(#f.reactions == 2 and f.reactions[2].user.login == 'viewer')
f.run(function() return comment_actions.remove(ctx, item) end)
assert(f.deleted == 10)
local select, selection = vim.ui.select, nil
vim.ui.select = function(items, opts, callback) selection = { items = items, opts = opts, callback = callback } end
local source_buf, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
require('git.utils').set_buf_work_tree(source_buf, f.root)
view.setup()
vim.cmd('GitIssue')
f.wait(function() return selection ~= nil end)
assert(#selection.items == 5 and selection.items[5].number == 7, 'List exposed a PR or missed repository actions')
selection.callback(selection.items[1])
f.wait(function() return selection.opts.prompt:find('closed', 1, true) end)
local current = selection
current.callback(current.items[2])
f.wait(function() return selection ~= current end)
assert(selection.opts.prompt == 'Issue labels' and selection.items[3].value == 'help wanted')
selection.callback(selection.items[3])
f.wait(function() return selection.opts.prompt:find('closed', 1, true) end)
assert(table.concat(f.calls[#f.calls], ' '):find('--label help wanted', 1, true))
selection.callback(selection.items[5])
local buf = vim.api.nvim_get_current_buf()
f.wait(function() return view.model(buf) ~= nil end)
assert(view.model(buf).ctx.resource_kind == 'issue')
local win = vim.api.nvim_get_current_win()
local function row(text)
  for index, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do if line:find(text, 1, true) then return index end end
  error('Missing ' .. text)
end
-- Header gE picks candidates and changes only one membership, then reopens.
vim.api.nvim_win_set_cursor(win, { row('Assignees:'), 0 })
selection = nil; vim.fn.maparg('gE', 'n', false, true).callback()
f.wait(function() return selection ~= nil end)
assert(selection.opts.prompt:find('Issue assignees', 1, true))
local selected
for _, entry in ipairs(selection.items) do if entry.name == 'bob' then selected = entry end end
selection.callback(selected)
f.wait(function() return #f.issue.assignees == 2 and not require('git.features.async').busy(f.root) end)
-- Close reason chooser and stale close/reopen paths.
selection = nil; view.lifecycle(buf)
assert(selection.opts.prompt == 'Close Issue #7')
selection.callback(selection.items[2]); f.wait(function() return f.issue.state == 'closed' end)
f.wait(function() return view.model(buf).issue.state == 'closed' end)
view.lifecycle(buf); f.wait(function() return f.issue.state == 'open' end)
assert(f.writes[#f.writes].payload.state_reason == nil)
-- Native create command publishes title/body through the same protected composer.
vim.api.nvim_set_current_win(source_win); selection = nil
vim.cmd('GitIssueCreate')
f.wait(function() return vim.api.nvim_get_current_buf() ~= source_buf end)
local composer = vim.api.nvim_get_current_buf()
assert(vim.b[composer].git_issue_ctx.number == nil and vim.api.nvim_buf_get_name(composer):find('/issues/new/', 1, true))
vim.api.nvim_buf_set_lines(composer, 0, -1, false, { 'Created through UI', '', 'Markdown body' })
-- Use a recorded opener to verify the successful handoff without fetching #55.
local opened, original_open = nil, view.open
view.open = function(target) opened = target end
vim.cmd('write')
f.wait(function() return opened ~= nil end)
assert(opened.number == 55 and opened.repo == 'org/repo' and not vim.api.nvim_buf_is_valid(composer))
assert(f.writes[#f.writes].payload.title == 'Created through UI' and f.writes[#f.writes].payload.body == 'Markdown body')
view.open = original_open
vim.api.nvim_set_current_win(source_win)
-- A successful creation after its composer closes must not open on another window.
local late_composer
issue_actions.create(ctx)
f.wait(function() return vim.api.nvim_get_current_buf() ~= source_buf end)
late_composer = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(late_composer, 0, -1, false, { 'Background creation', '', 'Body' })
f.delay = 20; opened = nil; view.open = function(target) opened = target end
vim.cmd('write')
vim.api.nvim_buf_delete(late_composer, { force = true })
f.wait(function() return not require('git.features.async').busy(f.root) end)
assert(opened == nil, 'Late creation stole focus after its composer was destroyed')
view.open, f.delay = original_open, 2
vim.api.nvim_set_current_win(source_win)
-- Listing callbacks abandon a replaced window, rather than opening on another buffer.
selection = nil; issue_actions.list(ctx)
vim.api.nvim_win_set_buf(source_win, vim.api.nvim_create_buf(true, false))
vim.wait(40, function() return false end, 2)
assert(selection == nil)
vim.ui.select = select
vim.api.nvim_buf_delete(buf, { force = true }); f.cleanup()
print('PASS: own/stale/foreign comment guards, own reaction toggles, Issue list/filter/open commands, header metadata, close reasons, native creation handoff and abandoned source callbacks')
