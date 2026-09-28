local M = {}

local function write_bytes(path, contents)
  local fd, err = vim.uv.fs_open(path, 'w', 384)
  if not fd then return nil, err end
  local offset = 0
  while offset < #contents do
    local written, write_err = vim.uv.fs_write(fd, contents:sub(offset + 1), offset)
    if not written or written == 0 then
      vim.uv.fs_close(fd)
      return nil, write_err or 'Could not write request body'
    end
    offset = offset + written
  end
  vim.uv.fs_close(fd)
  return true
end

function M.title(request)
  return 'HTTP: ' .. (request.name and request.name ~= '' and request.name or (request.method .. ' (line ' .. request.line_start .. ')'))
end

function M.definition(request)
  local config = require('overseer_http').config
  if vim.fn.executable(config.curl.executable) == 0 then
    return nil, 'curl executable not found: ' .. config.curl.executable
  end
  local env = require('overseer_http.variables').environment(request.source_file, config)
  local expanded, err = require('overseer_http.variables').expand_request(request, env)
  if not expanded then return nil, err end
  if expanded.url:find('[\r\n]') then return nil, 'Invalid URL: newline is not allowed' end
  for key, value in pairs(expanded.headers) do
    if key:find('[\r\n]') or value:find('[\r\n]') then
      return nil, 'Invalid header: newline is not allowed'
    end
  end
  local dir = vim.fn.tempname()
  local ok, mkdir_err = vim.uv.fs_mkdir(dir, 448)
  if not ok then return nil, mkdir_err end
  local paths = {
    dir = dir,
    request_body = dir .. '/request-body',
    headers = dir .. '/response-headers',
    body = dir .. '/response-body',
  }
  if expanded.body ~= nil then
    ok, err = write_bytes(paths.request_body, expanded.body)
    if not ok then
      vim.fn.delete(dir, 'rf')
      return nil, err
    end
  end
  local args = require('overseer_http.curl').build(expanded, paths, config.curl.executable)
  local title = M.title(request)
  return {
    name = title,
    cmd = args,
    cwd = vim.fn.fnamemodify(request.source_file, ':p:h'),
    strategy = { 'jobstart', use_terminal = false },
    components = { 'overseer_http.result' },
    metadata = {
      overseer_http = {
        title = title,
        request = expanded,
        args = args,
        paths = paths,
      },
    },
  }
end

function M.create(request)
  local definition, err = M.definition(request)
  if not definition then return nil, err end
  local ok, task = pcall(require('overseer').new_task, definition)
  if not ok then
    vim.fn.delete(definition.metadata.overseer_http.paths.dir, 'rf')
    return nil, task
  end
  return task
end

function M.run(request)
  local task, err = M.create(request)
  if not task then return nil, err end
  if not task:start() then
    task:dispose(true)
    return nil, 'Could not start curl task'
  end
  require('overseer').open({ enter = false, focus_task_id = task.id })
  return task
end

return M
