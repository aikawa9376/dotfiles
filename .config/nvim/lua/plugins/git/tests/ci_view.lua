local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.ci_fixture').new()
local ui = require('helpers.pr_ui').new(f)
local pr, ci = require('git.features.pr'), require('git.features.ci.view')
dofile(plugin .. '/../../config/colorScheme.lua')
vim.api.nvim_exec_autocmds('ColorScheme', { pattern = 'git-test' })
local function text(buf) return table.concat(vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false), '\n') end
local function key(value) local map = vim.fn.maparg(value, 'n', false, true); assert(map.callback, value); map.callback() end
ui.open(); local source_tab, source_win = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
ui.key('o', ui.row('CI:'))
local check_row = ui.row('test: FAILURE')
local seed = assert(pr.check_at(ui.buf, check_row))
assert(seed.provider == 'github_actions')
-- An unsaved PR draft must survive every transition.
local title = ui.row('PR title'); vim.api.nvim_buf_set_lines(ui.buf, title - 1, title, false, { 'Unsaved CI title' })
local tabs = #vim.api.nvim_list_tabpages()
ui.key('<CR>', check_row)
local detail, detail_win, detail_tab = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win(), vim.api.nvim_get_current_tabpage()
assert(#vim.api.nvim_list_tabpages() == tabs + 1 and detail_tab ~= source_tab and vim.bo[detail].filetype == 'gitcicheck')
ui.wait(function() return ci.details(detail) ~= nil end)
assert(text(detail):find('Test suite') and text(detail):find('Annotations') and text(detail):find('src/test.lua:42'), text(detail))
assert(ci.step_at(detail, vim.fn.line('.')).name == 'Run tests', 'Initial cursor missed the failed step')
assert(vim.fn.maparg('v', 'n', false, true).callback == nil, 'v should retain Visual selection')
vim.api.nvim_feedkeys('v', 'xt', false); assert(vim.fn.mode() == 'v')
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'xt', false)
local function highlighted(token, group)
  local lines = vim.api.nvim_buf_get_lines(detail, 0, -1, false)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(detail, vim.api.nvim_create_namespace('git_ci_details'), 0, -1, { details = true })) do
    local line, opts = lines[mark[2] + 1], mark[4]
    if opts.hl_group == group and line:sub(mark[3] + 1, opts.end_col) == token then return true end
  end
  return false
end
for _, item in ipairs({ { 'test', 'GitCiTitle' }, { 'Provider', 'GitPrHeaderLabel' },
  { 'Run tests', 'GitCiFailedStep' }, { 'failure', 'DiagnosticError' }, { 'Steps', 'GitCiHeading' },
  { 'Annotations', 'GitCiHeading' }, { 'src/test.lua', 'Directory' }, { '42', 'Number' },
  { 'Enter', 'GitActionMenuKey' }, { seed.url, 'GitCiLink' } }) do
  assert(highlighted(item[1], item[2]), 'Missing semantic CI highlight: ' .. item[1])
end
assert(vim.api.nvim_get_hl(0, { name = 'GitCiTitle' }).bold and vim.api.nvim_get_hl(0, { name = 'GitCiFailedStep' }).bold)
assert(vim.api.nvim_get_hl(0, { name = 'GitCiLink' }).underline)
local browser, original = nil, vim.ui.open; vim.ui.open = function(url) browser = url end
key('o'); assert(browser == seed.url); vim.ui.open = original
key('s'); local log1, log1_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
assert(vim.api.nvim_get_current_tabpage() == detail_tab and #vim.api.nvim_tabpage_list_wins(detail_tab) == 2)
assert(vim.api.nvim_win_get_position(log1_win)[1] > vim.api.nvim_win_get_position(detail_win)[1], 's should open below the details')
ui.wait(function() return text(log1):find('Expected 200', 1, true) ~= nil end)
assert(not text(log1):find('\27', 1, true) and vim.bo[log1].readonly and not vim.bo[log1].modifiable and vim.bo[log1].filetype == 'log')
assert(vim.fn.line('.') == 4, 'A successful step log should start at its body')
vim.fn.setreg('"', vim.api.nvim_buf_get_lines(log1, 3, 4, false)[1]); assert(vim.fn.getreg('"') == 'FAIL')
assert(vim.fn.search('Expected 200', 'w') > 0, 'Normal search failed in log')
vim.api.nvim_set_current_win(detail_win)
key('<CR>'); assert(vim.api.nvim_get_current_win() == log1_win and f.count('/steps/1/logs') == 1, 'Same log should reuse its window/cache')
key('q'); assert(vim.api.nvim_get_current_tabpage() == detail_tab and vim.api.nvim_get_current_buf() == detail)
key('s'); local log1_again = vim.api.nvim_get_current_buf(); assert(f.count('/steps/1/logs') == 1 and text(log1_again):find('FAIL'), 'Closed log must reuse downloaded body')
vim.api.nvim_set_current_win(detail_win)
local setup_row
for row = 1, vim.api.nvim_buf_line_count(detail) do local step = ci.step_at(detail, row); if step and step.name == 'Setup' then setup_row = row end end
vim.api.nvim_win_set_cursor(detail_win, { assert(setup_row), 0 }); key('<CR>')
local log2 = vim.api.nvim_get_current_buf(); ui.wait(function() return text(log2):find('SETUP', 1, true) ~= nil end)
assert(vim.api.nvim_win_get_position(0)[2] > vim.api.nvim_win_get_position(detail_win)[2], 'Enter should open a vertical split')
assert(#vim.api.nvim_tabpage_list_wins(detail_tab) == 3 and log2 ~= log1_again, 'Multiple step logs cannot be compared')
vim.api.nvim_set_current_win(detail_win); key('R')
assert(text(log1_again):find('Outdated log') and text(log2):find('Outdated log'), 'Refresh left old logs looking current')
ui.wait(function() return ci.details(detail) ~= nil end)
key('s'); local refreshed_log = vim.api.nvim_get_current_buf()
ui.wait(function() return text(refreshed_log):find('Expected 200', 1, true) ~= nil end)
assert(f.count('/steps/1/logs') == 2, 'Detail refresh must invalidate step cache')
-- Reopening the same check reuses its detail tab without duplicates.
vim.api.nvim_set_current_win(source_win); ui.key('<CR>', check_row)
assert(vim.api.nvim_get_current_buf() == detail and #vim.api.nvim_list_tabpages() == tabs + 1)
key('q')
assert(vim.api.nvim_get_current_tabpage() == source_tab and vim.api.nvim_get_current_win() == source_win)
assert(vim.api.nvim_win_get_cursor(source_win)[1] == check_row and text(ui.buf):find('Unsaved CI title') and vim.bo[ui.buf].modified)
-- The PR menu's CI entry reveals this same list without a popup or requests.
ui.key('<', ui.row('CI:'))
local before_menu = #f.calls + #f.ci_calls
require('git.features.github_checks').checks({ bufnr = ui.buf })
assert(vim.api.nvim_get_current_buf() == ui.buf and pr.check_at(ui.buf, vim.fn.line('.')))
assert(#f.calls + #f.ci_calls == before_menu and text(ui.buf):find('Unsaved CI title'))
-- A foreign user window in the detail tab survives q.
ui.key('<CR>', check_row); detail, detail_win, detail_tab = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win(), vim.api.nvim_get_current_tabpage()
ui.wait(function() return ci.details(detail) ~= nil end)
-- A newer refresh must win even if the cancelled response arrives later.
f.ci_delay = 100; key('R')
f.ci_delay = 2; f.ci_run.output.title = 'Current detail'
f.ci_job.steps[2].started_at, f.ci_job.steps[2].completed_at = '2026-10-12T01:00:12Z', '2026-10-12T01:00:20Z'
key('R')
ui.wait(function() return ci.details(detail) ~= nil end)
vim.wait(180, function() return false end, 10)
assert(text(detail):find('Current detail'), 'A stale request overwrote newer details')
f.responses['repos/org/repo/actions/jobs/12/steps/1/logs'] = { code = 1, stderr = 'Not Found (HTTP 404)' }
f.responses['repos/org/repo/actions/jobs/12/logs'] = { raw = '\239\187\191FULL JOB\n2026-10-12T01:00:10.000Z setup\n'
  .. '2026-10-12T01:00:12.010Z previous step tail\n2026-10-12T01:00:12.100Z ##[group]Run tests\n'
  .. '2026-10-12T01:00:13.000Z failed assertion\n2026-10-12T01:00:21.000Z cleanup\n' }
key('<CR>'); local fallback = vim.api.nvim_get_current_buf()
ui.wait(function() return text(fallback):find('FULL JOB', 1, true) ~= nil end)
assert(text(fallback):find('Job log · all steps', 1, true) and text(fallback):find('Selected step: Run tests', 1, true))
assert(not text(fallback):find('Step logs unavailable', 1, true) and not text(fallback):find('Cursor:', 1, true))
assert(not text(fallback):find('timestamp estimate', 1, true) and not text(fallback):find('\239\187\191', 1, true))
assert(vim.api.nvim_get_current_line() == 'FULL JOB', 'Whole-job logs should start at the body instead of an estimated step')
assert(text(fallback):find('cleanup'), 'The full job body should remain available')
key('q'); key('<CR>')
assert(vim.api.nvim_get_current_line() == 'FULL JOB', 'Cached whole-job logs should start at the body')
-- Completing in another window must update only the log's cursor and viewport.
key('q'); f.ci_delay = 80; key('<CR>')
local delayed = vim.api.nvim_get_current_buf()
-- Closed windows reuse the body cache; R explicitly starts an uncached read.
key('R'); local delayed_win = vim.api.nvim_get_current_win()
vim.api.nvim_set_current_win(detail_win)
ui.wait(function() return text(delayed):find('failed assertion', 1, true) ~= nil end)
assert(vim.api.nvim_get_current_win() == detail_win, 'Async log positioning stole focus')
local at = vim.api.nvim_win_get_cursor(delayed_win)[1]
assert(vim.api.nvim_buf_get_lines(delayed, at - 1, at, false)[1] == 'FULL JOB')
vim.api.nvim_set_current_win(delayed_win)
-- Retry still starts at the body, regardless of timestamp coverage.
f.ci_delay = 2
f.responses['repos/org/repo/actions/jobs/12/logs'] = { raw = '2026-10-12T01:00:10.000Z setup only\n' }
key('R'); ui.wait(function() return text(delayed):find('setup only', 1, true) ~= nil end)
assert(not text(delayed):find('start was not found') and vim.fn.line('.') == 4)
key('q')
vim.cmd('vnew'); local foreign, foreign_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
vim.api.nvim_buf_set_lines(foreign, 0, -1, false, { 'User work' })
vim.api.nvim_set_current_win(detail_win); key('q')
assert(vim.api.nvim_win_is_valid(foreign_win) and text(foreign) == 'User work' and vim.api.nvim_get_current_tabpage() == source_tab)
-- A pending request cannot repaint a closed tab.
f.ci_delay = 100
ui.key('<CR>', check_row); local closing = vim.api.nvim_get_current_buf(); key('q')
vim.wait(300, function() return false end, 10)
assert(vim.api.nvim_get_current_tabpage() == source_tab and not ci.details(closing))
-- Stable Commit Status context IDs reuse the tab, while newer selection metadata
-- forces enrichment and invalidates the previous version of its description.
f.ci_delay = 2
local status_row = ui.row('external: PENDING')
ui.key('<CR>', status_row); local external = vim.api.nvim_get_current_buf()
ui.wait(function() return ci.details(external) ~= nil end)
assert(text(external):find('Waiting for external CI'))
local current = vim.deepcopy(pr.check_at(ui.buf, status_row))
current.description = 'Updated external status'
f.responses['repos/org/repo/commits/' .. f.head .. '/statuses?per_page=100&page=1'][1].description = current.description
vim.api.nvim_set_current_win(source_win)
assert(ci.open(pr.model(ui.buf).ctx, current) == external)
ui.wait(function() return ci.details(external) ~= nil end)
assert(text(external):find('Updated external status') and not text(external):find('Waiting for external CI'))
key('q')
vim.api.nvim_buf_delete(ui.buf, { force = true }); f.cleanup()
print('PASS: direct PR entry, failed-step focus, searchable horizontal/vertical logs, cache/refresh, tab reuse, drafts/cursor and foreign-window/late-result safety')
