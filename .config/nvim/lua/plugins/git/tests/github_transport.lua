local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local github = require('git.features.github')
local actions = require('git.features.github_actions')
f.api_before = function() return true end
f.api_error_stderr = 'gh: Validation Failed (HTTP 422)'
local function failure(response)
  f.api_error_response = response
  local count = #f.notifications
  local task = actions.run({ root = f.root, url = f.pr.url }, function(ctx)
    return github.api(ctx, 'repos/org/repo/issues/7/comments', { body = 'Literal $(body)' })
  end, function() error('Failed API request reported success') end, true)
  assert(vim.wait(5000, function() return task.completed and #f.notifications > count end, 10))
  return f.notifications[#f.notifications]
end
local message = failure(vim.json.encode({ message = 'Validation Failed', errors = {
  'String reason', { message = 'Detailed validation reason' }, { field = 'line', code = 'invalid' },
}, documentation_url = 'https://example.test/DO_NOT_DUMP' }))
assert(message:find('HTTP 422', 1, true) and message:find('String reason', 1, true)
  and message:find('Detailed validation reason', 1, true) and message:find('line: invalid', 1, true))
assert(not message:find('DO_NOT_DUMP', 1, true))
assert(select(2, message:gsub('Validation Failed', '')) == 1, 'Duplicate API summary')
assert(failure('<html>DO_NOT_DUMP</html>') == f.api_error_stderr)
assert(failure(vim.json.encode({ errors = vim.NIL })) == f.api_error_stderr)
f.api_error_stderr = ''
assert(failure('null') == 'GitHub command failed (exit 1)')
for _, call in ipairs(f.calls) do if call.argv[2] == 'api' then
  assert(call.opts.cwd == f.root and call.opts.env.GH_HOST == 'ghe.example.test')
  assert(vim.tbl_contains(call.argv, 'X-GitHub-Api-Version: 2022-11-28'))
end end
f.cleanup()
print('PASS: API error bodies retain validation reasons, omit arbitrary response contents and tolerate malformed bodies')
