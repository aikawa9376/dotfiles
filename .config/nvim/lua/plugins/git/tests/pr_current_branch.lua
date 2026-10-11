local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local view, async = require('git.features.pr'), require('git.features.async')
view.setup()
local function open(argument)
  local before = #f.calls
  vim.cmd('GitPr' .. (argument and (' ' .. argument) or ''))
  local buf = vim.api.nvim_get_current_buf()
  assert(vim.wait(5000, function() return view.model(buf) and not async.busy(f.root) end, 10),
    table.concat(f.notifications, '\n'))
  local request
  for i = before + 1, #f.calls do
    local call = f.calls[i]
    if call.argv[2] == 'pr' and call.argv[3] == 'view' then request = call end
  end
  assert(request and request.opts.cwd == f.root)
  assert(view.model(buf).ctx.number == 7 and view.model(buf).ctx.host == 'ghe.example.test')
  vim.api.nvim_buf_delete(buf, { force = true })
  return request
end
-- Previously this emitted gh usage: --repo without a selector.
local request = open()
assert(request.argv[4] == '--json' and not vim.tbl_contains(request.argv, '--repo'),
  'No-argument GitPr did not delegate current-branch lookup to gh')
assert(request.opts.env.GH_HOST == 'ghe.example.test')
-- Numeric branch names remain branches, rather than being mistaken for PR IDs.
f.git({ 'checkout', '-qb', '123' })
request = open()
assert(request.argv[4] == '--json')
-- Saved worktree associations select the actual PR, not the local branch name.
f.git({ 'config', 'branch.123.pullRequestUrl', f.pr.url })
request = open()
assert(request.argv[4] == '7' and vim.tbl_contains(request.argv, 'ghe.example.test/org/repo'))
f.git({ 'config', '--unset', 'branch.123.pullRequestUrl' })
request = open('7')
assert(request.argv[4] == '7' and vim.tbl_contains(request.argv, '--repo'))
request = open(f.pr.url)
assert(request.argv[4] == '7' and vim.tbl_contains(request.argv, 'ghe.example.test/org/repo'))
-- An absent PR is an ordinary lookup error; reopening retries after creation.
local system = vim.system
vim.system = function(argv, opts, callback)
  if argv[1] == 'gh' and argv[2] == 'pr' and argv[3] == 'view' then
    local result = { code = 1, stdout = '', stderr = 'no pull requests found for branch "123"' }
    vim.defer_fn(function() callback(result) end, 2)
    return { kill = function() end }
  end
  return system(argv, opts, callback)
end
vim.cmd('GitPr')
local failed = vim.api.nvim_get_current_buf()
assert(vim.wait(5000, function() return not async.busy(f.root) end, 10))
assert(not view.model(failed))
local error = vim.api.nvim_buf_get_lines(failed, 0, 1, false)[1]
assert(error:find('no pull requests found', 1, true) and not error:find('Usage:', 1, true))
vim.system = system
vim.cmd('GitPr')
assert(vim.api.nvim_get_current_buf() == failed)
assert(vim.wait(5000, function() return view.model(failed) and not async.busy(f.root) end, 10))
vim.api.nvim_buf_delete(failed, { force = true })
f.cleanup()
print('PASS: no-argument GitPr, numeric branches, saved associations, explicit selectors, missing PRs and reopen retries')
