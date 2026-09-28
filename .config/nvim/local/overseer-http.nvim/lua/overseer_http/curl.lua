local M = {}

function M.build(request, paths, executable)
  local args = {
    executable or 'curl', '--silent', '--show-error', '--globoff',
    '--request', request.method, '--dump-header', paths.headers,
    '--output', paths.body, '--write-out', '%{http_code}\n',
  }
  if request.method == 'HEAD' then
    args[#args + 1] = '--head'
  end
  local keys = vim.tbl_keys(request.headers)
  table.sort(keys)
  for _, key in ipairs(keys) do
    args[#args + 1] = '--header'
    args[#args + 1] = key .. ': ' .. request.headers[key]
  end
  if request.body ~= nil then
    args[#args + 1] = '--data-binary'
    args[#args + 1] = '@' .. paths.request_body
  end
  args[#args + 1] = '--url'
  args[#args + 1] = request.url
  return args
end

return M
