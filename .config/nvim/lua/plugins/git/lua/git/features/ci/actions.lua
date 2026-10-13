local M = {}
local github = require('git.features.github')
local transport = require('git.features.ci.transport')
function M.perform(ctx, selected, operation)
  assert(vim.tbl_contains({ 'rerun', 'failed', 'cancel' }, operation), 'Invalid CI operation')
  -- Re-resolve the check/job/workflow identity before every remote write.
  local details = require('git.features.ci.service').details(ctx, selected)
  local check = details.check
  if check.provider == 'github_actions' then
    local job = details.job
    assert(job and job.run_id, 'Actions job identity is unavailable; refresh the check')
    local endpoint = ('repos/%s/actions/runs/%s'):format(ctx.repo, job.run_id)
    local run = transport.github(ctx, endpoint)
    assert(run.id == job.run_id and run.head_sha == check.head_sha, 'Workflow run/commit identity changed')
    assert(type(run.status) == 'string', 'Workflow run status is unavailable; refresh the check')
    if operation == 'cancel' then
      assert(run.status ~= 'completed', 'This workflow run has already finished')
    else assert(run.status == 'completed', 'Wait for the workflow to finish before rerunning it') end
    local suffix = ({ rerun = '/rerun', failed = '/rerun-failed-jobs', cancel = '/cancel' })[operation]
    return github.api(ctx, endpoint .. suffix, nil, 'POST')
  elseif check.provider == 'circleci' then
    local id = details.workflow_id
    assert(id, 'CircleCI workflow identity is unavailable; refresh the check')
    local active = vim.tbl_contains({ 'running', 'on_hold', 'failing' }, details.workflow_status)
    local finished = vim.tbl_contains({ 'success', 'failed', 'error', 'canceled', 'unauthorized', 'not_run' }, details.workflow_status)
    assert(operation == 'cancel' and active or operation ~= 'cancel' and finished,
      operation == 'cancel' and 'This workflow has already finished' or 'Wait for the workflow to finish before rerunning it')
    return transport.circle_post(ctx, '/api/v2/workflow/' .. id .. (operation == 'cancel' and '/cancel' or '/rerun'),
      operation == 'failed' and { from_failed = true } or vim.empty_dict())
  end
  error('This CI provider does not support native workflow actions', 0)
end
function M.menu(ctx, check, done)
  if check.provider ~= 'github_actions' and check.provider ~= 'circleci' then
    vim.notify('Native workflow actions support GitHub Actions and CircleCI'); return
  end
  local function run(operation)
    if operation == 'cancel' and vim.fn.confirm('Cancel the workflow containing ' .. check.name .. '?', '&Cancel workflow\n&Keep running', 2) ~= 1 then return end
    require('git.features.github_actions').run(ctx, function(target) return M.perform(target, check, operation) end,
      function() vim.notify(operation == 'cancel' and 'Workflow cancellation requested' or 'Workflow rerun requested'); if done then done() end end, true)
  end
  require('git.features.transient_menu').show({ kind = 'ci-actions', title = 'Workflow actions', context = check.name,
    groups = { { title = 'Remote workflow', actions = {
      { key = 'r', label = 'Rerun entire workflow', run = function() run('rerun') end },
      { key = 'f', label = 'Rerun failed jobs', run = function() run('failed') end },
      { key = 'x', label = 'Cancel workflow…', run = function() run('cancel') end },
    } } } })
end
return M
