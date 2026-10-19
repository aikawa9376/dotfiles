-- Run: nvim --headless --clean -u NONE -l tests/panel_close.lua
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
vim.opt.rtp:prepend(plugin)
vim.g.git_status_auto_fetch = false
local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false' }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait(); assert(result.code == 0, result.stderr)
end
git({ 'init', '-qb', 'main' })
vim.fn.writefile({ 'one' }, root .. '/file.txt')
git({ 'add', '.' }); git({ 'commit', '-qm', 'first' })
vim.fn.writefile({ 'stashed' }, root .. '/file.txt'); git({ 'stash', 'push', '-qm', 'saved change' })
require('git').setup()
local utilities = require('utilities')
vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/file.txt'))
local source = vim.api.nvim_get_current_buf()
vim.cmd('vsplit'); vim.cmd('belowright split')
local source_win = vim.api.nvim_get_current_win()
vim.wo.number, vim.wo.relativenumber, vim.wo.wrap, vim.wo.list = true, true, true, true
vim.wo.signcolumn, vim.wo.foldmethod, vim.wo.foldenable, vim.wo.foldcolumn = 'yes', 'indent', true, '1'
local function window_options()
  local values = {}
  for _, name in ipairs({ 'number', 'relativenumber', 'wrap', 'list', 'signcolumn', 'foldmethod', 'foldenable', 'foldcolumn' }) do
    values[name] = vim.api.nvim_get_option_value(name, { win = 0, scope = 'local' })
  end
  return values
end
local source_options = window_options()
local function snapshot()
  local sizes = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    sizes[win] = { vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win) }
  end
  return { layout = vim.fn.winlayout(), sizes = sizes, tab = vim.api.nvim_get_current_tabpage() }
end
local function press_q() assert(vim.fn.maparg('q', 'n', false, true).callback)() end
for _, command in ipairs({ 'G', 'GitCommit', 'GitLog', 'Gbranch', 'Gstash', 'Greflog' }) do
  vim.api.nvim_set_current_win(source_win)
  if command == 'GitCommit' then vim.cmd('belowright split') end
  vim.cmd(command)
  local panel, panel_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local before = snapshot()
  local status = vim.bo[panel].filetype == 'gitstatus'
  press_q()
  assert(vim.deep_equal(snapshot(), before), command .. ': q changed windows or their sizes')
  assert(vim.api.nvim_get_current_win() == panel_win, command .. ': q moved focus')
  assert(vim.api.nvim_get_current_buf() == source, command .. ': q did not restore the source buffer')
  assert(vim.deep_equal(window_options(), source_options), command .. ': panel display options leaked into the file')
  assert(status == vim.api.nvim_buf_is_loaded(panel), command .. ': wrong buffer lifetime')
  -- Close the preserved test window explicitly before opening the next panel.
  vim.api.nvim_win_close(panel_win, false)
end

-- A modified commit keeps both its draft and layout when closing is cancelled.
vim.api.nvim_set_current_win(source_win)
vim.cmd('GitCommit')
local commit = vim.api.nvim_get_current_buf()
local before = snapshot()
local row
for index, line in ipairs(vim.api.nvim_buf_get_lines(commit, 0, -1, false)) do
  if line == 'first' then row = index; break end
end
vim.api.nvim_buf_set_lines(commit, assert(row) - 1, row, false, { 'draft' })
local confirm = vim.fn.confirm
vim.fn.confirm = function() return 3 end
press_q()
assert(vim.api.nvim_get_current_buf() == commit and vim.bo[commit].modified)
assert(vim.deep_equal(snapshot(), before))
vim.fn.confirm = function() return 2 end
press_q(); vim.fn.confirm = confirm
assert(vim.deep_equal(snapshot(), before) and not vim.api.nvim_buf_is_loaded(commit))

-- With no source or alternate, use a fresh normal buffer in the same window.
vim.cmd('only')
for _, buf in ipairs(vim.api.nvim_list_bufs()) do pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
local panel = vim.api.nvim_create_buf(false, true)
vim.bo[panel].bufhidden = 'wipe'
vim.api.nvim_set_current_buf(panel)
before = snapshot()
utilities.smart_close()
assert(vim.deep_equal(snapshot(), before) and vim.bo.buftype == '' and vim.bo.buflisted)
assert(not vim.api.nvim_buf_is_valid(panel))

-- The sole regular window in a dedicated tab still closes that tab, even with a float.
local origin_tab = vim.api.nvim_get_current_tabpage()
vim.cmd('tabnew')
panel = vim.api.nvim_get_current_buf(); vim.bo[panel].buftype = 'nofile'; vim.bo[panel].bufhidden = 'wipe'
local win = vim.api.nvim_get_current_win()
vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false,
  { relative = 'editor', row = 0, col = 0, width = 10, height = 2 })
vim.api.nvim_set_current_win(win)
utilities.smart_close()
assert(vim.api.nvim_get_current_tabpage() == origin_tab and #vim.api.nvim_list_tabpages() == 1)

-- A floating panel itself closes its window without replacing ordinary windows.
before = snapshot()
local float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true,
  { relative = 'editor', row = 0, col = 0, width = 10, height = 2 })
utilities.smart_close()
assert(not vim.api.nvim_win_is_valid(float) and vim.deep_equal(snapshot(), before))
vim.fn.delete(root, 'rf')
print('PASS: panel q preserves split layout/source, status cache, commit draft guard, empty fallback, tabs and floats')
