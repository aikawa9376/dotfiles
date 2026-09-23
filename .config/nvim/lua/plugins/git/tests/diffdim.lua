local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local function git(args, date)
  local argv = { 'git', '-C', root }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true,
    env = date and { GIT_AUTHOR_DATE = date, GIT_COMMITTER_DATE = date } or nil }):wait()
  assert(result.code == 0, result.stderr)
end
git({ 'init', '-q' })
git({ 'config', 'user.name', 'Test' })
git({ 'config', 'user.email', 'test@example.invalid' })
local path = root .. '/a file.txt'
vim.fn.writefile({ 'first', 'second', 'third' }, path)
git({ 'add', '.' }); git({ 'commit', '-qm', 'initial' }, '2020-01-01T12:00:00+0900')
vim.fn.writefile({ 'first', 'changed', 'third' }, path)
git({ 'add', '.' }); git({ 'commit', '-qm', 'change' }, '2025-01-01T12:00:00+0900')
vim.cmd('edit ' .. vim.fn.fnameescape(path))
local buf = vim.api.nvim_get_current_buf()
local base
package.loaded.gitsigns = {
  reset_base = function() base = nil end,
  change_base = function(rev, _, callback) base = rev; callback() end,
  get_hunks = function() return { { added = { start = 2, count = 1 } } } end,
}
require('git.features.diffdim').setup()
assert(vim.tbl_contains(vim.fn.getcompletion('DiffDim HE', 'cmdline'), 'HEAD'),
  'DiffDim should complete Git revisions through the independent Git provider')
local ns = vim.api.nvim_create_namespace('DimNonDiffLines')
local function dimmed()
  local result = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})) do result[#result + 1] = mark[2] + 1 end
  return result
end
vim.cmd('DiffDim latest')
assert(vim.deep_equal(dimmed(), { 1, 3 }), 'latest should retain only the changed commit line')
vim.cmd('DiffDim older')
assert(vim.deep_equal(dimmed(), { 2 }), 'older should retain the initial commit lines')
vim.cmd('DiffDim newer')
assert(vim.deep_equal(dimmed(), { 1, 3 }), 'newer should return to the changed commit')
vim.cmd('DiffDim clear')
assert(#dimmed() == 0)
vim.cmd('DiffDim HEAD~1')
assert(base == 'HEAD~1' and vim.deep_equal(dimmed(), { 1, 3 }), 'revision mode should keep its Gitsigns base')
vim.cmd('DiffDim')
assert(base == nil and #dimmed() == 0, 'bare DiffDim should toggle the marks off')
vim.fn.delete(root, 'rf')
print('PASS: migrated DiffDim revision and blame modes on a spaced Git path')
