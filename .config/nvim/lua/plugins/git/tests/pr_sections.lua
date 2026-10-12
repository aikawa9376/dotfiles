local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local ui = require('helpers.pr_ui').new(f)
local view = require('git.features.pr')
f.discussion = { { id = 1, body = 'Discussion body', user = { login = 'reviewer' }, created_at = '2026-10-12T01:00:00Z' } }
local definition_jumps = 0
vim.keymap.set('n', 'gd', function() definition_jumps = definition_jumps + 1 end, { desc = 'Existing definition jump' })
local function press(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), 'xt', false)
  assert(vim.api.nvim_get_current_buf() == ui.buf, key .. ' opened another view')
end
local function current() return vim.api.nvim_get_current_line() end
local function absent(value) assert(not pcall(ui.row, value), 'Unexpected expanded row: ' .. value) end
ui.open()
press('gd'); assert(definition_jumps == 1, 'PR navigation replaced the existing definition shortcut')
-- An LSP may attach after PR mappings. Its definition mapping stays intact,
-- and the separate Conversation key still dispatches through the gc prefix.
vim.keymap.set('n', 'gd', function() definition_jumps = definition_jumps + 1 end,
  { buffer = ui.buf, desc = 'Existing LSP definition jump' })
press('gd'); assert(definition_jumps == 2)
local requests = #f.calls
press('gp'); assert(current():match('^Commits %('), 'Closed commits should focus their heading')
press('gu'); assert(view.entry_at(ui.buf, vim.fn.line('.')), 'Open changes should focus their first file')
press('gh'); assert(vim.fn.line('.') == 1)
press('gU'); assert(current():match('^CI:'), 'Closed CI should focus its summary')
press('gco'); assert(current():match('^Conversation %('), 'Closed Conversation should focus its heading')
assert(vim.fn.maparg('gd', 'n', false, true).desc == 'Existing LSP definition jump')
absent('Discussion body')
absent('test: FAILURE')
assert(vim.fn.maparg('gc', 'n', false, true).desc == 'Open review thread / reply', 'CI navigation replaced comment access')
assert(#f.calls == requests, 'Section navigation made API requests')
for _, entry in ipairs(view.model(ui.buf).entries) do assert(not entry.patch, 'Section navigation fetched patches') end

-- Navigation works from the editable draft, accounting for extra body rows
-- without native gp pasting or gu changing case.
local title = ui.row('PR title')
vim.api.nvim_buf_set_lines(ui.buf, title - 1, title, false, { 'Unsaved PR title' })
vim.api.nvim_buf_set_lines(ui.buf, title + 1, title + 1, false, { 'Extra body line', 'Another body line' })
local draft = vim.api.nvim_buf_get_lines(ui.buf, title - 1, ui.row('Commits (') - 2, false)
for _, key in ipairs({ 'gp', 'gu', 'gh', 'gU', 'gco' }) do
  vim.api.nvim_win_set_cursor(0, { ui.row('Unsaved PR title'), 0 })
  press(key)
  if key == 'gp' then assert(current():match('^Commits %('))
  elseif key == 'gu' then assert(view.entry_at(ui.buf, vim.fn.line('.')))
  elseif key == 'gh' then assert(vim.fn.line('.') == 1)
  elseif key == 'gco' then assert(current():match('^Conversation %('))
  else assert(current():match('^CI:')) end
end
assert(vim.bo[ui.buf].modified and f.pr.title == 'PR title')
ui.key('<', ui.row('Changes ('))
press('gu'); assert(current():match('^Changes %('), 'Collapsed changes were expanded')
ui.key('<', 1); absent('CI:')
press('gh'); assert(vim.fn.line('.') == 1); absent('CI:')
press('gU'); assert(current():match('^CI:')); absent('test: FAILURE')
press('gu'); assert(current():match('^Changes %('), 'Revealing CI reset the Changes fold')
assert(vim.deep_equal(draft, vim.api.nvim_buf_get_lines(ui.buf, ui.row('Unsaved PR title') - 1, ui.row('Commits (') - 2, false)), 'Revealing the CI parent erased the draft')

ui.key('>', ui.row('Commits (')); press('gp')
local first_commit = view.model(ui.buf).commits[1]
assert(current():find(first_commit.hash:sub(1, 7), 1, true), 'Open commits should focus their first item')
ui.key('>', ui.row('CI:')); press('gU')
assert(view.check_at(ui.buf, vim.fn.line('.')), 'Open CI should focus its first result')
ui.key('<', 1); press('gU')
assert(view.check_at(ui.buf, vim.fn.line('.')), 'CI parent reveal lost the result fold state')
press('gp'); assert(current():find(first_commit.hash:sub(1, 7), 1, true), 'CI parent reveal reset the commits fold')
press('gu'); assert(current():match('^Changes %('))
ui.key('>', ui.row('Conversation (')); press('gco')
assert(view.conversation_at(ui.buf, vim.fn.line('.')).key == 'comment:1', 'Open Conversation should focus its first item')
ui.key('<', 1); press('gco')
assert(view.conversation_at(ui.buf, vim.fn.line('.')).key == 'comment:1', 'Header folding lost the Conversation target')
ui.key('<', ui.row('Conversation (')); press('gco')
assert(current():match('^Conversation %('), 'Conversation navigation changed its fold')
assert(#f.calls == requests, 'Local section folds/navigation made API requests')
vim.api.nvim_buf_delete(ui.buf, { force = true })

-- Empty sections retain a useful heading without delayed navigation or views.
f.pr.baseRefOid, f.pr.headRefOid, f.pr.statusCheckRollup = f.head, f.head, vim.NIL
f.discussion = {}
ui.open()
press('gp'); assert(current() == 'Commits (0)')
press('gu'); assert(current():match('^Changes %(0%)'))
press('gU'); assert(current():match('^CI:'))
press('gco'); assert(current() == 'Conversation (0)')
ui.key('>', ui.row('Conversation (')); press('gco')
assert(current() == 'Conversation (0)', 'Empty expanded Conversation should focus its heading')
press('gh'); assert(vim.fn.line('.') == 1)
vim.api.nvim_buf_delete(ui.buf, { force = true }); f.cleanup()
print('PASS: section keys, gc prefix coexistence, expanded/collapsed/empty targets, draft row shifts, nested CI reveal and request-free navigation')
