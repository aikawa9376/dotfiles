local M = {}
local transport = require('git.features.ci.transport')
local model = require('git.features.ci.model')
local scalar = require('git.features.github').scalar
local function path(ctx, tail) return 'repos/' .. ctx.repo .. '/' .. tail end
local function identity(ctx, check, job)
  local host, check_path = model.url_parts(job.check_run_url)
  local api_host = ctx.host == 'github.com' and 'api.github.com' or ctx.host
  local expected = '/repos/' .. ctx.repo .. '/check-runs/' .. tostring(check.check_run_id)
  return job.head_sha == check.head_sha and host == api_host
    and (check_path == expected or ctx.host ~= 'github.com' and check_path == '/api/v3' .. expected)
end
function M.details(ctx, check, details)
  local host, url_path = model.url_parts(check.url)
  if host ~= ctx.host then details.message = 'GitHub Actions job link does not match this repository host.'; return details end
  local repo_path = '/' .. ctx.repo .. '/'
  if not url_path or url_path:sub(1, #repo_path) ~= repo_path then
    details.message = 'GitHub Actions job link does not match this repository.'; return details
  end
  local tail = url_path:sub(#repo_path + 1)
  local run, job_id = tail:match('^actions/runs/(%d+)/job/(%d+)$')
  local attempt
  if not job_id then run, attempt, job_id = tail:match('^actions/runs/(%d+)/attempts/(%d+)/job/(%d+)$') end
  if not job_id then job_id = tail:match('^runs/(%d+)$') end
  if not job_id then job_id = tail:match('^runs/%d+/jobs/(%d+)$') end
  if job_id then
    local job = transport.github(ctx, path(ctx, 'actions/jobs/' .. job_id))
    if not identity(ctx, check, job) or tostring(job.id) ~= job_id or run and tostring(job.run_id) ~= run
      or attempt and tostring(job.run_attempt) ~= attempt then
      details.message = 'Check/job/commit identity mismatch; logs are unavailable.'; return details
    end
    details.job = job
  else
    run = tail:match('^actions/runs/(%d+)$')
    if not run then details.message = 'A unique Actions job could not be resolved; use o for the web view.'; return details end
    local jobs = transport.pages(ctx, path(ctx, 'actions/runs/' .. run .. '/jobs?filter=all'), 'jobs')
    local matches = {}
    for _, job in ipairs(jobs) do if identity(ctx, check, job) and tostring(job.run_id) == run then matches[#matches + 1] = job end end
    if #matches ~= 1 then details.message = 'A unique Actions job could not be resolved; use o for the web view.'; return details end
    details.job = matches[1]
  end
  local job = details.job
  details.workflow = scalar(job.workflow_name)
  details.started_at, details.completed_at = scalar(job.started_at), scalar(job.completed_at)
  details.attempt = tonumber(scalar(job.run_attempt) or attempt)
  details.steps = {}
  -- The API accepts zero-based position, not the often non-contiguous `number`
  -- returned for display (post steps can have numbers such as 16 and 17).
  for index, step in ipairs(scalar(job.steps) or {}) do
    local state = scalar(step.conclusion) or step.status or 'pending'
    local available = step.status == 'completed' and model.bucket(state) ~= 'skipping'
    details.steps[#details.steps + 1] = { id = tostring(job.id) .. ':' .. tostring(details.attempt or 'unknown') .. ':' .. (index - 1),
      number = step.number, name = step.name or 'Step', state = state, started_at = scalar(step.started_at), completed_at = scalar(step.completed_at),
      log_available = available, log_reason = available and nil or 'Step logs are not generated yet or this step was skipped.',
      provider_data = { job_id = job.id, run_id = job.run_id, attempt = details.attempt, position = index - 1 } }
  end
  if #details.steps == 0 then details.message = 'This job has no steps yet; R refreshes, o opens the web view.' end
  return details
end
function M.log(ctx, check, step)
  local data = step.provider_data
  local base = path(ctx, 'actions/jobs/' .. tostring(data.job_id))
  local ok, text, truncated = pcall(transport.github, ctx, base .. '/steps/' .. data.position .. '/logs', true)
  if ok then return { text = text, truncated = truncated, scope = 'Step log' } end
  -- Older GHES versions lack this endpoint. Never call a whole-job log a step log.
  if not tostring(text):find('HTTP 404', 1, true) then error(text, 0) end
  local full, cut = transport.github(ctx, base .. '/logs', true)
  return { text = full, truncated = cut, scope = 'Job log (step endpoint unavailable)' }
end
return M
