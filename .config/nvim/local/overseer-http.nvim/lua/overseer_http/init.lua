local M = {}

M.config = {
  env_files = { '.env', '.env.local' },
  variables = {},
  curl = { executable = 'curl' },
  response = { pretty_json = true },
  success_status = function(code) return code >= 200 and code < 400 end,
}

local function report(err)
  vim.notify('Overseer HTTP: ' .. err, vim.log.levels.ERROR)
end

function M.parse_buffer()
  if vim.bo.buftype ~= '' or vim.api.nvim_buf_get_name(0) == '' then
    return nil, 'A file-backed .http buffer is required'
  end
  return require('overseer_http.parser').parse(
    vim.api.nvim_buf_get_lines(0, 0, -1, false), vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':p')
  )
end

function M.run_current()
  local requests, err = M.parse_buffer()
  if not requests then report(err); return end
  local request = require('overseer_http.parser').current(requests, vim.api.nvim_win_get_cursor(0)[1])
  if not request then report('No request at cursor'); return end
  local task
  task, err = require('overseer_http.runner').run(request)
  if not task then report(err) end
  return task
end

function M.select()
  local requests, err = M.parse_buffer()
  if not requests then report(err); return end
  vim.ui.select(requests, {
    prompt = 'HTTP request',
    format_item = require('overseer_http.runner').title,
  }, function(request)
    if not request then return end
    local task, run_err = require('overseer_http.runner').run(request)
    if not task then report(run_err) end
  end)
end

function M.run_all()
  local requests, err = M.parse_buffer()
  if not requests then report(err); return end
  for _, request in ipairs(requests) do
    local task
    task, err = require('overseer_http.runner').run(request)
    if not task then report(err); return end
  end
end

function M.jump(direction)
  local requests, err = M.parse_buffer()
  if not requests then report(err); return end
  if #requests == 0 then report('No requests in this file'); return end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local index
  for i, request in ipairs(requests) do
    if request.line_start <= line and line <= request.line_end then
      index = i
      break
    end
  end
  local target = index and ((index - 1 + direction) % #requests + 1)
    or (direction > 0 and 1 or #requests)
  vim.api.nvim_win_set_cursor(0, { requests[target].line_start, 0 })
end

function M.latest_task()
  local source = vim.api.nvim_buf_get_name(0)
  if source ~= '' and vim.bo.buftype == '' and (vim.bo.filetype == 'http' or vim.bo.filetype == 'rest') then
    source = vim.fn.fnamemodify(source, ':p')
  else
    source = nil
  end
  local latest
  for _, task in ipairs(require('overseer').list_tasks()) do
    local info = task.metadata and task.metadata.overseer_http
    if info and (not source or info.request.source_file == source) and (not latest or task.id > latest.id) then
      latest = task
    end
  end
  if not latest then
    vim.notify('Overseer HTTP: No previous request for this file', vim.log.levels.WARN)
  end
  return latest
end

function M.repeat_last()
  local task = M.latest_task()
  if task then task:restart(true) end
end

function M.show_last(kind)
  local task = M.latest_task()
  if not task then return end
  local shown = require('overseer_http.result')[kind == 'headers' and 'open_headers' or 'open_body'](task)
  if shown then require('overseer').open({ enter = false, focus_task_id = task.id }) end
  return shown
end

function M.toggle_response()
  local task = M.latest_task()
  if not task then return end
  local buf = task:get_bufnr()
  local kind = buf and vim.b[buf].overseer_http_response_view == 'body' and 'headers' or 'body'
  if require('overseer_http.result')[kind == 'headers' and 'open_headers' or 'open_body'](task) then
    require('overseer').open({ enter = false, focus_task_id = task.id })
  end
end

function M.copy_last_curl()
  local task = M.latest_task()
  if task then require('overseer_http.result').copy_curl(task) end
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', M.config, opts or {})
  require('overseer_http.provider').register()
  for name, method in pairs({
    OverseerHttpRun = M.run_current,
    OverseerHttpSelect = M.select,
    OverseerHttpRunAll = M.run_all,
    OverseerHttpNext = function() M.jump(1) end,
    OverseerHttpPrev = function() M.jump(-1) end,
    OverseerHttpRepeat = M.repeat_last,
    OverseerHttpBody = function() M.show_last('body') end,
    OverseerHttpHeaders = function() M.show_last('headers') end,
    OverseerHttpToggleResponse = M.toggle_response,
    OverseerHttpCopyCurl = M.copy_last_curl,
  }) do
    vim.api.nvim_create_user_command(name, method, { desc = 'Run HTTP requests as Overseer tasks', force = true })
  end
end

return M
