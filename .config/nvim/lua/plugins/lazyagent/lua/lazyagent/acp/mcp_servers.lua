local M = {}

local function named_values(value)
  local items = {}
  if type(value) ~= "table" then return items end
  if vim.islist(value) then
    for _, item in ipairs(value) do
      if type(item) == "table" and item.name and item.value ~= nil then
        items[#items + 1] = { name = tostring(item.name), value = tostring(item.value) }
      end
    end
    return items
  end
  local names = vim.tbl_keys(value)
  table.sort(names)
  for _, name in ipairs(names) do
    if value[name] ~= nil then items[#items + 1] = { name = tostring(name), value = tostring(value[name]) } end
  end
  return items
end

local function absolute_command(command)
  command = vim.fn.expand(tostring(command or ""))
  if command == "" then return nil end
  if command:sub(1, 1) == "/" or command:match("^%a:[/\\]") then return vim.fs.normalize(command) end
  local resolved = vim.fn.exepath(command)
  return resolved ~= "" and resolved or nil
end

local function normalize_one(name, spec)
  if type(spec) ~= "table" or spec.enabled == false then return nil end
  name = tostring(spec.name or name or "")
  if name == "" then return nil, "MCP server name is missing" end
  if spec.command then
    local command = absolute_command(spec.command)
    if not command then return nil, "MCP server executable not found: " .. tostring(spec.command) end
    return {
      name = name,
      command = command,
      args = vim.deepcopy(type(spec.args) == "table" and spec.args or {}),
      env = named_values(spec.env),
    }
  end
  if spec.url then
    local transport = tostring(spec.type or spec.transport or "http"):lower()
    if transport ~= "http" and transport ~= "sse" then return nil, "unsupported MCP transport: " .. transport end
    return {
      type = transport,
      name = name,
      url = tostring(spec.url),
      headers = named_values(spec.headers),
    }
  end
  return nil, "MCP server must define command or url: " .. name
end

function M.normalize(config)
  local servers, errors = {}, {}
  if type(config) ~= "table" then return servers, errors end
  if vim.islist(config) then
    for index, spec in ipairs(config) do
      local server, err = normalize_one(spec and spec.name or tostring(index), spec)
      if server then servers[#servers + 1] = server elseif err then errors[#errors + 1] = err end
    end
  else
    local names = vim.tbl_keys(config)
    table.sort(names)
    for _, name in ipairs(names) do
      local server, err = normalize_one(name, config[name])
      if server then servers[#servers + 1] = server elseif err then errors[#errors + 1] = err end
    end
  end
  return servers, errors
end

function M.merge(global_config, agent_config)
  local merged, positions = {}, {}
  for _, config in ipairs({ global_config, agent_config }) do
    local servers = M.normalize(config)
    for _, server in ipairs(servers) do
      local position = positions[server.name]
      if position then merged[position] = server else
        merged[#merged + 1] = server
        positions[server.name] = #merged
      end
    end
  end
  return merged
end

function M.for_capabilities(servers, capabilities)
  local supported = {}
  capabilities = type(capabilities) == "table" and capabilities or {}
  for _, server in ipairs(servers or {}) do
    if not server.type
      or (server.type == "http" and capabilities.http == true)
      or (server.type == "sse" and capabilities.sse == true)
    then
      supported[#supported + 1] = vim.deepcopy(server)
    end
  end
  return supported
end

return M
