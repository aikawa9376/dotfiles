local M = {}

function M.build(request, paths, executable)
  local args = {
    executable or 'curl', '--silent', '--show-error', '--globoff',
    '--request', request.method, '--dump-header', paths.headers,
    '--output', paths.body, '--write-out', '%{http_code}\n',
  }
  local options = request.curl_options or {}
  for _, option in ipairs({
    { 'insecure', '--insecure' },
    { 'location', '--location' },
    { 'compressed', '--compressed' },
    { 'max_time', '--max-time', true },
    { 'connect_timeout', '--connect-timeout', true },
  }) do
    local value = options[option[1]]
    if value then
      args[#args + 1] = option[2]
      if option[3] then args[#args + 1] = value end
    end
  end
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
