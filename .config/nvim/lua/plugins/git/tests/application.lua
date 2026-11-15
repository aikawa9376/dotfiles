local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.rtp:prepend(plugin)
vim.g.git_status_auto_fetch = false
vim.o.hidden = true
local root = vim.fn.tempname() .. ' application repo'
vim.fn.mkdir(root, 'p')
local function git(args)
  local cmd = { 'git', '-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false' }
  vim.list_extend(cmd, args)
  local result = vim.system(cmd, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end
git({ 'init', '-qb', 'main' })
vim.fn.writefile({ 'original' }, root .. '/file.txt')
git({ 'add', '.' }); git({ 'commit', '-qm', 'initial' })
vim.fn.writefile({ 'changed' }, root .. '/file.txt')
vim.api.nvim_set_current_dir(root)
require('git').setup()
local app = require('git.features.application')
local status = require('git.features.status')
local home = app.start(root)
local home_win, home_tab = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_tabpage()
assert(vim.bo.filetype == 'gitstatus' and #vim.api.nvim_list_tabpages() == 1)
assert(vim.o.showtabline == 0)
assert(vim.wait(5000, function() return not require('git.features.loading').busy(home) end, 10))
local function press(key)
  local map = vim.fn.maparg(key, 'n', false, true)
  assert(map.callback, 'missing mapping: ' .. key)
  map.callback()
end
local function home_again()
  assert(vim.api.nvim_get_current_win() == home_win)
  assert(vim.api.nvim_get_current_buf() == home)
  assert(vim.api.nvim_get_current_tabpage() == home_tab)
end
local function select_file()
  assert(status.focus_section(home, 'unstaged', { refresh = false }))
end
select_file(); press('<CR>')
assert(vim.wait(500, function() return vim.fn.maparg('q', 'n', false, true).desc == 'Return to Git status' end, 5))
assert(vim.api.nvim_buf_get_name(0) == root .. '/file.txt')
assert(#vim.api.nvim_list_tabpages() == 2)
assert(vim.api.nvim_win_get_buf(home_win) == home)
local file = vim.api.nvim_get_current_buf()
press('q'); home_again()
assert(#vim.api.nvim_list_tabpages() == 1)

-- Staged blobs are inspected in their own tab too, with the same q behavior.
git({ 'add', 'file.txt' })
status.reload_buffer(home)
assert(vim.wait(5000, function()
  if require('git.features.loading').busy(home) then return false end
  for row = 1, vim.api.nvim_buf_line_count(home) do
    local entry = require('git.features.status_renderer').entry_at(home, row)
    if entry and entry.section == 'staged' and entry.path == 'file.txt' then
      vim.api.nvim_win_set_cursor(home_win, { row, 0 })
      return true
    end
  end
  return false
end, 10))
press('<CR>')
assert(vim.wait(1000, function() return vim.b.git_object ~= nil end, 5))
assert(vim.wait(500, function() return vim.fn.maparg('q', 'n', false, true).desc == 'Return to Git status' end, 5))
press('q'); home_again()

-- Git/Git! in a child view reuse the home instead of creating a second status.
local win = app.file_window(home_win)
vim.api.nvim_win_set_buf(win, file)
assert(status.open({ work_tree = root, tab = true }) == home)
home_again()
vim.api.nvim_set_current_win(win)
vim.cmd('tabclose')
assert(vim.wait(500, function() return vim.api.nvim_get_current_win() == home_win end, 5))

-- Even a direct :edit must keep the home panel available.
vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/file.txt'))
assert(vim.wait(500, function() return vim.api.nvim_get_current_tabpage() ~= home_tab end, 5))
assert(vim.api.nvim_win_get_buf(home_win) == home)
vim.api.nvim_buf_set_lines(0, 0, 1, false, { 'unsaved' })
local dirty = vim.api.nvim_get_current_buf()
assert(app.close_view() == false)
assert(vim.bo[dirty].modified and vim.api.nvim_get_current_buf() == dirty)
vim.cmd('write')
assert(app.close_view()); home_again()

-- Native commit q may restore its original empty buffer; discard that empty
-- inspection tab rather than stranding the application away from status.
local commit_win = app.file_window(home_win)
vim.api.nvim_win_call(commit_win, function() require('git.features.commit').open({ work_tree = root, revision = 'HEAD' }) end)
assert(vim.b.custom_git_commit)
press('q')
assert(vim.wait(1000, function() return vim.api.nvim_get_current_win() == home_win end, 5))
assert(#vim.api.nvim_list_tabpages() == 1)

-- RPC Git editors keep their own write/close protocol, not the file q mapping.
local editor_win = app.file_window(home_win)
local message = root .. '/.git/COMMIT_EDITMSG'
vim.fn.writefile({ 'message' }, message)
vim.api.nvim_win_call(editor_win, function()
  vim.cmd('edit ' .. vim.fn.fnameescape(message))
  vim.bo.filetype = 'gitcommit'
end)
vim.wait(30, function() return false end)
assert(vim.fn.maparg('q', 'n', false, true).desc ~= 'Return to Git status')
vim.cmd('tabclose')
assert(vim.wait(500, function() return vim.api.nvim_get_current_win() == home_win end, 5))

-- A cancelled exit after an explicit home-window close recreates a usable home.
local original_cmd = vim.cmd
local attempted
vim.cmd = setmetatable({}, { __index = original_cmd, __call = function(_, command)
  if command == 'confirm qall' then attempted = true; return end
  return original_cmd(command)
end })
local extra = app.file_window(home_win)
vim.api.nvim_win_set_buf(extra, file)
vim.api.nvim_win_close(home_win, false)
assert(vim.wait(1000, function() return attempted and vim.bo.filetype == 'gitstatus' end, 5))
vim.cmd = original_cmd
assert(vim.api.nvim_get_current_buf() == home)
vim.fn.delete(root, 'rf')
print('PASS: application home, file/index tabs, dirty protection, commit return, editor protocol, and cancelled root close')
