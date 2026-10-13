local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.ci_fixture').new()
local api, model, async = require('git.features.ci.actions'), require('git.features.ci.model'), require('git.features.async')
local ctx = { root = f.root, host = 'ghe.example.test', repo = 'org/repo', number = 7, url = f.pr.url }
local function run(fn)
  local done, success, value
  async.run(f.root, fn, function(ok, result) done, success, value = true, ok, result end)
  assert(vim.wait(5000, function() return done end, 10)); return success, value
end
local check = model.check(f.ci_run, ctx, f.head, 'check_run')
local workflow = { id = 11, head_sha = f.head, status = 'completed' }
f.responses['repos/org/repo/actions/runs/11'] = function() return workflow end
for _, endpoint in ipairs({ '/rerun', '/rerun-failed-jobs', '/cancel' }) do f.responses['repos/org/repo/actions/runs/11' .. endpoint] = { raw = '' } end
assert(run(function() return api.perform(ctx, check, 'rerun') end))
assert(run(function() return api.perform(ctx, check, 'failed') end))
assert(not run(function() return api.perform(ctx, check, 'cancel') end))
workflow.status = 'in_progress'; assert(run(function() return api.perform(ctx, check, 'cancel') end))
assert(not run(function() return api.perform(ctx, check, 'rerun') end))
workflow.head_sha = f.base
assert(not run(function() return api.perform(ctx, check, 'cancel') end))
for _, call in ipairs(f.ci_calls) do if call.path:match('/rerun') or call.path:match('/cancel$') then
  assert(vim.tbl_contains(call.argv, 'POST'), 'CI action must issue POST')
end end
workflow.head_sha, workflow.status = f.head, 'completed'
local ui, view = require('helpers.pr_ui').new(f), require('git.features.ci.view')
ui.open(); ui.key('>', ui.row('CI:')); ui.key('<CR>', ui.row('test: FAILURE'))
local detail = vim.api.nvim_get_current_buf(); ui.wait(function() return view.details(detail) ~= nil end)
vim.fn.maparg('a', 'n', false, true).callback()
assert(vim.b.git_action_menu_kind == 'ci-actions')
local previous = f.count('/rerun')
vim.fn.maparg('r', 'n', false, true).callback()
ui.wait(function() return f.count('/rerun') > previous and not async.busy(f.root) end)
vim.fn.maparg('q', 'n', false, true).callback(); vim.api.nvim_buf_delete(ui.buf, { force = true })
local token = vim.env.CIRCLE_TOKEN; vim.env.CIRCLE_TOKEN = 'test-circle-token'
local id, pipeline = '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222'
local circle = model.check({ id = 44, context = 'ci/circleci: build', state = 'failure', target_url = 'https://circleci.com/gh/org/repo/22' }, ctx, f.head, 'status')
f.responses['repos/org/repo/commits/' .. f.head .. '/statuses?per_page=100&page=1'] = { circle.raw }
local prefix = 'https://circleci.com/api/v2/'
f.responses[prefix .. 'project/gh/org/repo/job/22'] = { number = 22, latest_workflow = { id = id } }
local circle_workflow = { id = id, pipeline_id = pipeline, name = 'Build', status = 'failed' }
f.responses[prefix .. 'workflow/' .. id] = function() return circle_workflow end
local circle_pipeline = { vcs = { revision = f.head, origin_repository_url = 'https://ghe.example.test/org/repo' } }
f.responses[prefix .. 'pipeline/' .. pipeline] = function() return circle_pipeline end
f.responses[prefix .. 'workflow/' .. id .. '/job'] = { items = {} }
f.responses['https://circleci.com/api/v1.1/project/gh/org/repo/22'] = { build_num = 22, vcs_revision = f.head, username = 'org', reponame = 'repo', steps = {} }
f.responses[prefix .. 'workflow/' .. id .. '/rerun'] = { workflow_id = id, http = 202 }
f.responses[prefix .. 'workflow/' .. id .. '/cancel'] = { message = 'Canceled', http = 202 }
assert(run(function() return api.perform(ctx, circle, 'failed') end))
local call = f.ci_calls[#f.ci_calls]
assert(call.path:match('/rerun$') and call.opts.stdin:find('request = "POST"', 1, true) and call.opts.stdin:find('from_failed', 1, true))
assert(not table.concat(call.argv, ' '):find(vim.env.CIRCLE_TOKEN, 1, true))
circle_workflow.status = 'running'; assert(run(function() return api.perform(ctx, circle, 'cancel') end))
circle_pipeline.vcs.revision = f.base
local before = f.count('/cancel')
assert(not run(function() return api.perform(ctx, circle, 'cancel') end) and f.count('/cancel') == before,
  'Failed pipeline identity checks must not publish a writable workflow target')
vim.env.CIRCLE_TOKEN = token; f.cleanup()
print('PASS: Actions/CircleCI POST rerun/failed/cancel, active/terminal gating, exact run/pipeline identity and token-free argv')
