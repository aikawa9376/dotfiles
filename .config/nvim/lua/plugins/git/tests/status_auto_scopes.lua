-- Run: nvim --headless --clean -u NONE -l tests/status_auto_scopes.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
vim.g.git_status_auto_fetch = false -- The fixture controls its own remote refs.
package.loaded['git.features.status_watch'] = { subscribe = function() return function() end end }
package.loaded['git.features.worktree_watch'] = { subscribe = function() return function() end end }

local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root, '-c', 'user.name=Test Author 日本語', '-c', 'user.email=test@example.invalid' }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end
git({ 'init', '-qb', 'main' })
git({ 'remote', 'add', 'origin', root })
vim.fn.writefile({ 'base' }, root .. '/file.txt')
git({ 'add', '.' })
git({ 'commit', '-qm', 'base  subject with Test Author 日本語' })
git({ 'update-ref', 'refs/remotes/origin/main', 'HEAD' })
git({ 'branch', '--set-upstream-to=origin/main' })

local original_system, original_executable = vim.system, vim.fn.executable
local branch_prs = {}
local all_prs = { { number = 1, title = 'Other branch 日本語 @other', headRefName = 'other', isDraft = false,
  author = { login = 'other' }, mergeable = 'CONFLICTING',
  createdAt = os.date('!%Y-%m-%dT%H:%M:%SZ', os.time() - 90000),
  url = 'https://github.com/example/repo/pull/1' } }
local pr_reads = 0
vim.fn.executable = function(name) return name == 'gh' and 1 or original_executable(name) end
vim.system = function(argv, opts, callback)
  if argv[1] ~= 'gh' then return original_system(argv, opts, callback) end
  local fields = argv[vim.fn.index(argv, '--json') + 2]
  assert(fields and fields:find('author', 1, true) and fields:find('createdAt', 1, true),
    'PR listing must request author and creation time')
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

local function colored(namespace, at, text, group)
  local line = lines()[at]
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(b, vim.api.nvim_create_namespace(namespace),
    { at - 1, 0 }, { at - 1, -1 }, { details = true })) do
    if mark[4].hl_group == group and line:sub(mark[3] + 1, mark[4].end_col) == text then return true end
  end
  return false
end
local pr_row = assert(row('#1 1d Other branch 日本語 @other other @other [CI:— Review:— conflicts]'))
assert(colored('git_status_pull_requests', pr_row, 'other', 'GitBranch'))
assert(colored('git_status_pull_requests', pr_row, '@other', 'Type'))
assert(colored('git_status_pull_requests', pr_row, '#1', 'GitPrPositive'))
assert(colored('git_status_pull_requests', pr_row, ' 1d', 'Directory'), 'PR age should be blue beside its number')
assert(colored('git_status_pull_requests', pr_row, 'conflicts', 'DiagnosticError'), 'Conflict status should be red')
assert(not colored('git_status_pull_requests', pr_row, 'Other branch 日本語 @other', 'GitBranch'),
  'Repeated author/branch text in the title corrupted highlight boundaries')
local function author_highlight()
  local commit_row
  for at, line in ipairs(lines()) do
    if line:match(' Test Author 日本語$') then commit_row = at; break end
  end
  assert(commit_row, 'Commit author must follow the subject at the end')
  assert(colored('git_status_icons', commit_row, 'Test Author 日本語', 'Type'), 'Commit author lost its color')
end
author_highlight()

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
author_highlight()
assert(not row('@nil') and not row('@vim.NIL'), 'Missing PR author leaked a placeholder')

vim.api.nvim_buf_delete(b, { force = true })
vim.system, vim.fn.executable = original_system, original_executable
vim.fn.delete(root, 'rf')
print('PASS: clean scopes collapse, empty PRs hide, new commits and branch PRs reopen atomically')
