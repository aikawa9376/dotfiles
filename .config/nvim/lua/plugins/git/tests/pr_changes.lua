local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local ui = require('helpers.pr_ui').new(f)
local view = require('git.features.pr')
local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'xt', false)
end
local function marker(expected)
  local row = ui.row('Changes (')
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(ui.buf, vim.api.nvim_create_namespace('git_pr_status'),
    { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    if mark[4].sign_text then
      assert(mark[4].sign_text:gsub('%s+$', '') == expected and mark[4].sign_hl_group == 'Title'); return
    end
  end
  error('Missing Changes fold marker')
end
local function hidden()
  marker('▸'); assert(not pcall(ui.row, 'M file name.txt') and not pcall(ui.row, '+TWO'))
  assert(ui.row('Review threads (3)') and #view.model(ui.buf).entries == 4)
end
local function shown()
  marker('▾'); assert(ui.row('M file name.txt') and ui.row('+TWO'))
  assert(not pcall(ui.row, '+new'), 'Changes fold changed another file expansion')
  assert(view.entry_at(ui.buf, ui.row('+TWO')).path == 'file name.txt')
end
ui.open(); marker('▾')
assert(ui.row('M file name.txt') and not pcall(ui.row, '+TWO'))
ui.key('o', ui.row('M file name.txt')); ui.wait(function() return pcall(ui.row, '+TWO') end)
local title = ui.row('PR title')
vim.api.nvim_buf_set_lines(ui.buf, title - 1, title, false, { 'Unsaved title' })
vim.api.nvim_buf_set_lines(ui.buf, title + 1, title + 1, false, { 'Unsaved paragraph' })
ui.key('o', ui.row('Commits ('))
local calls = #f.calls
for _, key in ipairs({ 'o', '=', '<Tab>', '<CR>' }) do
  ui.source(); vim.api.nvim_win_set_cursor(0, { ui.row('Changes ('), 0 }); press(key)
  hidden()
  assert(ui.row('Unsaved title') and ui.row('Unsaved paragraph') and vim.bo[ui.buf].modified)
  assert(ui.row(f.head:sub(1, 7) .. '\t'), 'Changes fold collapsed Commits')
  press(key); shown()
end
ui.key('<', ui.row('Changes (')); hidden()
ui.key('>', ui.row('Changes (')); shown()
assert(#f.calls == calls, 'Changes folding performed remote requests')
for _, entry in ipairs(view.model(ui.buf).entries) do if entry.path ~= 'file name.txt' then
  assert(entry.patch == nil, 'Opening Changes unnecessarily loaded collapsed file patches')
end end
-- Both independent folds can remain closed without losing draft or file state.
ui.key('<', ui.row('Changes (')); ui.key('<', 1); hidden()
assert(not pcall(ui.row, 'CI:') and not pcall(ui.row, 'Created by:'))
ui.key('>', 1); hidden(); assert(ui.row('CI:'))
local old = view.model(ui.buf)
view.refresh(ui.buf, false, true); ui.wait(function() return view.model(ui.buf) ~= old end)
hidden(); assert(ui.row('Unsaved title') and vim.bo[ui.buf].modified)
ui.key('>', ui.row('Changes (')); shown()
-- i and both comment-navigation directions reveal folded Changes before moving.
ui.key('<', ui.row('Changes ('))
vim.api.nvim_win_set_cursor(0, { 1, 0 }); press('i')
ui.wait(function() return view.entry_at(ui.buf, vim.fn.line('.')) ~= nil end)
marker('▾'); assert(vim.api.nvim_get_mode().mode == 'n')
ui.key('<', ui.row('Changes (')); vim.api.nvim_win_set_cursor(0, { 1, 0 }); press(']C')
ui.wait(function() return vim.api.nvim_get_current_line() == '-two' and vim.b[ui.buf].git_pr_preview ~= nil end)
marker('▾'); require('git.features.pr_comment_preview').close(ui.buf)
ui.key('<', ui.row('Changes (')); ui.key('[C', ui.row('Review threads ('))
ui.wait(function() return vim.api.nvim_get_current_line():find('new.txt', 1, true) and vim.b[ui.buf].git_pr_preview ~= nil end)
marker('▾'); require('git.features.pr_comment_preview').close(ui.buf)
-- An empty Changes section is still operable, retaining the selected fold state.
ui.key('<', ui.row('Changes ('))
f.pr.headRefOid = f.base_head; f.comments = { {} }
f.git({ 'update-ref', 'refs/pull/7/head', f.base_head })
old = view.model(ui.buf); view.refresh(ui.buf, false, true)
ui.wait(function() return view.model(ui.buf) ~= old end)
assert(ui.row('Changes (0)') and #view.model(ui.buf).entries == 0); marker('▸')
ui.key('>', ui.row('Changes (')); marker('▾')
ui.key('<CR>', ui.row('Changes (')); marker('▸')
assert(ui.row('Unsaved title') and ui.row('Unsaved paragraph') and vim.bo[ui.buf].modified)
vim.api.nvim_buf_delete(ui.buf, { force = true }); f.cleanup()
print('PASS: default-open Changes folding, real aliases/Enter, preserved file/history/header state and drafts, no eager patches, refresh persistence, i/comment navigation and empty changes')
