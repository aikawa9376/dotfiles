local M = {}
local transport = require('git.features.ci.transport')
local model = require('git.features.ci.model')
local scalar = require('git.features.github').scalar
local function uuid(value) return type(value) == 'string' and value:match('^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$') end
function M.locator(check)
  local host, path = model.url_parts(check.url)
  if host ~= 'circleci.com' and host ~= 'app.circleci.com' and host ~= transport.circle_host() then return nil end
  local vcs, org, repo, number = (path or ''):match('^/(gh)/([%w_.%-]+)/([%w_.%-]+)/(%d+)$')
  if vcs then return { slug = table.concat({ vcs, org, repo }, '/'), number = number, legacy = true } end
  local kind, owner, project, workflow, job = (path or ''):match('^/pipelines/([%w]+)/([%w_.%-]+)/([%w_.%-]+)/%d+/workflows/([%x%-]+)/jobs/(%d+)$')
  if kind and uuid(workflow) then
    vcs = ({ github = 'gh', gh = 'gh', circleci = 'circleci' })[kind]
    if not vcs or vcs == 'circleci' and (not uuid(owner) or not uuid(project)) then return nil end
    return { slug = table.concat({ vcs, owner, project }, '/'), number = job, workflow = workflow, legacy = vcs == 'gh' }
  end
end
local function verify_pipeline(ctx, check, pipeline)
  local vcs = scalar(pipeline.vcs) or {}
  local url = model.web_url(vcs.origin_repository_url)
  local expected = ('https://%s/%s'):format(ctx.host, ctx.repo)
  if vcs.revision ~= check.head_sha or not url or url:gsub('%.git$', '') ~= expected then
    error('CircleCI pipeline repository/commit mismatch; logs are unavailable.', 0)
  end
end
local function verify_build(ctx, check, locator, build)
  if tostring(build.build_num) ~= locator.number or build.vcs_revision ~= check.head_sha then error('CircleCI build/commit mismatch; logs are unavailable.', 0) end
  local repo = scalar(build.username) and scalar(build.reponame) and build.username .. '/' .. build.reponame
  local url = model.web_url(build.vcs_url)
  if repo ~= ctx.repo and (not url or url:gsub('%.git$', '') ~= ('https://%s/%s'):format(ctx.host, ctx.repo)) then
    error('CircleCI repository mismatch; logs are unavailable.', 0)
  end
end
local function workflow_jobs(ctx, workflow_id)
  local items, page, seen = {}, nil, {}
  repeat
    local suffix = page and ('?page-token=' .. vim.uri_encode(page, 'rfc2396')) or ''
    local response = transport.circle_json(ctx, '/api/v2/workflow/' .. workflow_id .. '/job' .. suffix)
    if type(response.items) ~= 'table' then error('Invalid CircleCI workflow jobs response', 0) end
    vim.list_extend(items, response.items)
    page = scalar(response.next_page_token)
    if page and seen[page] then error('Repeated CircleCI pagination token', 0) end
    if page then seen[page] = true end
  until not page
  return items
end
function M.details(ctx, check, details)
  local locator = M.locator(check)
  if not locator then details.message = 'A unique CircleCI job could not be resolved from this check; o opens the web view.'; return details end
  if not vim.env.CIRCLE_TOKEN or vim.env.CIRCLE_TOKEN == '' then
    details.message = 'CircleCI authentication required: set CIRCLE_TOKEN; o opens the web page.'; return details
  end
  local job = transport.circle_json(ctx, '/api/v2/project/' .. locator.slug .. '/job/' .. locator.number)
  if tostring(job.number) ~= locator.number or job.project and job.project.slug ~= locator.slug then error('CircleCI job/project mismatch', 0) end
  local workflow_id = locator.workflow or job.latest_workflow and job.latest_workflow.id
  assert(not locator.workflow or not job.latest_workflow or job.latest_workflow.id == locator.workflow,
    'CircleCI job/workflow identity mismatch')
  local pipeline_id = job.pipeline and job.pipeline.id
  if workflow_id then
    if not uuid(workflow_id) then error('Invalid CircleCI workflow identity', 0) end
    local workflow = transport.circle_json(ctx, '/api/v2/workflow/' .. workflow_id)
    if workflow.id ~= workflow_id then error('CircleCI workflow identity mismatch', 0) end
    pipeline_id = workflow.pipeline_id
    details.workflow = workflow.name
    details.workflow_status = workflow.status
  end
  if not uuid(pipeline_id) then error('CircleCI pipeline identity unavailable; use o for the web view.', 0) end
  verify_pipeline(ctx, check, transport.circle_json(ctx, '/api/v2/pipeline/' .. pipeline_id))
  details.workflow_id = workflow_id -- Publish writable identity only after verification.
  details.started_at, details.completed_at = scalar(job.started_at), scalar(job.stopped_at)
  details.steps = {}
  -- Workflow job UUIDs are distinct from per-project job numbers. Resolve the
  -- exact numbered job in this workflow before using the current v3 API.
  local job_id = uuid(job.id) and job.id or nil
  local modern_error
  if not job_id and workflow_id then
    local ok, items = pcall(workflow_jobs, ctx, workflow_id)
    if ok then
      local matches = {}
      for _, item in ipairs(items) do
        if tostring(item.job_number) == locator.number and uuid(item.id) then matches[#matches + 1] = item.id end
      end
      if #matches == 1 then job_id = matches[1] end
    else
      modern_error = items
    end
  end
  if job_id then
    local ok, response = pcall(transport.circle_json, ctx, '/api/v3/jobs/' .. job_id)
    if ok then
      -- Wire shape/numbering verified against official circleci-cli v1.5.0
      -- internal/apiclient/job.go: jobWire, toJobV3, GetJobStdout/GetJobStderr.
      local data = scalar(response.data)
      local refs = data and scalar(data.references) or {}
      local attrs = data and scalar(data.attributes) or {}
      if not data or data.id ~= job_id or not refs.pipeline or refs.pipeline.id ~= pipeline_id
        or workflow_id and (not refs.workflow or refs.workflow.id ~= workflow_id) then
        error('CircleCI v3 job/pipeline/workflow identity mismatch', 0)
      end
      for index, execution in ipairs(scalar(attrs.parallel_executions) or {}) do
        for _, step in ipairs(scalar(execution.steps) or {}) do
          if type(step.num) ~= 'number' or step.num < 0 or step.num % 1 ~= 0 then error('Invalid CircleCI step number', 0) end
          local state = step.phase == 'ended' and (scalar(step.outcome) or 'ended') or step.phase or 'pending'
          details.steps[#details.steps + 1] = { id = job_id .. ':' .. (index - 1) .. ':' .. step.num, number = step.num,
            name = (step.name or 'Step') .. ' [parallel ' .. (index - 1) .. ']', state = state,
            started_at = scalar(step.started_at), completed_at = scalar(step.ended_at),
            log_available = (step.phase == 'started' or step.phase == 'ended') and model.bucket(state) ~= 'skipping',
            log_reason = 'CircleCI step has not started or was not run.',
            provider_data = { modern = true, job_id = job_id, execution = index - 1, position = step.num } }
        end
      end
      if #details.steps == 0 then details.message = 'No CircleCI steps available yet; R refreshes, o opens the web view.' end
      return details
    end
    modern_error = response
  end
  if not locator.legacy then
    details.message = 'CircleCI GitHub App job verified; native steps unavailable: ' .. (modern_error or 'a unique job UUID could not be resolved.') .. ' Use o for the web view.'
    return details
  end
  local build = transport.circle_json(ctx, '/api/v1.1/project/' .. locator.slug .. '/' .. locator.number)
  verify_build(ctx, check, locator, build)
  for step_index, step in ipairs(scalar(build.steps) or {}) do
    for action_index, action in ipairs(scalar(step.actions) or {}) do
      local parallel = tonumber(action.index) or 0
      local position = tonumber(action.step) or step_index - 1
      local available = model.web_url(scalar(action.output_url)) ~= nil
      details.steps[#details.steps + 1] = { id = locator.slug .. ':' .. locator.number .. ':' .. position .. ':' .. parallel .. ':' .. action_index,
        number = position, name = (scalar(action.name) or scalar(step.name) or 'Step') .. ' [parallel ' .. parallel .. ']',
        state = scalar(action.status) or 'pending', started_at = scalar(action.start_time), completed_at = scalar(action.end_time),
        log_available = available, log_reason = 'CircleCI step output is not generated or no longer available.',
        provider_data = { slug = locator.slug, job_number = locator.number, step_index = step_index, action_index = action_index, position = position, execution = parallel } }
    end
  end
  if #details.steps == 0 then details.message = 'No CircleCI steps available yet; R refreshes, o opens the web view.' end
  return details
end
function M.log(ctx, check, step)
  local data = step.provider_data
  if data.modern then
    local base = '/api/v3/jobs/' .. data.job_id
    local query = '?filter[step_num]=' .. data.position .. '&filter[execution]=' .. data.execution
    local results = require('git.features.async').gather({
      function() local text, truncated = transport.circle_raw(ctx, base .. '/stdout' .. query, true); return { text = text, truncated = truncated } end,
      function() local text, truncated = transport.circle_raw(ctx, base .. '/stderr' .. query, true); return { text = text, truncated = truncated } end,
    })
    for _, result in ipairs(results) do if not result.ok then error(result.value, 0) end end
    local stdout, stderr = results[1].value, results[2].value
    return { text = (stdout.text ~= '' and 'Stdout\n' .. stdout.text or '') .. (stderr.text ~= '' and '\nStderr\n' .. stderr.text or ''),
      truncated = stdout.truncated or stderr.truncated, scope = 'Step log · parallel ' .. data.execution }
  end
  -- Reacquire a presigned URL for every uncached/retried read; only locators are
  -- retained in state. Never send CIRCLE_TOKEN to this output URL.
  local build = transport.circle_json(ctx, '/api/v1.1/project/' .. data.slug .. '/' .. data.job_number)
  verify_build(ctx, check, { number = data.job_number }, build)
  local raw_step = (build.steps or {})[data.step_index]
  local action = raw_step and (raw_step.actions or {})[data.action_index]
  if not action or (tonumber(action.step) or data.step_index - 1) ~= data.position or (tonumber(action.index) or 0) ~= data.execution then
    error('CircleCI step/parallel identity changed; refresh details first.', 0)
  end
  local output = transport.download(ctx, action.output_url, nil, true)
  local ok, messages = pcall(vim.json.decode, output)
  if not ok or type(messages) ~= 'table' then error('Invalid CircleCI step output; R retries with a fresh signed URL.', 0) end
  local parts = {}; for _, entry in ipairs(messages) do if type(entry.message) == 'string' then parts[#parts + 1] = entry.message end end
  return { text = table.concat(parts), scope = 'Step log · parallel ' .. data.execution }
end
return M
