-- Run: nvim --headless --clean -u NONE -l tests/status_folds.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path

local folds = require('git.features.status_folds')
local bufnr = vim.api.nvim_get_current_buf()
vim.wo.fillchars = 'fold:·'
local function render(stash_count)
  local lines = { 'Head: main', '', 'Untracked files (3)', '? a', '? b', '? c', '',
    ('Stashes (%d)'):format(stash_count) }
  for i = 1, stash_count do table.insert(lines, ('stash@{%d}'):format(i - 1)) end
  vim.list_extend(lines, { '', 'Unpushed [only] (3)', 'aaa', 'bbb', 'ccc' })
  folds.capture(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  folds.rebuild(bufnr)
  return 8, 10 + stash_count
end

local stash, commits = render(3)
assert(vim.fn.foldclosed(3) == -1, 'untracked should start open')
assert(vim.fn.foldclosed(stash) == stash, 'three stashes should start closed')
assert(vim.fn.foldclosed(commits) == -1, 'commits should start open')
assert(vim.wo.foldcolumn == '0', 'status fold column should not draw a vertical guide')
assert(vim.wo.signcolumn == 'yes:1', 'status gutter should hold the fold arrow')
assert(vim.opt_local.fillchars:get().fold == ' ', 'fold filler should be blank')
assert(vim.fn.foldtextresult(stash) == 'Stashes (3)', 'closed heading changed its text')
local marker_ns = vim.api.nvim_create_namespace('git_status_fold_markers')
local function marker(row)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, marker_ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })
  return marks[1] and vim.trim(marks[1][4].sign_text)
end
assert(marker(3) == '▾' and marker(stash) == '▸', 'open/closed arrows are incorrect')
vim.cmd('redraw')
assert(vim.fn.screenstring(3, 1) == '▾', 'open arrow is not visible in the gutter')
assert(vim.fn.screenstring(stash, 1) == '▸', 'closed arrow is not visible in the gutter')
assert(vim.fn.screenstring(stash, 30) == ' ', 'closed fold still shows filler dots')
assert(folds.toggle(bufnr, stash))
assert(vim.fn.foldclosed(stash) == -1, 'Tab should open stashes')
assert(marker(stash) == '▾', 'opened heading should show the down arrow')
vim.cmd(('%dfoldclose'):format(stash))
folds.rebuild(bufnr)
assert(vim.fn.foldclosed(stash) == stash, 'fold-column/normal fold state should survive refresh')
vim.cmd(('%dfoldopen'):format(stash))
stash = render(4)
assert(vim.fn.foldclosed(stash) == -1, 'open state should survive refreshed count')
assert(folds.toggle(bufnr, stash))
assert(vim.fn.foldclosed(stash) == stash, 'Tab should close stashes')
folds.cleanup(bufnr)
stash = render(2)
assert(vim.fn.foldclosed(stash) == -1, 'two stashes should start open')
assert(not folds.toggle(bufnr, 1), 'ordinary header should not toggle')

print('PASS: status section fold defaults, toggle, and refresh persistence')
