-- Run from the plugin root: nvim --headless --clean -u NONE -l tests/github_open.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local github = require('git.features.github_open')
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local function git(args)
  local cmd = { 'git', '-C', root }
  vim.list_extend(cmd, args)
  local result = vim.system(cmd, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout or '')
end

git({ 'init', '-q' })
git({ 'config', 'user.name', 'Test' })
git({ 'config', 'user.email', 'test@example.invalid' })
vim.fn.writefile({ 'first' }, root .. '/sample.txt')
git({ 'add', 'sample.txt' })
git({ 'commit', '-qm', 'first' })
local pushed = git({ 'rev-parse', 'HEAD' })
git({ 'branch', 'feature/topic' })
git({ 'remote', 'add', 'origin', 'git@github.com:example/project.git' })
git({ 'update-ref', 'refs/remotes/origin/feature/topic', pushed })
assert(github.branch_url(root, 'feature/topic', 'local_') ==
  'https://github.com/example/project/tree/feature/topic')
assert(github.branch_url(root, 'origin/feature/topic', 'remote') ==
  'https://github.com/example/project/tree/feature/topic')
assert(github.commit_url(root, pushed:sub(1, 7)) ==
  'https://github.com/example/project/commit/' .. pushed)

git({ 'checkout', '-qb', 'local-only' })
git({ 'update-ref', 'refs/remotes/origin/main', pushed })
git({ 'branch', '--set-upstream-to=origin/main', 'local-only' })
vim.fn.writefile({ 'second' }, root .. '/sample.txt')
git({ 'commit', '-qam', 'second' })
assert(github.branch_url(root, 'local-only', 'local_') == nil)
assert(github.commit_url(root, git({ 'rev-parse', 'HEAD' })) == nil)
assert(github.branch_url(root, 'feature/topic', 'tags') == nil)
git({ 'remote', 'set-url', 'origin', 'git@gitlab.com:example/project.git' })
assert(github.branch_url(root, 'origin/feature/topic', 'remote') == nil)
assert(github.commit_url(root, pushed) == nil)

vim.fn.delete(root, 'rf')
print('PASS: pushed GitHub branches and commits, local-only and non-GitHub refs')
