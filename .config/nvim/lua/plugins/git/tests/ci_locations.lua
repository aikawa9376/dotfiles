local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local locations = require('git.features.ci.log_locations')
local stamp = '2026-08-02T12:06:18.9787747Z '
local lines = {
  'unrelated output', '',
  stamp .. 'warning: Cannot assign number to integer.',
  stamp .. '  --> lua/fzf-lua/test/harness/screenshot.lua:87:9', stamp,
  stamp .. '  86 |         -- Cycle', stamp .. '  87 |         cur_code_id = 42',
  stamp .. '  88 |       end', stamp,
  stamp .. 'warning: another problem', stamp .. '  --> another.lua:150:96', stamp,
  stamp .. '  150 | other code', '', 'normal output', '',
  'Error traceback', '  src/test.lua:42:3', '  assertion failed', '',
  'a.lua:1:2 b.lua:3:4', 'ambiguous continuation', '',
  'https://example.test:443', '', '"file name.txt:2:2"', '',
  'src/main.lua:5: error: failed', '', 'missing.lua:0:9',
  '', '--- diagnostics.lua [1 warning]', 'warning: last diagnostic',
  '  --> diagnostics.lua:10:2', '', '  10 | return value', '##[endgroup]', 'ordinary output',
}
local rows = locations.index(lines)
for row = 3, 9 do assert(rows[row] and rows[row].path == 'lua/fzf-lua/test/harness/screenshot.lua' and rows[row].row == 87 and rows[row].col == 9, 'Missing/wrong diagnostic row ' .. row) end
for row = 10, 14 do assert(rows[row] and rows[row].path == 'another.lua', 'Neighbor diagnostic leaked at ' .. row) end
for row = 17, 19 do assert(rows[row] and rows[row].path == 'src/test.lua') end
for _, row in ipairs({ 1, 2, 15, 16, 21, 22, 24, 30 }) do assert(not rows[row], 'Spurious source location at ' .. row) end
assert(rows[26].path == 'file name.txt' and rows[28].row == 5)
for row = 33, 36 do assert(rows[row] and rows[row].path == 'diagnostics.lua') end
for _, row in ipairs({ 32, 37, 38 }) do assert(not rows[row], 'Source block crossed a file/group heading') end
assert(locations.relative('/repo', 'lua/../src/main.lua') == '/repo/src/main.lua')
assert(not locations.relative('/repo', '../outside.lua') and not locations.relative('/repo', '/repo2/file.lua'))
assert(locations.relative('/repo', '/repo/src/main.lua') == '/repo/src/main.lua')

local f = require('helpers.ci_fixture').new()
local ui = require('helpers.pr_ui').new(f)
-- Ordinary editor defaults must survive PR/detail/log windows. Use the actual
-- configured values and a distinct relative-number preference to catch leaks.
local defaults = { number = true, relativenumber = true, numberwidth = 1, wrap = true,
  list = true, signcolumn = 'yes', statuscolumn = '%C%l%s', foldenable = false, foldcolumn = '1' }
for name, value in pairs(defaults) do vim.api.nvim_set_option_value(name, value, { scope = 'global' }) end
require('git').setup()
local function editor_defaults(win)
  for name, value in pairs(defaults) do
    assert(vim.api.nvim_get_option_value(name, { scope = 'global' }) == value, 'CI changed the global ' .. name)
    assert(vim.api.nvim_get_option_value(name, { win = win, scope = 'local' }) == value, 'Source inherited CI ' .. name)
  end
end
local ci = require('git.features.ci.view')
local function key(value) local map = vim.fn.maparg(value, 'n', false, true); assert(map.callback, value); map.callback() end
local body = {
  stamp .. 'warning: local file diagnostic', stamp .. '  --> file name.txt:2:2', stamp,
  stamp .. '  2 | TWO', '',
  stamp .. 'warning: PR-only file diagnostic', stamp .. '  --> added.txt:1:2', stamp,
  stamp .. '  1 | new', '',
  'missing.lua:87:9', '', '../outside.lua:2:1', '', 'plain output',
}
f.responses['repos/org/repo/actions/jobs/12/steps/1/logs'] = { raw = table.concat(body, '\n') }
ui.open(); local pr_win = vim.api.nvim_get_current_win()
ui.key('o', ui.row('CI:')); ui.key('<CR>', ui.row('test: FAILURE'))
local detail, detail_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
ui.wait(function() return ci.details(detail) ~= nil end)
key('<CR>'); local log, log_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
ui.wait(function() return vim.api.nvim_buf_get_lines(log, 3, 4, false)[1] == body[1] end)
vim.cmd('cd /tmp') -- CI root must not depend on cwd.
local initial_tabs = #vim.api.nvim_list_tabpages()
local source_win
for _, row in ipairs({ 4, 5, 6, 7 }) do
  vim.api.nvim_set_current_win(log_win); vim.api.nvim_win_set_cursor(0, { row, 0 }); key('gf')
  assert(vim.api.nvim_buf_get_name(0) == f.root .. '/file name.txt', table.concat(f.notifications, '\n'))
  assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 2, 1 }))
  source_win = source_win or vim.api.nvim_get_current_win()
  assert(vim.api.nvim_get_current_win() == source_win, 'gf should reuse an already open source window')
  assert(#vim.api.nvim_list_tabpages() == initial_tabs + 1, 'Repeated gf created another source tab')
  editor_defaults(source_win)
  assert(vim.api.nvim_win_get_buf(log_win) == log and vim.bo[log].readonly, 'gf destroyed the log')
end
local editable_source = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(0, 1, 2, false, { 'Unsaved source edit' })
-- A foreign PR must not jump into a coincidentally same-named caller file.
local pr_model = require('git.features.pr_model')
local remote = pr_model.remote
pr_model.remote = function() return 'https://ghe.example.test/other/repo.git' end
vim.api.nvim_set_current_win(log_win); vim.api.nvim_win_set_cursor(0, { 4, 0 }); key('gf')
assert(vim.b.git_object and vim.b.git_object.path == 'file name.txt' and vim.api.nvim_get_current_line() == 'TWO')
assert(vim.bo.readonly and vim.bo[editable_source].modified)
assert(vim.api.nvim_get_current_win() == source_win and #vim.api.nvim_list_tabpages() == initial_tabs + 1, 'Foreign source created another tab')
editor_defaults(source_win)
pr_model.remote = remote
vim.fn.delete(f.root .. '/added.txt')
vim.api.nvim_set_current_win(log_win); vim.api.nvim_win_set_cursor(0, { 12, 0 }); key('gf')
local snapshot, snapshot_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
assert(vim.b.git_object and vim.b.git_object.revision == f.head and vim.b.git_object.path == 'added.txt', table.concat(f.notifications, '\n'))
assert(vim.api.nvim_get_current_line() == 'new' and vim.bo.readonly and not vim.bo.modifiable)
assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 1, 1 }))
assert(vim.bo[editable_source].modified and vim.api.nvim_buf_get_lines(editable_source, 1, 2, false)[1] == 'Unsaved source edit', 'Source draft lost while opening snapshot')
assert(snapshot_win == source_win and #vim.api.nvim_list_tabpages() == initial_tabs + 1, 'Another path created another source tab')
editor_defaults(source_win)
-- Returning to a hidden, edited source restores that buffer in the same tab.
vim.api.nvim_set_current_win(log_win); vim.api.nvim_win_set_cursor(0, { 4, 0 }); key('gf')
assert(vim.api.nvim_get_current_buf() == editable_source and vim.bo.modified)
assert(vim.api.nvim_get_current_win() == source_win and #vim.api.nvim_list_tabpages() == initial_tabs + 1)
editor_defaults(source_win)
for _, row in ipairs({ 14, 16, 18 }) do
  vim.api.nvim_set_current_win(log_win); vim.api.nvim_win_set_cursor(0, { row, 0 })
  local tabs = #vim.api.nvim_list_tabpages(); key('gf')
  assert(vim.api.nvim_get_current_win() == log_win and #vim.api.nvim_list_tabpages() == tabs, 'Invalid location created an empty source tab')
end
-- A pending retry must not expose previous row-to-location data.
f.ci_delay = 80; key('R'); key('gf'); assert(vim.api.nvim_get_current_win() == log_win)
ui.wait(function() return vim.api.nvim_buf_get_lines(log, 3, 4, false)[1] == body[1] end)
vim.api.nvim_set_current_win(detail_win); key('q')
assert(vim.api.nvim_get_current_win() == pr_win and vim.api.nvim_win_is_valid(source_win) and vim.api.nvim_win_is_valid(snapshot_win))
assert(vim.api.nvim_buf_is_valid(snapshot) and vim.bo[editable_source].modified)
-- The repository's source destination survives closing/reopening CI details.
f.ci_delay = 2
ui.key('<CR>', ui.row('test: FAILURE'))
detail, detail_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
ui.wait(function() return ci.details(detail) ~= nil end); key('<CR>')
log, log_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
ui.wait(function() return vim.api.nvim_buf_get_lines(log, 3, 4, false)[1] == body[1] end)
vim.api.nvim_win_set_cursor(0, { 12, 0 }); key('gf')
assert(vim.api.nvim_get_current_win() == source_win and #vim.api.nvim_list_tabpages() == initial_tabs + 1, 'Reopening CI lost the source destination')
editor_defaults(source_win)
-- A user-repurposed destination is preserved, then exactly one new source tab
-- is created. The user's unsaved work must not become the reuse slot.
local user_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(user_buf, 0, -1, false, { 'User work in the old source tab' })
vim.api.nvim_win_set_buf(source_win, user_buf)
vim.api.nvim_set_current_win(log_win); vim.api.nvim_win_set_cursor(0, { 4, 0 }); key('gf')
local replacement_win = vim.api.nvim_get_current_win()
assert(replacement_win ~= source_win and vim.api.nvim_win_get_buf(source_win) == user_buf and vim.bo[user_buf].modified)
assert(vim.api.nvim_get_current_buf() == editable_source and vim.bo.modified)
assert(#vim.api.nvim_list_tabpages() == initial_tabs + 2)
editor_defaults(replacement_win)
-- Failure after switching a reusable destination restores its previous buffer.
local objects = require('git.objects'); local open = objects.open
objects.open = function(...)
  open(...)
  error('simulated source load failure')
end
vim.api.nvim_set_current_win(log_win); vim.api.nvim_win_set_cursor(0, { 12, 0 }); key('gf')
assert(vim.api.nvim_get_current_win() == log_win and vim.api.nvim_win_get_buf(replacement_win) == editable_source)
assert(#vim.api.nvim_list_tabpages() == initial_tabs + 2 and vim.bo[editable_source].modified)
-- A failed new destination is closed, including on repeated attempts.
vim.api.nvim_win_close(replacement_win, true)
local remaining_tabs = #vim.api.nvim_list_tabpages()
for _ = 1, 2 do key('gf'); assert(vim.api.nvim_get_current_win() == log_win and #vim.api.nvim_list_tabpages() == remaining_tabs) end
objects.open = open
key('gf'); local recreated_win = vim.api.nvim_get_current_win()
assert(vim.b.git_object.path == 'added.txt' and #vim.api.nvim_list_tabpages() == remaining_tabs + 1)
editor_defaults(recreated_win)
vim.api.nvim_set_current_win(detail_win); key('q')
assert(vim.api.nvim_win_is_valid(source_win) and vim.api.nvim_win_get_buf(source_win) == user_buf and vim.bo[user_buf].modified)
f.cleanup()
print('PASS: diagnostic/root navigation, editor defaults, bounded source tabs, captured snapshots, drafts, repurposed/closed destinations and failed-load cleanup')
