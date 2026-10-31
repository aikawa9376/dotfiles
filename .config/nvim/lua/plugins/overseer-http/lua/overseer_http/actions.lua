local M = {}

local function is_http(task)
  return task.metadata and task.metadata.overseer_http ~= nil
end

function M.build()
  local result = require('overseer_http.result')
  return {
    ['HTTP: Open Body'] = {
      condition = is_http,
      run = result.open_body,
    },
    ['HTTP: Open Headers'] = {
      condition = is_http,
      run = result.open_headers,
    },
    ['HTTP: Save Body to File'] = {
      condition = is_http,
      run = result.save_body,
    },
    ['HTTP: Copy cURL'] = {
      condition = is_http,
      run = result.copy_curl,
    },
    ['HTTP: Repeat Request'] = {
      condition = is_http,
      run = function(task) task:restart(true) end,
    },
    ['HTTP: Open Source Request'] = {
      condition = is_http,
      run = result.open_source,
    },
  }
end

return M
