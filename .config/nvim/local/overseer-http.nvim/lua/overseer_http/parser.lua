local M = {}

local methods = { GET = true, POST = true, PUT = true, PATCH = true, DELETE = true, HEAD = true, OPTIONS = true }

local function is_comment(line)
  return line:match('^%s*#') or line:match('^%s*//')
end

local curl_boolean_options = { insecure = true, location = true, compressed = true }
local curl_numeric_options = { max_time = true, connect_timeout = true }

local function parse_curl_option(line, options, source_file, line_number)
  local name, value = line:match('^%s*@curl_([%w_]+)%s*(.-)%s*$')
  if not name then return true end
  if curl_boolean_options[name] then
    if value ~= '' then
      return nil, string.format('%s:%d: curl_%s does not take a value', source_file, line_number, name)
    end
    options[name] = true
  elseif curl_numeric_options[name] then
    value = value:gsub('^=%s*', '')
    if not value:match('^%d+%.?%d*$') or tonumber(value) <= 0 then
      return nil, string.format('%s:%d: curl_%s requires a positive number of seconds', source_file, line_number, name)
    end
    options[name] = value
  else
    return nil, string.format('%s:%d: Unsupported curl option: curl_%s', source_file, line_number, name)
  end
  return true
end

---Parse buffer lines without depending on Neovim or Overseer.
---@return table[]? requests
---@return string? error
function M.parse(lines, source_file)
  local requests = {}
  local block_start = 1
  local range_start = 1
  local block_name
  local file_variables = {}

  local function parse_block(last_line)
    local first = block_start
    local curl_options = {}
    while first <= last_line do
      local line = lines[first]
      if line:match('^%s*$') or is_comment(line) then
        first = first + 1
      elseif line:match('^%s*@curl_') then
        local ok, err = parse_curl_option(line, curl_options, source_file, first)
        if not ok then return nil, err end
        first = first + 1
      elseif line:match('^%s*@') then
        local key, value = line:match('^%s*@([%a_][%w_]*)%s*=%s*(.-)%s*$')
        if not key then
          return nil, string.format('%s:%d: Invalid variable definition', source_file, first)
        end
        file_variables[key] = value
        first = first + 1
      else
        break
      end
    end
    if first > last_line then
      return true
    end

    local method, url = lines[first]:match('^%s*(%a+)%s+(%S+)%s*$')
    method = method and method:upper()
    if not methods[method] or not url then
      return nil, string.format('%s:%d: Invalid request line', source_file, first)
    end

    local headers = {}
    local cursor = first + 1
    while cursor <= last_line and not lines[cursor]:match('^%s*$') do
      if is_comment(lines[cursor]) then
        -- Comments among headers do not change request options.
      elseif lines[cursor]:match('^%s*@curl_') then
        local ok, err = parse_curl_option(lines[cursor], curl_options, source_file, cursor)
        if not ok then return nil, err end
      else
        local key, value = lines[cursor]:match('^%s*([^:%s][^:]*):%s*(.*)$')
        if not key then
          return nil, string.format('%s:%d: Invalid header', source_file, cursor)
        end
        key = key:gsub('%s+$', '')
        if key:find('%s') then
          return nil, string.format('%s:%d: Invalid header', source_file, cursor)
        end
        headers[key] = value
      end
      cursor = cursor + 1
    end

    local body
    if cursor <= last_line then
      cursor = cursor + 1
      if cursor <= last_line then
        body = table.concat(lines, '\n', cursor, last_line)
      end
    end

    requests[#requests + 1] = {
      name = block_name,
      method = method,
      url = url,
      headers = headers,
      body = body,
      variables = file_variables,
      curl_options = curl_options,
      line_start = range_start,
      line_end = last_line,
      source_file = source_file,
    }
    return true
  end

  for line = 1, #lines + 1 do
    local name = line <= #lines and lines[line]:match('^%s*###%s*(.-)%s*$')
    if name ~= nil or line == #lines + 1 then
      local ok, err = parse_block(line - 1)
      if not ok then
        return nil, err
      end
      block_start = line + 1
      range_start = line
      block_name = name ~= '' and name or nil
    end
  end
  return requests
end

function M.current(requests, line)
  for _, request in ipairs(requests) do
    if request.line_start <= line and line <= request.line_end then
      return request
    end
  end
end

return M
