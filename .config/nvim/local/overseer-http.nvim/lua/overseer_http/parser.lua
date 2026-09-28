local M = {}

local methods = { GET = true, POST = true, PUT = true, PATCH = true, DELETE = true, HEAD = true, OPTIONS = true }

---Parse buffer lines without depending on Neovim or Overseer.
---@return table[]? requests
---@return string? error
function M.parse(lines, source_file)
  local requests = {}
  local block_start = 1
  local range_start = 1
  local block_name

  local function parse_block(last_line)
    local first = block_start
    while first <= last_line and lines[first]:match('^%s*$') do
      first = first + 1
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
      local key, value = lines[cursor]:match('^%s*([^:%s][^:]*):%s*(.*)$')
      if not key then
        return nil, string.format('%s:%d: Invalid header', source_file, cursor)
      end
      key = key:gsub('%s+$', '')
      if key:find('%s') then
        return nil, string.format('%s:%d: Invalid header', source_file, cursor)
      end
      headers[key] = value
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
