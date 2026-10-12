local M = {}
local transport = require('git.features.ci.transport')
local model = require('git.features.ci.model')
local scalar = require('git.features.github').scalar
function M.list(ctx, sha)
  if type(sha) ~= 'string' or not sha:match('^%x+$') or #sha < 7 then error('Invalid PR head SHA', 0) end
  local prefix = 'repos/' .. ctx.repo .. '/commits/' .. sha
  local results = require('git.features.async').gather({
    function() return transport.pages(ctx, prefix .. '/check-runs?filter=all', 'check_runs') end,
    function() return transport.pages(ctx, prefix .. '/statuses') end,
  })
  for _, result in ipairs(results) do if not result.ok then error(result.value, 0) end end
  return model.normalize(results[1].value, results[2].value, ctx, sha)
end
function M.details(ctx, selected)
  local details = { check = selected, steps = {}, annotations = {} }
  local ok, result = pcall(function()
    local check, err
    if selected.check_run_id then
      local raw = transport.github(ctx, 'repos/' .. ctx.repo .. '/check-runs/' .. selected.check_run_id)
      if raw.head_sha ~= selected.head_sha or raw.id ~= selected.check_run_id then error('Selected check no longer matches this commit.', 0) end
      check = model.check(raw, ctx, selected.head_sha, 'check_run')
    else
      check, err = model.match(selected, M.list(ctx, selected.head_sha))
      if not check then error(err, 0) end
    end
    details.check = check
    if check.kind == 'check_run' then
      local output = scalar(check.raw.output) or {}
      details.description = scalar(output.title) or check.description
      details.summary = scalar(output.summary) or scalar(output.text)
      local annotated, annotations = pcall(transport.pages, ctx, 'repos/' .. ctx.repo .. '/check-runs/' .. check.check_run_id .. '/annotations')
      if annotated then details.annotations = annotations else details.annotation_error = annotations end
    end
    local adapter = check.provider == 'github_actions' and require('git.features.ci.github_actions')
      or check.provider == 'circleci' and require('git.features.ci.circleci')
    if adapter then return adapter.details(ctx, check, details) end
    details.message = 'Native logs are unavailable for this provider; o opens the web view.'
    return details
  end)
  if not ok then details.message = result end
  return details
end
function M.log(ctx, check, step)
  if not step.log_available then error(step.log_reason or 'This step has no native log; o opens the web view.', 0) end
  local adapter = check.provider == 'github_actions' and require('git.features.ci.github_actions')
    or check.provider == 'circleci' and require('git.features.ci.circleci')
  if not adapter then error('Native logs are unavailable for this provider', 0) end
  local result = adapter.log(ctx, check, step)
  if #result.text > transport.limit() then result.text, result.truncated = result.text:sub(1, transport.limit()), true end
  result.text = transport.clean(result.text)
  if result.text == '' then error('No log output was returned; it may not have been generated yet. R retries.', 0) end
  return result
end
return M
