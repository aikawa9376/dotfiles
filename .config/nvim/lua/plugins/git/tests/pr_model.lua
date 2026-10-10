local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local model_api, github = require('git.features.pr_model'), require('git.features.github')
local before = f.git({ 'status', '--porcelain' })
local result, failure
require('git.features.github_actions').run({ root = f.root, url = f.pr.url }, model_api.load,
  function(model) result = model end, true)
assert(vim.wait(5000, function() return result ~= nil end, 10), table.concat(f.notifications, '\n'))
assert(result.base == f.base and result.hash == f.head, 'PR must compare merge-base, not base branch tip')
assert(f.git({ 'rev-parse', 'HEAD' }) == f.head and f.git({ 'status', '--porcelain' }) == before, 'Viewing changed working tree')
assert(#result.entries == 4 and #result.threads == 3, 'Change/thread pagination lost entries')
assert(#result.threads[1].comments == 2, 'Reply grouping lost a reply')
local entry
for _, item in ipairs(result.entries) do if item.path == 'file name.txt' then entry = item end end
local changes = require('git.features.commit_model')
local patch = assert(changes.patch(result, entry))
local coords = model_api.coordinates(patch)
local left, right
for row, line in ipairs(patch) do
  if line == '-two' then left = model_api.threads_at(result, entry, coords[row]) end
  if line == '+TWO' then right = model_api.threads_at(result, entry, coords[row]) end
end
assert(#left == 1 and left[1].id == 201, 'RIGHT comments leaked onto deletion rows')
assert(#right == 1 and right[1].id == 101, 'LEFT comments leaked onto addition rows')
assert(github.summary(f.pr):find('CI: ✗ 1/2', 1, true))
assert(github.summary({ statusCheckRollup = { { conclusion = 'SUCCESS' }, { conclusion = 'SKIPPED' } } }):find('CI: ✓ 2', 1, true))
assert(github.summary({ statusCheckRollup = vim.NIL }):find('CI: —', 1, true))
local checks = github.checks(f.pr)
assert(checks[1].url:find('/job/12', 1, true) and checks[2].url == 'https://ci.example.test/build/1')
for _, call in ipairs(f.calls) do
  assert(call.opts.cwd == f.root)
  if call.argv[2] == 'api' then assert(vim.tbl_contains(call.argv, 'ghe.example.test')) end
end
-- Moving the PR head between API lookup and fetch must reject a mixed snapshot.
f.pr.headRefOid = f.base
local task = require('git.features.async').run(f.root, function() return model_api.load(result.ctx) end,
  function(ok, err) assert(not ok); failure = tostring(err) end)
assert(vim.wait(5000, function() return task.completed end, 10))
assert(failure:find('changed while fetching', 1, true))
f.cleanup()
print('PASS: PR merge-base diffs, protected worktree, rename/delete/add, paginated replies, LEFT/RIGHT anchors, Enterprise URLs, head drift')
