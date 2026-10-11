local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local api = require('git.features.pr_model')
local ctx = { root = f.root, host = 'ghe.example.test', repo = 'org/repo', number = 7 }
local prefix = 'refs/nvim-pr/ghe.example.test/org/repo/7'
local async = require('git.features.async')
local function load()
  local value, failure
  local task = async.run(f.root, function() return api.load(ctx) end, function(ok, result)
    if ok then value = result else failure = result end
  end)
  assert(vim.wait(5000, function() return task.completed end, 10))
  assert(value, tostring(failure))
  assert(value.base == f.base and value.hash == f.head and #value.entries == 4,
    'PR lost its recorded comparison')
  assert(f.git({ 'rev-parse', prefix .. '/base' }) == f.base)
  assert(f.git({ 'rev-parse', prefix .. '/head' }) == f.head)
end
local before = f.git({ 'status', '--porcelain' })
local head = f.git({ 'rev-parse', 'HEAD' })
-- Open PR API base SHAs can already differ from the base branch tip.
f.pr.baseRefOid = f.base
load()
-- Closed PR heads can also be independent of their advertised ref.
f.git({ 'update-ref', '-d', prefix .. '/base' })
f.git({ 'update-ref', '-d', prefix .. '/head' })
f.pr.state = 'MERGED'
f.git({ 'update-ref', 'refs/pull/7/head', f.base_head })
load()
-- A deleted base branch and PR ref are not needed to fetch recorded commits.
f.git({ 'update-ref', '-d', prefix .. '/base' })
f.git({ 'update-ref', '-d', prefix .. '/head' })
f.git({ 'branch', '-D', 'main' })
f.git({ 'update-ref', '-d', 'refs/pull/7/head' })
f.pr.state = 'CLOSED'
load()
assert(f.git({ 'rev-parse', 'HEAD' }) == head and f.git({ 'status', '--porcelain' }) == before,
  'loading a historical PR changed the caller worktree')
f.cleanup()
print('PASS: open PR recorded base, merged/closed historical heads, moved/deleted refs and unchanged worktree')
