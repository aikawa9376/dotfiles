local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
local function git(args)
  local cmd = { 'git', '-C', root, '-c', 'user.name=Layout Test', '-c', 'user.email=test@example.invalid' }
  vim.list_extend(cmd, args)
  local result = vim.system(cmd, { text = true }):wait(); assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout or '')
end
git({ 'init', '-q' })
local lines = {}; for i = 1, 200 do lines[i] = 'line number ' .. i end
vim.fn.writefile(lines, root .. '/file.txt'); git({ 'add', '.' }); git({ 'commit', '-qm', 'layout' })
local hash = git({ 'rev-parse', 'HEAD' })
vim.cmd('edit ' .. root .. '/file.txt')
local code = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(code, { 140, 5 })
vim.fn.winrestview({ lnum = 140, col = 5, topline = 130 })
local before = vim.fn.winsaveview()
local blame = require('git.features.blame'); blame.setup(vim.api.nvim_create_augroup('BlameLayoutTest', {}))
local buf = blame.open()
assert(#vim.api.nvim_list_wins() == 1 and vim.deep_equal(vim.fn.winsaveview(), before))
assert(vim.wait(2000, function() return vim.fn.bufwinid(buf) ~= -1 end, 10))
local panel = vim.fn.bufwinid(buf)
local function assert_aligned(line)
  vim.cmd('redraw')
  local panel_row = vim.fn.screenpos(panel, line, 1).row
  local code_row = vim.fn.screenpos(code, line, 1).row
  assert(panel_row > 0 and panel_row == code_row,
    ('blame/code row %d is offset on screen: %d vs %d'):format(line, panel_row, code_row))
end
assert_aligned(140)
assert(vim.wo[panel].winbar:find(hash:sub(1, 8), 1, true), 'scrolled commit hash should stay in the panel winbar')
assert(vim.wo[panel].winbar:match('^%%=') and vim.wo[panel].winbar:match('%%=$'), 'sticky metadata should be centered')
local width = vim.api.nvim_win_get_width(panel)
for _ = 1, 3 do
  vim.cmd('redraw')
  vim.api.nvim_exec_autocmds('WinScrolled', { pattern = tostring(panel) })
  vim.wait(30, function() return false end, 10)
  local code_view = vim.api.nvim_win_call(code, vim.fn.winsaveview)
  assert(code_view.lnum == 140 and code_view.col == 5 and code_view.topline == before.topline, 'opening/layout events moved code view')
  assert(vim.api.nvim_win_get_width(panel) == width, 'initial width changed after display')
  assert_aligned(140)
end
vim.api.nvim_win_set_cursor(panel, { 141, 0 })
vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
assert(vim.api.nvim_win_get_cursor(code)[1] == 141 and vim.api.nvim_win_get_cursor(code)[2] == 5)
assert_aligned(141)
vim.api.nvim_win_call(panel, function() vim.fn.winrestview({ lnum = 1, topline = 1 }) end)
vim.api.nvim_exec_autocmds('WinScrolled', { pattern = tostring(panel) })
assert(vim.wait(500, function() return vim.wo[panel].winbar == '%=Blame panel%=' end, 10),
  'show the panel label when the commit header is visible')
vim.api.nvim_win_call(panel, function() vim.fn.winrestview({ lnum = 180, topline = 170 }) end)
vim.api.nvim_exec_autocmds('WinScrolled', { pattern = tostring(panel) })
assert(vim.wait(500, function() return vim.wo[panel].winbar:find(hash:sub(1, 8), 1, true) ~= nil end, 10),
  'restore sticky metadata after scrolling into the same long commit')
vim.api.nvim_win_call(code, function() vim.fn.winrestview({ lnum = 180, topline = 170, col = 5 }) end)
assert_aligned(180)
assert(not vim.wo[panel].cursorbind and not vim.wo[code].cursorbind, 'duplicate native cursor synchronization')
vim.fn.maparg('q', 'n', false, true).callback()
for _, b in ipairs(vim.api.nvim_list_bufs()) do pcall(vim.api.nvim_buf_delete, b, { force = true }) end
vim.fn.delete(root, 'rf')
print('PASS: no loading split, preserved deep-file view, stable width after redraw/layout, single cursor synchronization')
