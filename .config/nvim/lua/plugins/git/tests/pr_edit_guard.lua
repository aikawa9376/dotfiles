local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local ui = require('helpers.pr_ui').new(f)
local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'xt', false)
end
local function contents() return vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false) end
local function settle() vim.wait(30, function() return false end, 5) end
ui.open(); ui.key('>', ui.row('M file name.txt'))
ui.wait(function() return pcall(ui.row, '+TWO') end)
local original = contents()
-- Actual native input keys must neither enter Insert mode nor alter a diff.
for _, key in ipairs({ 'a', 'I', 'gI', '<Insert>', 's', 'S', 'C', 'x', 'X', 'p', 'P' }) do
  ui.source(); vim.api.nvim_win_set_cursor(0, { ui.row('+TWO'), 0 })
  vim.v.errmsg = ''; press(key .. '<Esc>'); settle()
  assert(vim.api.nvim_get_mode().mode == 'n' and vim.deep_equal(contents(), original), 'Diff edited by ' .. key)
  assert(vim.v.errmsg == '', 'Protected key raised an error: ' .. key .. ': ' .. vim.v.errmsg)
end
-- The same a/I/o keys still edit metadata normally, including growing its rows.
vim.api.nvim_win_set_cursor(0, { ui.row('PR title'), 0 }); press('aX<Esc>')
assert(ui.row('PXR title'))
press('IY<Esc>'); assert(ui.row('YPXR title'))
vim.api.nvim_win_set_cursor(0, { ui.row('Second line'), 0 }); press('oNew paragraph<Esc>')
assert(ui.row('New paragraph') and vim.bo[ui.buf].modified)
local accepted = contents()
-- Bypassing a mapping or crossing into a diff from a legal draft row is caught
-- by the buffer guard. The most recent valid draft must survive unchanged.
vim.api.nvim_win_set_cursor(0, { ui.row('Second line'), 0 })
vim.cmd('normal! dG'); settle()
assert(vim.deep_equal(contents(), accepted) and vim.bo[ui.buf].modified, 'Range delete lost draft/protected text')
vim.api.nvim_buf_set_lines(ui.buf, 0, 1, false, { 'tampered header' }); settle()
assert(vim.deep_equal(contents(), accepted), 'Programmatic header edit escaped guard')
local row = ui.row('+TWO')
vim.api.nvim_buf_set_lines(ui.buf, row - 1, row, false, { 'tampered diff' }); settle()
assert(vim.deep_equal(contents(), accepted), 'Diff paste escaped guard')
-- Visual ranges spanning the boundary are rejected before entering Insert mode.
vim.api.nvim_win_set_cursor(0, { ui.row('New paragraph'), 0 })
press('Vjc<Esc>'); settle()
assert(vim.deep_equal(contents(), accepted) and vim.api.nvim_get_mode().mode == 'n')
-- Rendering/folding is trusted and keeps the draft; navigation remains intact.
ui.key('<', ui.row('M file name.txt'))
assert(not pcall(ui.row, '+TWO') and ui.row('YPXR title') and ui.row('New paragraph'))
vim.api.nvim_win_set_cursor(0, { 1, 0 }); press('i')
ui.wait(function() return require('git.features.pr').entry_at(ui.buf, vim.fn.line('.')) ~= nil end)
assert(vim.api.nvim_get_mode().mode == 'n')
-- Saving posts just the accepted metadata, never the protected edits.
vim.cmd('write'); ui.wait(function() return f.pr.title == 'YPXR title' end); ui.loaded()
assert(f.pr.body:find('New paragraph', 1, true) and not vim.bo[ui.buf].modified)
assert(not f.pr.body:find('tampered', 1, true) and not f.pr.body:find('@@', 1, true))
vim.api.nvim_buf_delete(ui.buf, { force = true }); f.cleanup()
print('PASS: native input stays outside diffs, metadata edits grow normally, range/paste/header edits restore the accepted draft, visual boundaries, trusted folding, i navigation and metadata-only save')
