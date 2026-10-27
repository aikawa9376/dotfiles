-- Git views may disable wrapping without changing defaults for ordinary buffers.
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.rtp:prepend(plugin)
vim.g.git_status_auto_fetch = false
local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false' }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end
git({ 'init', '-qb', 'main' })
vim.fn.writefile({ 'before' }, root .. '/file.txt')
vim.fn.writefile({ 'deleted' }, root .. '/deleted.txt')
git({ 'add', '.' }); git({ 'commit', '-qm', 'initial' })
vim.fn.writefile({ 'after' }, root .. '/file.txt')
vim.fn.delete(root .. '/deleted.txt')
require('git').setup()
vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/file.txt'))
vim.o.wrap = true
local source_win = vim.api.nvim_get_current_win()

local function nowrap_view(label)
  assert(not vim.wo.wrap, label .. ': view should disable wrapping')
  assert(vim.go.wrap, label .. ': view changed the window default')
end
local function ordinary_buffer(label)
  vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, false))
  assert(vim.wo.wrap and vim.go.wrap, label .. ': ordinary buffer inherited nowrap')
end

-- Reuse the actual branch window, rather than only closing it back to its source.
vim.cmd('Gbranch')
nowrap_view('Gbranch')
ordinary_buffer('Gbranch')
vim.cmd('close')
assert(vim.api.nvim_get_current_win() == source_win and vim.wo.wrap)

-- Action menus and graph windows must preserve the same default when reused.
local ui = require('git.features.transient_menu').show({ title = 'Wrap scope', groups = {} }, { layout = 'split' })
nowrap_view('action menu')
ordinary_buffer('action menu')
ui.close()
vim.cmd('new')
require('git.utils').setup_flog_window(vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf())
nowrap_view('graph window')
ordinary_buffer('graph window')
vim.cmd('close')

-- Exercise both worktree-file and scratch-only Status diff paths.
local status = require('git.features.status')
local buf = assert(status.open({ work_tree = root, split = true, auto_fetch = false }))
for _, text in ipairs({ 'M file.txt', 'D deleted.txt' }) do
  local row
  assert(vim.wait(3000, function()
    for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if line == text then row = i; return true end
    end
  end, 5), 'missing Status row: ' .. text)
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  vim.fn.maparg('d', 'n', false, true).callback()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    vim.api.nvim_win_call(win, function()
      nowrap_view('Status diff ' .. text)
      vim.cmd('diffoff')
      ordinary_buffer('Status diff ' .. text)
    end)
  end
  vim.cmd('tabclose')
end
vim.fn.maparg('q', 'n', false, true).callback()

-- The configured Diffview hook must also restrict its override to the view.
vim.cmd('new')
local spec = dofile(vim.fs.dirname(plugin) .. '/diffview.lua')
spec.opts.hooks.diff_buf_win_enter(vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win(),
  { symbol = 'a', layout_name = 'diff2_horizontal' })
nowrap_view('Diffview hook')
ordinary_buffer('Diffview hook')
vim.cmd('close')

vim.fn.delete(root, 'rf')
print('PASS: Git branch/menu/graph/Status diff/Diffview overrides preserve wrapping for ordinary buffers')
