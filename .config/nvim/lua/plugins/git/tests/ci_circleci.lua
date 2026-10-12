local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.ci_fixture').new()
local model, service, async = require('git.features.ci.model'), require('git.features.ci.service'), require('git.features.async')
local ctx = { host = 'ghe.example.test', repo = 'org/repo', number = 7, root = f.root }
local token = vim.env.CIRCLE_TOKEN; vim.env.CIRCLE_TOKEN = nil
local check = model.check({ id = 44, context = 'ci/circleci: build', state = 'failure', target_url = 'https://circleci.com/gh/org/repo/22' }, ctx, f.head, 'status')
-- Resolve a Commit Status by both context and the exact URL.
f.responses['repos/org/repo/commits/' .. f.head .. '/statuses?per_page=100&page=1'] = { check.raw }
local function run(fn)
  local done, value, success
  async.run(f.root, fn, function(ok, result) done, success, value = true, ok, result end)
  assert(vim.wait(5000, function() return done end, 10)); return value, success
end
local details = run(function() return service.details(ctx, check) end)
assert(details.message:find('CIRCLE_TOKEN') and #details.steps == 0 and f.count('https://circleci.com') == 0)
vim.env.CIRCLE_TOKEN = 'test-circle-token-never-print'
local workflow = '11111111-1111-1111-1111-111111111111'
local pipeline = '22222222-2222-2222-2222-222222222222'
local job_uuid = '33333333-3333-3333-3333-333333333333'
f.responses['https://circleci.com/api/v2/project/gh/org/repo/job/22'] = { number = 22, id = job_uuid,
  project = { slug = 'gh/org/repo' }, latest_workflow = { id = workflow }, started_at = '2026-10-12T01:00:00Z', stopped_at = '2026-10-12T01:00:42Z' }
f.responses['https://circleci.com/api/v2/workflow/' .. workflow] = { id = workflow, pipeline_id = pipeline, name = 'Build' }
f.responses['https://circleci.com/api/v2/pipeline/' .. pipeline] = { vcs = { revision = f.head, origin_repository_url = 'https://ghe.example.test/org/repo.git' } }
local output0 = 'https://circle-production.s3.amazonaws.com/output/0?signature=do-not-cache'
local output1 = 'https://circle-production.s3.amazonaws.com/output/1?signature=do-not-cache'
local build = { build_num = 22, username = 'org', reponame = 'repo', vcs_revision = f.head,
  steps = { { name = 'Tests', actions = {
    { step = 0, index = 0, name = 'Tests', status = 'success', output_url = output0 },
    { step = 0, index = 1, name = 'Tests', status = 'failed', output_url = output1 },
  } } } }
f.responses['https://circleci.com/api/v1.1/project/gh/org/repo/22'] = function() return build end
f.responses[output0] = { { message = 'worker0\n' } }
f.responses[output1] = { { message = '\27[31mworker1 failed\27[0m\n' } }
f.responses['https://circleci.com/api/v2/project/gh/org/repo/job/22'].id = nil
f.responses['https://circleci.com/api/v2/workflow/' .. workflow .. '/job'] = { items = { { job_number = 99, id = '99999999-9999-9999-9999-999999999999', name = 'Tests' } }, next_page_token = 'next' }
f.responses['https://circleci.com/api/v2/workflow/' .. workflow .. '/job?page-token=next'] = { items = { { job_number = 22, id = job_uuid, name = 'Tests' } } }
details = run(function() return service.details(ctx, check) end)
assert(#details.steps == 2 and details.steps[1].id ~= details.steps[2].id and details.steps[2].state == 'failed')
assert(f.count('/job?page-token=next') == 1, 'CircleCI job resolution missed pagination')
assert(not vim.inspect(details.steps):find('signature=', 1, true), 'Signed URLs leaked into retained step data')
local log = run(function() return service.log(ctx, details.check, details.steps[2]) end)
assert(log.text == 'worker1 failed\n' and log.scope == 'Step log · parallel 1' and f.count(output0) == 0)
for _, call in ipairs(f.ci_calls) do if call.argv[1] == 'curl' then
  assert(not table.concat(call.argv, ' '):find('signature', 1, true) and not table.concat(call.argv, ' '):find(vim.env.CIRCLE_TOKEN, 1, true))
  if call.path:find('amazonaws.com', 1, true) then assert(not call.opts.stdin:find('Circle-Token', 1, true))
  else assert(call.opts.stdin:find(call.path:find('/api/v3/', 1, true) and 'Authorization: Bearer' or 'Circle-Token', 1, true)) end
end end
-- Retrying signed URL failures reacquires the build and a fresh URL.
f.responses[output1] = { raw = 'expired body DO_NOT_PRINT', http = 403 }
local err, ok = run(function() return service.log(ctx, details.check, details.steps[2]) end)
assert(not ok and err:find('expired') and not err:find('DO_NOT_PRINT'))
local refresh_url = 'https://circle-production.s3.amazonaws.com/output/1?signature=fresh'
build.steps[1].actions[2].output_url = refresh_url; f.responses[refresh_url] = { { message = 'fresh output' } }
log = run(function() return service.log(ctx, details.check, details.steps[2]) end); assert(log.text == 'fresh output')
-- Different parallel actions / commits can never be substituted.
build.steps[1].actions[2].index = 2
err, ok = run(function() return service.log(ctx, details.check, details.steps[2]) end); assert(not ok and err:find('identity changed'))
build.steps[1].actions[2].index = 1; build.vcs_revision = f.base
details = run(function() return service.details(ctx, check) end); assert(#details.steps == 0 and details.message:find('mismatch'))
build.vcs_revision = f.head
-- GitHub App projects retain verified metadata and an explicit CLI/web fallback.
local org_id, project_id = '44444444-4444-4444-4444-444444444444', '55555555-5555-5555-5555-555555555555'
local app = model.check({ id = 45, context = 'ci/circleci: app', state = 'failure', target_url = 'https://app.circleci.com/pipelines/circleci/' .. org_id .. '/' .. project_id .. '/4/workflows/' .. workflow .. '/jobs/22' }, ctx, f.head, 'status')
f.responses['repos/org/repo/commits/' .. f.head .. '/statuses?per_page=100&page=1'] = { app.raw }
f.responses['https://circleci.com/api/v2/project/circleci/' .. org_id .. '/' .. project_id .. '/job/22'] = { id = job_uuid, number = 22 }
details = run(function() return service.details(ctx, app) end)
assert(#details.steps == 0 and details.workflow == 'Build' and details.message:find('native steps unavailable'))
-- Current v3 wire format is source-verified against circleci-cli v1.5.0.
f.responses['https://circleci.com/api/v3/jobs/' .. job_uuid] = { data = { id = job_uuid,
  references = { pipeline = { id = pipeline }, workflow = { id = workflow } },
  attributes = { parallel_executions = {
    { steps = { { num = 3, name = 'Test', phase = 'ended', outcome = 'succeeded' } } },
    { steps = { { num = 3, name = 'Test', phase = 'ended', outcome = 'failed' } } },
  } },
} }
local query = '?filter[step_num]=3&filter[execution]=1'
f.responses['https://circleci.com/api/v3/jobs/' .. job_uuid .. '/stdout' .. query] = { raw = 'v3 worker1 step3\n' }
f.responses['https://circleci.com/api/v3/jobs/' .. job_uuid .. '/stderr' .. query] = { raw = 'failure details\n' }
details = run(function() return service.details(ctx, app) end)
assert(#details.steps == 2 and details.steps[2].provider_data.modern and details.steps[2].provider_data.execution == 1)
log = run(function() return service.log(ctx, details.check, details.steps[2]) end)
assert(log.text:find('v3 worker1 step3') and log.text:find('Stderr\nfailure details'))
for _, call in ipairs(f.ci_calls) do if call.path:find('/api/v3/', 1, true) then assert(call.opts.stdin:find('Authorization: Bearer', 1, true)) end end
vim.env.CIRCLE_TOKEN = token; f.cleanup()
print('PASS: CircleCI token fallback, verified OAuth/App pipelines, distinct parallel logs, unsigned fresh downloads, expiry/identity guards and v3 wire format/stdout/stderr')
