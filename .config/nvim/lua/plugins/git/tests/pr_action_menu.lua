local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local ui = require('helpers.pr_ui').new(f)
local view, actions = require('git.features.pr'), require('git.features.github_actions')
local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'xt', false)
end
local function kind(expected) ui.wait(function() return vim.b.git_action_menu_kind == expected end) end
local function text() return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n') end
local function root(row)
  ui.source(); vim.api.nvim_win_set_cursor(0, { row or ui.row('+TWO'), 0 })
  press('<Space><Space>'); kind('pr-actions')
  local menu = text()
  for _, label in ipairs({ 'New comment', 'Review / resolve', 'Read / reply', 'Preview conversation', 'Diff display', 'Edit title', 'CI checks', 'Merge PR' }) do
    assert(menu:find(label, 1, true), 'Missing PR menu item: ' .. label)
  end
  for _, label in ipairs({ 'Create default PR', 'Create PR (Octo', 'Issues', 'Notifications', 'Current / selected PR', 'List pull requests' }) do
    assert(not menu:find(label, 1, true), 'Repository action leaked into PR menu: ' .. label)
  end
  assert(vim.fn.maparg('C', 'n', false, true).callback == nil, 'PR creation remains reachable')
  return vim.api.nvim_get_current_buf()
end
ui.open(); ui.key('>', ui.row('M file name.txt'))
ui.wait(function() return pcall(ui.row, '+TWO') end)
local title = ui.row('PR title')
vim.api.nvim_buf_set_lines(ui.buf, title - 1, title, false, { 'Unsaved title' })
local calls = #f.calls
local menu = root(); press('c'); kind('pr-comment')
assert(not vim.api.nvim_buf_is_valid(menu) and text():find('file name.txt:L2 (RIGHT)', 1, true))
assert(#f.calls == calls, 'Opening the comment menu made a GitHub request')
press('r')
local input = vim.api.nvim_get_current_buf()
assert(vim.bo.buftype == 'acwrite')
ui.body({ 'Menu review draft' }); ui.send(input)
ui.wait(function() return view.model(ui.buf).review.pending ~= nil end)
assert(f.reviews[1].state == 'PENDING' and f.reviews[1].comments[1].line == 2)
assert(ui.row('Unsaved title') and vim.bo[ui.buf].modified)
-- The review submenu uses the same source thread for its Resolve entry.
root(); press('r'); kind('pr-review')
assert(text():find('Resolve / reopen selected thread', 1, true))
local previous = view.model(ui.buf)
press('R')
ui.wait(function() return view.model(ui.buf) ~= previous and f.resolved and f.resolved[101] end)
assert(f.reviews[1].state == 'PENDING', 'Resolving a public thread submitted the pending review')
assert(ui.row('Unsaved title') and vim.bo[ui.buf].modified)
root(); press('r'); kind('pr-review'); press('m')
input = vim.api.nvim_get_current_buf(); assert(vim.bo.buftype == 'acwrite')
ui.send(input); assert(f.reviews[1].state == 'COMMENTED')
-- Browser, reply and preview routes retain PR/file context and do not open the
-- default creation menu merely because c/r have other meanings on Status.
local browser, open = nil, vim.ui.open
vim.ui.open = function(url) browser = url end
root(); press('b'); assert(browser == f.pr.url); vim.ui.open = open
root(ui.row('-two')); press('t')
input = vim.api.nvim_get_current_buf(); assert(vim.bo.buftype == 'acwrite')
local context = vim.api.nvim_buf_get_lines(vim.b[input].git_pr_context, 0, -1, false)
assert(context[1]:find('L2 (LEFT)', 1, true)); ui.close_draft(input)
root(); press('v')
assert(vim.api.nvim_get_current_buf() == ui.buf and vim.b[ui.buf].git_pr_preview)
require('git.features.pr_comment_preview').close(ui.buf)
root(); press('s'); kind('pr-display'); press('q')
-- Opening a diff or section action uses source rows, not the action-menu row.
local diffview
vim.api.nvim_create_user_command('DiffviewOpen', function(args) diffview = args.args end, { nargs = '*' })
local old_lib, old_bridge = package.loaded['diffview.lib'], package.loaded['diffview_extension.github_context']
local target_view, association = {}, nil
package.loaded['diffview.lib'] = { get_current_view = function() return target_view end }
package.loaded['diffview_extension.github_context'] = { associate = function(target, ctx) association = { target = target, ctx = ctx } end }
root(); press('D'); assert(diffview:find(f.base .. '..' .. f.head, 1, true))
assert(association.target == target_view and association.ctx.url == f.pr.url and association.ctx.root == f.root)
package.loaded['diffview.lib'], package.loaded['diffview_extension.github_context'] = old_lib, old_bridge
root(ui.row('M file name.txt')); press('o'); assert(not pcall(ui.row, '+TWO'))
root(ui.row('M file name.txt')); press('o'); ui.wait(function() return pcall(ui.row, '+TWO') end)
root(1); press('E'); press('<Esc>'); assert(vim.fn.line('.') == ui.row('Unsaved title'))
-- Both alternate entry points select the same context-specific PR menu.
ui.source(); press('N'); kind('pr-actions'); press('q')
actions.setup(); vim.cmd('GitHub'); kind('pr-actions'); press('q')
-- A completed refresh cannot turn a selected line into another comment target
-- while the root menu is still open.
menu = root()
previous = view.model(ui.buf)
view.refresh(ui.buf, false, true)
ui.wait(function() return view.model(ui.buf) ~= previous end)
press('c')
assert(vim.api.nvim_get_current_buf() == ui.buf and f.notifications[#f.notifications]:find('PR context changed', 1, true))
assert(ui.row('Unsaved title') and vim.bo[ui.buf].modified)
-- A replaced source buffer cannot be edited by a stale native-menu callback.
menu = root()
local source_win = assert(vim.fn.bufwinid(ui.buf))
local scratch = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { 'replacement' })
vim.api.nvim_win_set_buf(source_win, scratch); press('E')
assert(vim.api.nvim_get_current_buf() == scratch and vim.api.nvim_get_current_line() == 'replacement')
assert(f.notifications[#f.notifications]:find('source window changed', 1, true))
-- Regular Status keeps its Magit root, repository creation and Octo routes,
-- even with a selected PR URL. Buffer identity, not the URL, selects the menu.
local status = vim.api.nvim_create_buf(true, false)
vim.bo[status].filetype = 'gitstatus'
vim.api.nvim_buf_set_lines(status, 0, -1, false, { 'Head: topic' })
require('git.utils').set_buf_work_tree(status, f.root)
vim.api.nvim_set_current_buf(status)
require('git.features.magit_actions').attach(status)
local pull_request_at = require('git.features.status').pull_request_at
require('git.features.status').pull_request_at = function() return f.pr end
press('<Space><Space>'); kind('root'); press('N'); kind('github')
for _, label in ipairs({ 'Create default PR', 'Create PR (Octo', 'Review in Octo', 'Issues', 'Notifications' }) do
  assert(text():find(label, 1, true), 'Status lost a repository action: ' .. label)
end
assert(not text():find('New comment', 1, true))
press('q'); press('N'); kind('github'); press('q')
require('git.features.status').pull_request_at = pull_request_at
vim.api.nvim_buf_delete(ui.buf, { force = true }); f.cleanup()
print('PASS: PR-specific root and c/r submenus, source targeting, pending review safety, state refresh/draft preservation, read/preview/diff/metadata routes, N/GitHub aliases and regular Status filtering')
