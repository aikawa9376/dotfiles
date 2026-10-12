local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.ci_fixture').new()
local ui = require('helpers.pr_ui').new(f)
local pr, ci = require('git.features.pr'), require('git.features.ci.view')
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
local browser, original = nil, vim.ui.open; vim.ui.open = function(url) browser = url end
key('o'); assert(browser == seed.url); vim.ui.open = original
key('s'); local log1, log1_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
assert(vim.api.nvim_get_current_tabpage() == detail_tab and #vim.api.nvim_tabpage_list_wins(detail_tab) == 2)
ui.wait(function() return text(log1):find('Expected 200', 1, true) ~= nil end)
assert(not text(log1):find('\27', 1, true) and vim.bo[log1].readonly and not vim.bo[log1].modifiable and vim.bo[log1].filetype == 'log')
vim.fn.setreg('"', vim.api.nvim_buf_get_lines(log1, 3, 4, false)[1]); assert(vim.fn.getreg('"') == 'FAIL')
assert(vim.fn.search('Expected 200', 'w') > 0, 'Normal search failed in log')
vim.api.nvim_set_current_win(detail_win)
key('v'); assert(vim.api.nvim_get_current_win() == log1_win and f.count('/steps/1/logs') == 1, 'Same log should reuse its window/cache')
key('q'); assert(vim.api.nvim_get_current_tabpage() == detail_tab and vim.api.nvim_get_current_buf() == detail)
key('s'); local log1_again = vim.api.nvim_get_current_buf(); assert(f.count('/steps/1/logs') == 1 and text(log1_again):find('FAIL'), 'Closed log must reuse downloaded body')
vim.api.nvim_set_current_win(detail_win)
local setup_row
for row = 1, vim.api.nvim_buf_line_count(detail) do local step = ci.step_at(detail, row); if step and step.name == 'Setup' then setup_row = row end end
vim.api.nvim_win_set_cursor(detail_win, { assert(setup_row), 0 }); key('v')
local log2 = vim.api.nvim_get_current_buf(); ui.wait(function() return text(log2):find('SETUP', 1, true) ~= nil end)
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
f.ci_delay = 2; f.ci_run.output.title = 'Current detail'; key('R')
ui.wait(function() return ci.details(detail) ~= nil end)
vim.wait(180, function() return false end, 10)
assert(text(detail):find('Current detail'), 'A stale request overwrote newer details')
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
