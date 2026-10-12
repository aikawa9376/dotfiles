local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.ci_fixture').new()
local transport, service, async = require('git.features.ci.transport'), require('git.features.ci.service'), require('git.features.async')
local ctx = { host = 'ghe.example.test', repo = 'org/repo', root = f.root }
local check = { provider = 'github_actions' }
local step = { log_available = true, provider_data = { job_id = 12, position = 1 } }
local function run(fn)
  local done, ok, result
  async.run(f.root, fn, function(success, value) done, ok, result = true, success, value end)
  assert(vim.wait(5000, function() return done end, 10)); return result, ok
end
local log_path = 'repos/org/repo/actions/jobs/12/steps/1/logs'
f.responses[log_path] = function()
  local argv = f.ci_calls[#f.ci_calls].argv
  if not vim.tbl_contains(argv, '--allow-escape-sequences') then
    return { code = 1, stderr = 'the response contains terminal escape sequences; pass --allow-escape-sequences to output it anyway' }
  end
  return { raw = '\27[32mSAFE\27[0m\r\n' }
end
local log = run(function() return service.log(ctx, check, step) end)
assert(log.text == 'SAFE\n' and f.count('/steps/1/logs') == 2)
log = run(function() return service.log(ctx, check, step) end)
assert(log.text == 'SAFE\n' and f.count('/steps/1/logs') == 3, 'CLI capability should be remembered')
vim.g.git_ci = { max_log_bytes = 1024 }
f.responses[log_path] = { raw = string.rep('x', 2048) }
log = run(function() return service.log(ctx, check, step) end)
assert(#log.text == 1024 and log.truncated, 'Huge output must be bounded and marked')
local before = #f.ci_calls
local err, ok = run(function() return transport.download(ctx, 'https://evil.example/secret?signature=DO_NOT_PRINT', nil, true) end)
assert(not ok and err:find('Unrecognized log host') and #f.ci_calls == before)
err, ok = run(function() return transport.download(ctx, 'https://circleci.com@evil.example/log', 'token', true) end)
assert(not ok and #f.ci_calls == before)
f.responses['https://circleci.com/log?signature=transient'] = { raw = 'redirect body', http = 302 }
err, ok = run(function() return transport.download(ctx, 'https://circleci.com/log?signature=transient', nil, true) end)
assert(not ok and err:find('302') and not err:find('signature'), 'Redirects must not leak signed credentials')
local saved_token = vim.env.CIRCLE_TOKEN; vim.env.CIRCLE_TOKEN = 'TEST$TOKEN.*literal'
assert(transport.clean('a TEST$TOKEN.*literal b') == 'a [redacted] b')
assert(transport.clean('x\27]8;;https://hidden.example\7y\27]8;;\7\0z') == 'xyz')
assert(transport.clean('\239\187\1912026-08-02T12:05:39Z runner\r\n') == '2026-08-02T12:05:39Z runner\n', 'Leading UTF-8 BOM should be removed')
assert(transport.clean('body \239\187\191text') == 'body \239\187\191text', 'Only a stream-leading BOM should be removed')
vim.env.CIRCLE_TOKEN = saved_token
vim.g.git_ci = nil; f.cleanup()
print('PASS: gh ANSI opt-in/reuse, bounded log output, strict download hosts, redirect rejection and token/OSC/control sanitization')
