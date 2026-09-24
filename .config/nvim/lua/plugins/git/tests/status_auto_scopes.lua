-- Run: nvim --headless --clean -u NONE -l tests/status_auto_scopes.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
package.loaded['git.features.status_watch'] = { subscribe = function() return function() end end }
package.loaded['git.features.worktree_watch'] = { subscribe = function() return function() end end }

local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid' }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end
git({ 'init', '-qb', 'main' })
git({ 'remote', 'add', 'origin', root })
vim.fn.writefile({ 'base' }, root .. '/file.txt')
git({ 'add', '.' })
git({ 'commit', '-qm', 'base' })
git({ 'update-ref', 'refs/remotes/origin/main', 'HEAD' })
git({ 'branch', '--set-upstream-to=origin/main' })

local original_system, original_executable = vim.system, vim.fn.executable
local branch_prs = {}
local all_prs = { { number = 1, title = 'Other branch', headRefName = 'other', isDraft = false,
  url = 'https://github.com/example/repo/pull/1' } }
local pr_reads = 0
vim.fn.executable = function(name) return name == 'gh' and 1 or original_executable(name) end
vim.system = function(argv, opts, callback)
  if argv[1] ~= 'gh' then return original_system(argv, opts, callback) end
  local branch = vim.tbl_contains(argv, '--head')
  local output = vim.json.encode(branch and branch_prs or all_prs)
  pr_reads = pr_reads + 1
  vim.defer_fn(function() callback({ code = 0, stdout = output, stderr = '' }) end, branch and 10 or 80)
end

local status = require('git.features.status')
status.setup(vim.api.nvim_create_augroup('StatusAutoScopesTest', { clear = true }))
local b = assert(status.open({ work_tree = root, split = true }))
local function lines() return vim.api.nvim_buf_get_lines(b, 0, -1, false) end
local function row(pattern)
  for i, line in ipairs(lines()) do if line:find(pattern, 1, true) then return i end end
end
local transient = {}
vim.api.nvim_buf_attach(b, false, { on_lines = function()
  for _, line in ipairs(lines()) do
    if line:match('^Pull requests %(0%)') then table.insert(transient, line) end
  end
end })
assert(vim.wait(5000, function()
  return row('Commits [latest 15+] (1)') and row('Pull requests (1) [all]')
end, 20), 'clean repository did not show latest commits and all PRs')
assert(vim.fn.foldclosed(row('Commits [latest 15+] (1)')) > 0, 'latest commits should start closed')
assert(vim.fn.foldclosed(row('Pull requests (1) [all]')) > 0, 'all PRs should start closed')
assert(#transient == 0, 'temporary empty PR heading appeared')

all_prs = {}
local reads = pr_reads
vim.fn.maparg('R', 'n', false, true).callback()
assert(vim.wait(5000, function() return pr_reads >= reads + 2 and not row('Pull requests (') end, 20),
  'empty PR section was not hidden')

branch_prs = { { number = 2, title = 'Main branch', headRefName = 'main', isDraft = false,
  url = 'https://github.com/example/repo/pull/2' } }
git({ 'commit', '--allow-empty', '-qm', 'new commit' })
vim.fn.maparg('R', 'n', false, true).callback()
assert(vim.wait(5000, function()
  return row('Unpushed [only] (1)') and row('Pull requests (1) [branch: main]')
end, 20), 'new commit and branch PR did not restore normal scopes')
assert(vim.fn.foldclosed(row('Unpushed [only] (1)')) == -1, 'unpushed commits should open')
assert(vim.fn.foldclosed(row('Pull requests (1) [branch: main]')) == -1, 'branch PRs should open')
assert(#transient == 0, 'temporary empty PR heading appeared')

vim.api.nvim_buf_delete(b, { force = true })
vim.system, vim.fn.executable = original_system, original_executable
vim.fn.delete(root, 'rf')
print('PASS: clean scopes collapse, empty PRs hide, new commits and branch PRs reopen atomically')
