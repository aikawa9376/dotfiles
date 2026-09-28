local M = {}

local function read_env(path)
  local result = {}
  local file = io.open(path, 'r')
  if not file then
    return result
  end
  for line in file:lines() do
    local key, value = line:match('^%s*([%a_][%w_]*)%s*=%s*(.-)%s*$')
    if key then
      local quote = value:sub(1, 1)
      if (quote == '"' or quote == "'") and value:sub(-1) == quote then
        value = value:sub(2, -2)
      end
      result[key] = value
    end
  end
  file:close()
  return result
end

function M.environment(source_file, config)
  local dir = vim.fn.fnamemodify(source_file, ':p:h')
  local env = {}
  -- Later files override earlier files (e.g. .env.local overrides .env).
  for index = 1, #(config.env_files or {}) do
    local path = config.env_files[index]
    if not path:match('^/') then
      path = dir .. '/' .. path
    end
    for key, value in pairs(read_env(path)) do
      env[key] = value
    end
  end
  for key, value in pairs(config.variables or {}) do
    env[key] = tostring(value)
  end
  return env
end

function M.resolve(value, env)
  local missing
  local expanded = value:gsub('{{%s*([%w_]+)%s*}}', function(key)
    local found = env[key]
    if found == nil then
      found = os.getenv(key)
    end
    if found == nil then
      missing = key
      return ''
    end
    return tostring(found)
  end)
  if missing then
    return nil, 'Undefined variable: ' .. missing
  end
  return expanded
end

function M.expand_request(request, env)
  local copy = vim.deepcopy(request)
  local value, err = M.resolve(copy.url, env)
  if not value then return nil, err end
  copy.url = value
  for key, header in pairs(copy.headers) do
    value, err = M.resolve(header, env)
    if not value then return nil, err end
    copy.headers[key] = value
  end
  if copy.body then
    value, err = M.resolve(copy.body, env)
    if not value then return nil, err end
    copy.body = value
  end
  return copy
end

return M
