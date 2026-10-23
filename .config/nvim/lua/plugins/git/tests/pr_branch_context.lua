local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local view, async = require('git.features.pr'), require('git.features.async')
local function loaded(buf)
  assert(vim.wait(5000, function() return view.model(buf) and not async.busy(f.root) end, 10),
    table.concat(f.notifications, '\n'))
end
local function text(buf) return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end
local original_pr = vim.deepcopy(f.pr)
local first = assert(view.open({ root = f.root })); loaded(first)
local before = #f.calls
assert(view.open({ root = f.root }) == first and #f.calls == before, 'Same branch should reuse its loaded PR')
local title
for row, line in ipairs(vim.api.nvim_buf_get_lines(first, 0, -1, false)) do if line == f.pr.title then title = row end end
assert(title)
vim.api.nvim_buf_set_lines(first, title - 1, title, false, { 'Unsaved original PR title' })
assert(vim.bo[first].modified)

f.git({ 'checkout', '-qb', 'another-topic' })
f.git({ 'update-ref', 'refs/pull/8/head', f.head })
f.pr.number, f.pr.title, f.pr.url, f.pr.headRefName = 8, 'Another PR',
  'https://ghe.example.test/org/repo/pull/8', 'another-topic'
f.api_response = function(path)
  if path == 'repos/org/repo/pulls/8/reviews' or path == 'repos/org/repo/issues/8/comments' then return { data = { {} } } end
end
local second = assert(view.open({ root = f.root })); loaded(second)
assert(second ~= first and view.model(second).ctx.number == 8 and #f.calls > before,
  'Current-branch opener reused the previous branch PR')
assert(view.model(first).ctx.number == 7 and vim.bo[first].modified and text(first):find('Unsaved original PR title', 1, true))
before = #f.calls
assert(view.open({ root = f.root, url = original_pr.url }) == first and #f.calls == before,
  'Explicit PR selectors must keep their original draft after checkout')
assert(view.open({ root = f.root, host = 'ghe.example.test', repo = 'org/repo', number = 8 }) == second)

f.git({ 'checkout', '-q', 'topic' })
f.pr = vim.deepcopy(original_pr)
assert(view.open({ root = f.root }) == first and text(first):find('Unsaved original PR title', 1, true),
  'Returning to a branch lost its draft')
-- A saved worktree association can change without a checkout.
f.git({ 'config', 'branch.topic.pullRequestUrl', 'https://ghe.example.test/org/repo/pull/8' })
assert(view.open({ root = f.root }) == second, 'Changed worktree association reused the old implicit selector')
f.git({ 'config', '--unset', 'branch.topic.pullRequestUrl' })
assert(view.open({ root = f.root }) == first)

-- The same PR URL in another local worktree still owns a separate buffer.
local linked = f.root .. '-linked'
f.git({ 'worktree', 'add', '-q', '--detach', linked, f.head })
local independent = assert(view.open({ root = linked, url = original_pr.url })); loaded(independent)
assert(independent ~= first and view.model(independent).ctx.root == linked)
assert(view.model(first).ctx.root == f.root and vim.bo[first].modified)
for _, buf in ipairs({ first, second, independent }) do vim.api.nvim_buf_delete(buf, { force = true }) end
f.git({ 'worktree', 'remove', '--force', linked })
f.cleanup()
print('PASS: retained current-branch PR views, checkout/back, draft preservation, explicit selectors, association changes and worktree isolation')
