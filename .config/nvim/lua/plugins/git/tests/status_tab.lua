-- Run from plugin root: nvim --headless --clean -u NONE -l tests/status_tab.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
vim.opt.rtp:prepend(plugin)

local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end
git({ 'init', '-qb', 'main' })
git({ 'config', 'user.name', 'Test' })
git({ 'config', 'user.email', 'test@example.invalid' })
vim.fn.writefile({ 'one' }, root .. '/file.txt')
git({ 'add', 'file.txt' })
git({ 'commit', '-qm', 'first' })

require('git').setup()
vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/file.txt'))
local file_win = vim.api.nvim_get_current_win()
vim.cmd('G')
local status_buf = vim.api.nvim_get_current_buf()
assert(vim.bo.filetype == 'fugitivestatus' and #vim.api.nvim_list_tabpages() == 1
  and #vim.api.nvim_tabpage_list_wins(0) == 2, 'G should open status in a split')

vim.api.nvim_set_current_win(file_win)
vim.cmd('G!')
local status_tab = vim.api.nvim_get_current_tabpage()
assert(vim.api.nvim_get_current_buf() == status_buf and #vim.api.nvim_list_tabpages() == 2
  and #vim.api.nvim_tabpage_list_wins(status_tab) == 1, 'G! should open status in a new tab')
assert(vim.api.nvim_tabpage_get_var(status_tab, 'git_status_work_tree') == root,
  'status tab should retain its repository identity')

vim.api.nvim_set_current_win(file_win)
vim.cmd('G! status')
assert(vim.api.nvim_get_current_tabpage() == status_tab and #vim.api.nvim_list_tabpages() == 2,
  'G! status should return to the existing status tab')

local spec = dofile(plugin .. '/init.lua')
local tab_mapping
for _, mapping in ipairs(spec.keys) do
  if mapping[1] == '<Leader>gS' then tab_mapping = mapping[2]; break end
end
assert(tab_mapping == '<cmd>G!<CR>', '<Leader>gS should open the tab status command')

vim.api.nvim_set_current_win(file_win)
vim.api.nvim_cmd({ cmd = 'G', bang = true }, {})
assert(vim.api.nvim_get_current_tabpage() == status_tab and #vim.api.nvim_list_tabpages() == 2,
  'repeated tab status should reuse the tab')

vim.fn.delete(root, 'rf')
print('PASS: G opens a split, G! opens and reuses a status tab, and leader gS points to G!')
