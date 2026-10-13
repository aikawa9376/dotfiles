local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local ui = require('helpers.pr_ui').new(f)
local view = require('git.features.pr')
local function lines() return vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false) end
local function absent(text) assert(not pcall(ui.row, text), 'Unexpected header row: ' .. text) end
ui.open()
local first_line = 'Repo: org/repo [ PR #7 ] [OPEN]'
local function gutter(expected)
  local marks = vim.api.nvim_buf_get_extmarks(ui.buf, vim.api.nvim_create_namespace('git_pr_status'), 0, -1, { details = true })
  local count = 0
  for _, mark in ipairs(marks) do if mark[2] == 0 and mark[4].sign_text then
    count = count + 1
    assert(mark[2] == 0 and mark[4].sign_text:gsub('%s+$', '') == expected and mark[4].sign_hl_group == 'GitPrHeaderLabel')
  end end
  assert(count == 1, 'Fold marker should be a single first-line sign')
end
assert(lines()[1] == first_line and lines()[2] == 'Created by: @author')
gutter('▾')
assert(vim.wo.signcolumn == 'yes:1' and vim.wo.statuscolumn == '%s' and vim.wo.foldcolumn == '0')
vim.api.nvim_win_set_cursor(0, { 1, 0 }); vim.cmd('normal! zt'); vim.cmd('redraw')
local first_pos, next_pos = vim.fn.screenpos(0, 1, 1), vim.fn.screenpos(0, 2, 1)
assert(first_pos.col > 0 and first_pos.col == next_pos.col, 'Fold marker shifted the first line relative to the other text')
assert(ui.row('Repo: org/repo') < ui.row('Created by: @author'))
assert(ui.row('Created: 2026-10-09') < ui.row('Updated: 2026-10-10'))
for _, text in ipairs({ 'Repo:', 'Created by:', 'Created:', 'Updated:', 'From:', 'Commits:', 'CI:', 'Merge:' }) do
  assert(lines()[ui.row(text)]:find(text, 1, true) == 1, 'Header is indented relative to other blocks: ' .. text)
end
assert(vim.api.nvim_get_hl(0, { name = 'GitPrHeaderLabel', link = true }).link == 'DiagnosticInfo', 'Labels should retain the blue information color')
local opened, original_open = nil, vim.ui.open
vim.ui.open = function(url) opened = url end
ui.key('gx', 1); assert(opened == f.pr.url, 'PR title/state area should open the PR')
vim.api.nvim_win_set_cursor(0, { 1, #'Repo: ' }); ui.key('gx')
assert(opened == 'https://ghe.example.test/org/repo', 'Repository area should open the repository')
vim.ui.open = original_open
assert(ui.row('Commits: 1  Changed files: 4  (+3 -2 ■■■■■)'))
absent('Assignees:'); absent('Labels:'); absent('Milestone:'); absent('Reviewers:')
absent(f.pr.url); absent('No one assigned'); absent('None yet')
absent('[Actions]'); absent('test:'); absent('external:')
local function ci_gutter(expected)
  local row = ui.row('CI:')
  local marks = vim.api.nvim_buf_get_extmarks(ui.buf, vim.api.nvim_create_namespace('git_pr_status'),
    { row - 1, 0 }, { row - 1, -1 }, { details = true })
  for _, mark in ipairs(marks) do if mark[4].sign_text then
    assert(mark[4].sign_text:gsub('%s+$', '') == expected)
    return
  end end
  error('CI fold marker missing')
end
ci_gutter('▸')
local calls_before_fold = #f.calls
ui.key('<Tab>', ui.row('CI:')); assert(ui.row('test:') and ui.row('external:')); ci_gutter('▾')
for _, text in ipairs({ 'test:', 'external:' }) do
  assert(not lines()[ui.row(text)]:match('^%s'), 'CI result should have no nesting indent')
end
ui.key('=', ui.row('test:')); absent('test:'); assert(ui.row('Created by:')); ci_gutter('▸')
ui.key('>', ui.row('CI:')); assert(ui.row('test:'))
ui.key('<', ui.row('external:')); absent('external:'); assert(ui.row('CI:'))
ui.key('<CR>', ui.row('CI:')); assert(ui.row('test:')); ci_gutter('▾')
assert(#f.calls == calls_before_fold, 'CI folding performed network or Git work')
local stats_row = ui.row('Commits:')
local stats = vim.api.nvim_buf_get_extmarks(ui.buf, vim.api.nvim_create_namespace('git_pr_status'),
  { stats_row - 1, 0 }, { stats_row - 1, -1 }, { details = true })
local green, red = false, false
for _, mark in ipairs(stats) do
  local text = lines()[stats_row]:sub(mark[3] + 1, mark[4].end_col)
  if text == '■■■' and mark[4].hl_group == 'GitPrPositive' then green = true end
  if text == '■■' and mark[4].hl_group == 'GitSignsDelete' then red = true end
end
assert(green and red, 'Diffstat proportions or colors were lost')
f.pr.assignees = { { login = 'assigned' } }
f.pr.labels = { { name = '日本語' }, { name = 'bug' } }
f.pr.milestone = { title = 'Version 1' }
f.pr.reviewRequests = { { login = 'requested' }, { requestedReviewer = { name = 'team' } } }
f.reviews = {
  { id = 400, user = { login = 'reviewer' }, state = 'CHANGES_REQUESTED', submitted_at = '2026-10-09T00:00:00Z' },
  { id = 401, user = { login = 'reviewer' }, state = 'APPROVED', submitted_at = '2026-10-10T00:00:00Z' },
  { id = 800, user = { login = 'private' }, state = 'PENDING' },
  { id = 402, user = { login = f.viewer }, state = 'COMMENTED', submitted_at = '2026-10-10T00:00:00Z', commit_id = f.head },
  { id = 403, node_id = 'REVIEW403', user = { login = f.viewer }, state = 'PENDING', commit_id = f.head, body = '', comments = {} },
}
ui.refresh()
assert(ui.row('Assignees: assigned') and ui.row('Labels: 日本語, bug') and ui.row('Milestone: Version 1'))
assert(lines()[ui.row('Reviewers:')] == 'Reviewers: @requested ◷  @reviewer ✓  @team ◷  @viewer ·')
absent('@private')
assert(ui.row('Your review:') < ui.row('Your last review:'))
assert(ui.row('Your last review:') < ui.row('CI:') and ui.row('CI:') < ui.row('test:'))
local header = require('git.features.pr_header').build(view.model(ui.buf), true, true)
assert(header.lines[#header.lines]:find('external:', 1, true), 'CI checks should finish the Repo header')
-- Header folding changes only its metadata, preserving the editable draft and
-- expanded file diffs; all three Status aliases are available on the header.
ui.key('o', ui.row('M file name.txt')); ui.wait(function() return pcall(ui.row, '+TWO') end)
local title = ui.row('PR title')
vim.api.nvim_buf_set_lines(ui.buf, title - 1, title, false, { 'Unsaved title' })
vim.api.nvim_buf_set_lines(ui.buf, title + 1, title + 1, false, { 'Unsaved body' })
local calls = #f.calls
ui.key('<', ui.row('CI:')); absent('test:')
assert(ui.row('Unsaved title') and ui.row('Unsaved body') and ui.row('+TWO') and vim.bo[ui.buf].modified)
assert(view.entry_at(ui.buf, ui.row('+TWO')).path == 'file name.txt')
ui.key('o', ui.row('CI:')); assert(ui.row('test:'))
ui.key('o', 1)
assert(lines()[1] == first_line); absent('CI:')
gutter('▸')
absent('Commits:'); absent('[Actions]'); absent('Assignees:')
absent('Your review:'); absent('Your last review:'); absent('test:'); absent('external:')
assert(ui.row('Unsaved title') and ui.row('Unsaved body') and ui.row('+TWO') and vim.bo[ui.buf].modified)
assert(view.entry_at(ui.buf, ui.row('+TWO')).path == 'file name.txt')
assert(#f.calls == calls, 'Header fold performed network or Git work')
ui.key('<Tab>', 1); assert(ui.row('Created by:')); gutter('▾')
assert(ui.row('test:')); ci_gutter('▾')
ui.key('=', ui.row('Created by:')); absent('Created by:'); gutter('▸')
ui.key('>', 1); assert(ui.row('Commits:'))
ui.key('<', 1); absent('Commits:')
assert(ui.row('Unsaved title') and ui.row('Unsaved body') and vim.bo[ui.buf].modified)
-- New remote metadata does not forcibly reopen a collapsed header.
title = ui.row('Unsaved title')
vim.api.nvim_buf_set_lines(ui.buf, title - 1, title, false, { 'PR title' })
vim.api.nvim_buf_set_lines(ui.buf, title + 1, title + 2, false, {})
ui.refresh(); absent('Created by:'); assert(lines()[1] == first_line); gutter('▸')
ui.key('>', 1)
ui.key('<', ui.row('CI:'))
f.pr.assignees, f.pr.labels, f.pr.milestone, f.pr.reviewRequests = {}, {}, vim.NIL, {}
f.pr.createdAt, f.pr.updatedAt, f.pr.mergeStateStatus = vim.NIL, vim.NIL, 'UNKNOWN'
f.reviews = {}; f.pr.additions, f.pr.deletions = 0, 0
ui.refresh()
absent('test:'); ci_gutter('▸')
for _, text in ipairs({ 'Created:', 'Updated:', 'Assignees:', 'Milestone:', 'Labels:', 'Reviewers:', 'Merge:' }) do absent(text) end
assert(ui.row('(+0 -0 ■■■■■)'))
vim.api.nvim_buf_delete(ui.buf, { force = true }); f.cleanup()
print('PASS: Octo-style optional details, latest reviewers, five-cell diffstat, default-open header folding, aliases, preserved drafts/diffs and refresh state')
