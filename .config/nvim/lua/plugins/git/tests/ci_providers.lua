local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.ci_fixture').new()
local ctx = { host = 'ghe.example.test', repo = 'org/repo', number = 7, root = f.root }
local model, service, transport, async = require('git.features.ci.model'), require('git.features.ci.service'), require('git.features.ci.transport'), require('git.features.async')
local seed = model.rollup(f.pr, ctx)[1]
local function run(fn)
  local finished, result, success
  async.run(f.root, fn, function(ok, value) finished, success, result = true, ok, value end)
  assert(vim.wait(5000, function() return finished end, 10), 'CI request hung')
  return result, success
end
local details = run(function() return service.details(ctx, seed) end)
assert(details.check.check_run_id == 901 and #details.steps == 3 and details.job.id == 12 and details.attempt == 2)
assert(details.steps[2].number == 16 and details.steps[2].provider_data.position == 1, 'Step position must be zero based, independent of display number')
assert(not details.steps[3].log_available and details.annotations[1].start_line == 42)
local log = run(function() return service.log(ctx, details.check, details.steps[2]) end)
assert(log.scope == 'Step log' and log.text == 'FAIL\nExpected 200\n' and f.count('/steps/16/logs') == 0)
f.responses['repos/org/repo/actions/jobs/12/steps/1/logs'] = { code = 1, stderr = 'Not Found (HTTP 404)' }
log = run(function() return service.log(ctx, details.check, details.steps[2]) end)
assert(log.scope:find('Job log') and log.text:find('FULL JOB'))
assert(log.scope == 'Job log · all steps' and log.job_wide)
f.responses['repos/org/repo/actions/jobs/12/steps/0/logs'] = { code = 1, stderr = 'Not Found (HTTP 404)' }
f.responses['repos/org/repo/actions/jobs/12/logs'] = { raw = '\239\187\191FULL JOB\n' }
local setup_log = run(function() return service.log(ctx, details.check, details.steps[1]) end)
assert(setup_log.text == log.text and setup_log.text:sub(1, 3) ~= '\239\187\191', 'Fallbacks share the full job body, with BOM removed')
f.ci_job.check_run_url = 'https://ghe.example.test/api/v3/repos/org/repo/check-runs/12'
details = run(function() return service.details(ctx, seed) end)
assert(#details.steps == 0 and details.message:find('identity mismatch'), 'Equal check/job IDs must not be assumed')
f.ci_job.check_run_url = 'https://ghe.example.test/api/v3/repos/org/repo/check-runs/901'
f.ci_job.head_sha = f.base
details = run(function() return service.details(ctx, seed) end); assert(#details.steps == 0 and details.message:find('identity mismatch'))
f.ci_job.head_sha = f.head
local generic = model.rollup(f.pr, ctx)[2]
details = run(function() return service.details(ctx, generic) end)
assert(details.check.description == 'Waiting for external CI' and details.message:find('Native logs') and #details.steps == 0)
-- Paging applies equally to statuses, checks and annotations.
local many = {}; for i = 1, 100 do many[i] = { id = i } end
f.responses['repos/org/repo/check-runs/999/annotations?per_page=100&page=1'] = many
f.responses['repos/org/repo/check-runs/999/annotations?per_page=100&page=2'] = { { id = 101 } }
local paged = run(function() return transport.pages(ctx, 'repos/org/repo/check-runs/999/annotations') end); assert(#paged == 101)
for _, code in ipairs({ 401, 403, 404, 429 }) do
  assert(transport.error({ code = 1, stderr = 'secret URL https://private.test/?signature=secret (HTTP ' .. code .. ')' }, true):find(tostring(code), 1, true) or code == 401)
end
assert(not transport.error({ code = 1, stderr = 'TOKEN secret signed url' }):find('secret'))
assert(transport.error({ code = 124 }):find('timed out'))
f.responses['repos/org/repo/check-runs/901'] = { raw = 'invalid json' }
details = run(function() return service.details(ctx, model.check(f.ci_run, ctx, f.head, 'check_run')) end)
assert(details.message:find('Invalid JSON'))
f.cleanup()
print('PASS: verified check/job/SHA/attempt, zero-based step logs, honest job fallback, annotations/pagination and redacted API errors')
