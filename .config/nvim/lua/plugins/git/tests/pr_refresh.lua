-- nvim --headless --clean -u NONE -l tests/pr_refresh.lua
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local ui = require('helpers.pr_ui').new(f)
local view = require('git.features.pr')
local function patch_rows()
  local count = 0
  for row = 1, vim.api.nvim_buf_line_count(ui.buf) do
    local _, info = view.entry_at(ui.buf, row)
    if info and info.patch_row then count = count + 1 end
  end
  return count
end
local function wait_refresh(previous)
  ui.wait(function() return view.model(ui.buf) ~= previous and not require('git.features.async').busy(f.root) end)
end
local function folds()
  local result = {}
  local lines = vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(ui.buf,
    vim.api.nvim_create_namespace('git_pr_status'), 0, -1, { details = true })) do
    if mark[4].sign_text then
      local line = lines[mark[2] + 1]
      local label = line:match('^(Repo:)') or line:match('^(CI:)') or line:match('^(Conversation)')
        or line:match('^(Commits)') or line:match('^(Changes)')
      if label then result[label] = mark[4].sign_text end
    end
  end
  return result
end
ui.open()
ui.key('>', ui.row('Commits ('))
ui.key('>', ui.row('Conversation ('))
ui.key('<', 1)
ui.expand_files(); ui.wait(function()
  return pcall(ui.row, '+TWO') and pcall(ui.row, '+new') and pcall(ui.row, '-delete this')
end)
local previous, section_folds = view.model(ui.buf), folds()
ui.key('R', ui.row('+TWO'))
assert(patch_rows() == 0, 'R did not immediately close all file diffs')
assert(vim.api.nvim_get_current_line() == 'M file name.txt', 'R did not retain the selected file')
wait_refresh(previous)
assert(patch_rows() == 0 and vim.deep_equal(folds(), section_folds), 'R changed section folds or reopened diffs')
ui.key('>', 1)

-- Automatic refresh retains expanded files; explicit R clears choices hidden
-- by the Changes fold as well, and reopening the section cannot revive them.
ui.key('>', ui.row('M file name.txt')); ui.wait(function() return patch_rows() > 0 end)
previous = view.model(ui.buf)
view.refresh(ui.buf); wait_refresh(previous)
assert(patch_rows() > 0, 'ordinary refresh collapsed file diffs')
ui.key('<', ui.row('Changes ('))
previous, section_folds = view.model(ui.buf), folds()
ui.key('R', ui.row('Changes (')); wait_refresh(previous)
assert(vim.deep_equal(folds(), section_folds), 'R opened the folded Changes section')
ui.key('>', ui.row('Changes ('))
assert(patch_rows() == 0, 'R retained hidden file expansion')

-- Keeping an unsaved title cancels both refresh and collapse. Accepting the
-- existing discard prompt closes diffs and reloads the remote title.
ui.key('>', ui.row('M file name.txt')); ui.wait(function() return patch_rows() > 0 end)
local title = ui.row('PR title')
vim.api.nvim_buf_set_lines(ui.buf, title - 1, title, false, { 'Unsaved title' })
local confirm, calls, rows = vim.fn.confirm, #f.calls, patch_rows()
vim.fn.confirm = function() return 2 end
ui.key('R', ui.row('M file name.txt'))
assert(ui.row('Unsaved title') and vim.bo[ui.buf].modified and patch_rows() == rows and #f.calls == calls,
  'canceling R changed the draft, diff state or remote requests')
vim.fn.confirm = function() return 1 end
previous = view.model(ui.buf)
ui.key('R', ui.row('M file name.txt')); wait_refresh(previous)
vim.fn.confirm = confirm
assert(ui.row('PR title') and not vim.bo[ui.buf].modified and patch_rows() == 0, 'confirmed R did not discard/reload and collapse')

-- The PR action menu uses the same collapse-and-refresh operation.
ui.key('>', ui.row('M file name.txt')); ui.wait(function() return patch_rows() > 0 end)
previous = view.model(ui.buf)
local refresh
for _, group in ipairs(view.action_groups(ui.buf)) do
  for _, action in ipairs(group.actions) do if action.key == 'R' then refresh = action end end
end
assert(refresh and refresh.label:find('Collapse', 1, true), 'action menu did not advertise collapse')
refresh.run(); wait_refresh(previous)
assert(patch_rows() == 0, 'menu R retained file diffs')

-- An expansion still fetching its patch cannot reopen files after R.
for _, entry in ipairs(view.model(ui.buf).entries) do entry.patch = nil end
previous = view.model(ui.buf)
ui.key('>', ui.row('M file name.txt'))
ui.key('R', ui.row('M file name.txt')); wait_refresh(previous)
assert(patch_rows() == 0, 'a late patch expansion undid R')

-- Collapse works even while an automatic refresh is already in flight.
ui.key('>', ui.row('M file name.txt')); ui.wait(function() return patch_rows() > 0 end)
f.delay = 30
previous = view.model(ui.buf)
view.refresh(ui.buf)
ui.key('R', ui.row('+TWO'))
assert(patch_rows() == 0, 'in-flight refresh prevented collapse')
wait_refresh(previous)
assert(patch_rows() == 0, 'in-flight refresh reopened collapsed diffs')
-- R in the editable title still starts native Replace mode, without fetching
-- or collapsing; panel refresh belongs to read-only rows and the action menu.
f.delay = 2
ui.key('>', ui.row('M file name.txt')); ui.wait(function() return patch_rows() > 0 end)
calls, rows = #f.calls, patch_rows()
vim.api.nvim_win_set_cursor(0, { ui.row('PR title'), 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('RX<Esc>', true, false, true), 'xt', false)
assert(ui.row('XR title') and vim.bo[ui.buf].modified and patch_rows() == rows and #f.calls == calls,
  'editable R refreshed/collapsed instead of replacing title text')
vim.api.nvim_buf_delete(ui.buf, { force = true }); f.cleanup()
print('PASS: PR R collapses all/hidden/pending diffs, preserves sections/file focus, protects drafts and keeps automatic refresh expansion')
