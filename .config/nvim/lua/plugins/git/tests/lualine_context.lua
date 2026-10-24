-- Run from the plugin root: python3 tests/run.py lualine_context
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
vim.opt.rtp:prepend(plugin)
vim.g.git_status_auto_fetch = false

local fixture = vim.fn.tempname() .. ' lualine-context'
vim.fn.mkdir(fixture, 'p')
local function git(root, args)
  local argv = { 'git', '-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
    '-c', 'commit.gpgsign=false' }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout or '')
end
local parent, seed = fixture .. '/parent', fixture .. '/seed'
for _, root in ipairs({ parent, seed }) do
  vim.fn.mkdir(root, 'p')
  git(root, { 'init', '-qb', root == parent and 'parent-branch' or 'module-branch' })
  vim.fn.writefile({ 'sample' }, root .. '/sample.txt')
  git(root, { 'add', '.' })
  git(root, { 'commit', '-qm', 'initial' })
end
git(parent, { '-c', 'protocol.file.allow=always', 'submodule', 'add', '-q', seed, 'modules/child' })
git(parent, { 'commit', '-qam', 'submodule' })
local child = parent .. '/modules/child'
git(child, { 'branch', 'other-branch' })
vim.cmd('cd ' .. vim.fn.fnameescape(parent))
vim.cmd('edit ' .. vim.fn.fnameescape(child .. '/sample.txt'))

-- Capture the actual configured components without loading unrelated UI plugins.
local sections
package.loaded.lualine = {
  setup = function(opts) sections = opts.sections.lualine_c end,
  refresh = function() end,
}
package.loaded.lazyagent = { status = function() return '' end }
dofile(vim.fs.dirname(plugin) .. '/lualine.lua').config()
local utils = require('git.utils')
local function expect_child(branch, label)
  assert(utils.get_work_tree() == child, label .. ': Git repository changed')
  assert(vim.fn.getcwd() == parent, label .. ': cwd changed')
  assert(vim.wait(5000, function()
    return sections[2][1]() == branch and sections[3][1]() == ' child'
  end, 5), label .. ': incorrect project or branch: ' .. sections[3][1]() .. ' / ' .. sections[2][1]())
end
expect_child('module-branch', 'ordinary file')
local group = vim.api.nvim_create_augroup('LualineContextTest', { clear = true })
require('git.features.status').setup(group)
require('git.features.branch').setup(group)
require('git.commands').setup(group)
local status_buf = assert(require('git.features.status').open({ split = true }))
expect_child('module-branch', 'Status')
vim.cmd('Gbranch')
expect_child('module-branch', 'Branch')
vim.fn.maparg('q', 'n', false, true).callback()
assert(vim.api.nvim_get_current_buf() == status_buf)
expect_child('module-branch', 'return to Status')

vim.cmd('Gbranch')
local row
for i, ref in ipairs(vim.b.branch_map) do if ref == 'other-branch' then row = i end end
assert(row, 'other branch missing')
vim.api.nvim_win_set_cursor(0, { row, 0 })
vim.fn.maparg('coo', 'n', false, true).callback()
expect_child('other-branch', 'checkout in Branch')
vim.fn.maparg('q', 'n', false, true).callback()
assert(vim.api.nvim_get_current_buf() == status_buf)
expect_child('other-branch', 'return after checkout')
assert(git(parent, { 'branch', '--show-current' }) == 'parent-branch')
assert(git(child, { 'branch', '--show-current' }) == 'other-branch')

-- Directory and unnamed Git buffers also carry their own repository identity.
local directory = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(directory, child)
vim.api.nvim_set_current_buf(directory)
expect_child('other-branch', 'directory buffer')
local unnamed = vim.api.nvim_create_buf(false, true)
utils.set_buf_work_tree(unnamed, child)
vim.api.nvim_set_current_buf(unnamed)
expect_child('other-branch', 'unnamed buffer with repository metadata')

-- A URI without explicit Git context must never inherit the superproject's cwd.
for _, scheme in ipairs({ 'git-object', 'custom+scheme.2' }) do
  local uri = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(uri, scheme .. ':///unrelated/path')
  vim.api.nvim_set_current_buf(uri)
  assert(sections[2][1]() == '' and sections[3][1]() == '', 'URI inherited cwd: ' .. scheme)
end
vim.cmd('cd ' .. vim.fn.fnameescape(plugin))
vim.fn.delete(fixture, 'rf')
