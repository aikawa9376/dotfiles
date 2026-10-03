-- Run: nvim --headless --clean -u NONE -l tests/dial_rebase.lua
-- Uses the installed dial plugin and its real normal/Visual operator mappings.
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
local dial = vim.fn.stdpath('data') .. '/lazy/dial.nvim'
assert(vim.fn.isdirectory(dial) == 1, 'Install dial.nvim to run this integration check')
vim.opt.runtimepath:prepend(vim.fn.stdpath('data') .. '/lazy/lazy.nvim')
local spec = dofile(vim.fs.dirname(plugin) .. '/dial.lua'); spec.dir = dial; spec.lazy = true
require('lazy').setup({ spec = { spec }, install = { missing = false }, checker = { enabled = false },
  change_detection = { enabled = false }, lockfile = vim.fn.tempname(),
  performance = { rtp = { reset = false }, cache = { enabled = false } } })
assert(not package.loaded['dial.config'], 'dial loaded before a trigger')
local function press(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), 'xt', false)
end
local hash = '123456789012'
for _, ft in ipairs({ 'gitrebaseplan', 'gitrebase' }) do
  vim.bo.filetype = ft
  assert(vim.wait(1000, function() return vim.fn.maparg('<C-a>', 'n', false, true).desc == 'Cycle rebase action' end, 5))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'pick ' .. hash .. ' pick 2026 true' })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local order = { 'reword', 'edit', 'squash', 'fixup', 'drop', 'pick' }
  for _, action in ipairs(order) do
    press('<C-a>'); assert(vim.api.nvim_get_current_line() == action .. ' ' .. hash .. ' pick 2026 true')
  end
  press('4<C-a>'); assert(vim.api.nvim_get_current_line():match('^fixup '))
  press('<C-x>'); assert(vim.api.nvim_get_current_line():match('^squash '))
  press('3<C-x>'); assert(vim.api.nvim_get_current_line():match('^pick '))
  for _, col in ipairs({ 5, 18 }) do
    vim.api.nvim_win_set_cursor(0, { 1, col }); press('<C-a>')
    assert(vim.api.nvim_get_current_line() == 'pick ' .. hash .. ' pick 2026 true', 'dial changed a hash or subject')
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'p ' .. hash .. ' one', 'pick ' .. hash .. ' two' })
  vim.api.nvim_win_set_cursor(0, { 1, 0 }); press('Vj<C-a><Esc>')
  local rows = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  assert(rows[1] == 'reword ' .. hash .. ' one' and rows[2] == 'reword ' .. hash .. ' two')
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'exec echo 123', 'break', '# pick 123456 label' })
  for i = 1, 3 do vim.api.nvim_win_set_cursor(0, { i, 0 }); press('<C-a>') end
  assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n') == 'exec echo 123\nbreak\n# pick 123456 label')
end
vim.bo.filetype = 'lua'; vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'count = 12' })
vim.api.nvim_win_set_cursor(0, { 1, 0 }); press('<C-a>'); assert(vim.api.nvim_get_current_line() == 'count = 13')
print('PASS: dial rebase action cycle, reverse/count/Visual/alias input, hash/subject guards and default integers')
