local Adapter = {}
Adapter.__index = Adapter

local M = {}

local function copy(value)
  return type(value) == "table" and vim.deepcopy(value) or value
end

local function supported(value)
  return value ~= nil and value ~= false and value ~= vim.NIL
end

local function marker(value)
  return supported(value) and {} or nil
end

local function convert_session_capabilities(session)
  if type(session) ~= "table" then return {} end
  local result = {}
  for _, name in ipairs({ "list", "resume", "close", "delete", "additionalDirectories" }) do
    result[name] = marker(session[name])
  end
  return result
end

function M.new(opts)
  opts = type(opts) == "table" and opts or {}
  return setmetatable({
    enabled = opts.enabled == true,
    message_seen = {},
    tool_content = {},
  }, Adapter)
end

function Adapter:outbound(method, params)
  if not self.enabled then return method, params end
  params = copy(params or {})

  if method == "initialize" then
    return method, {
      protocolVersion = 2,
      capabilities = {},
      info = copy(params.clientInfo or {}),
    }
  end
  if method == "authenticate" then return "auth/login", params end
  if method == "logout" then return "auth/logout", params end

  if (method == "session/new" or method == "session/resume") and type(params.mcpServers) == "table" then
    local servers = {}
    for _, server in ipairs(params.mcpServers) do
      if type(server) == "table" and server.type ~= "sse" then
        local normalized = copy(server)
        normalized.type = normalized.type or (normalized.command and "stdio" or "http")
        servers[#servers + 1] = normalized
      end
    end
    params.mcpServers = servers
  end
  return method, params
end

function Adapter:initialize_result(result)
  if not self.enabled or type(result) ~= "table" then return result end
  local capabilities = type(result.capabilities) == "table" and result.capabilities or {}
  local session = type(capabilities.session) == "table" and capabilities.session or {}
  local mcp = type(session.mcp) == "table" and session.mcp or {}
  return {
    protocolVersion = 1,
    agentCapabilities = {
      loadSession = false,
      sessionCapabilities = convert_session_capabilities(session),
      promptCapabilities = copy(session.prompt or {}),
      mcpCapabilities = {
        http = supported(mcp.http),
        sse = false,
      },
      auth = { logout = marker(capabilities.auth or result.auth) },
    },
    agentInfo = copy(result.info or {}),
    authMethods = copy(result.authMethods or {}),
  }
end

local function chunk_params(params, variant, content)
  local result = copy(params)
  result.update = {
    sessionUpdate = variant .. "_chunk",
    content = copy(content),
  }
  return result
end

function Adapter:updates(params)
  if not self.enabled or type(params) ~= "table" or type(params.update) ~= "table" then
    return { params }
  end
  local update = params.update
  local variant = update.sessionUpdate

  if variant == "user_message" or variant == "agent_message" or variant == "agent_thought" then
    local content = type(update.content) == "table" and update.content or {}
    local message_id = tostring(update.messageId or update.id or variant)
    local loss = self.message_seen[message_id]
      and "v2 whole-message replacement cannot remove previously rendered v1 chunks"
      or nil
    self.message_seen[message_id] = true
    local results = {}
    for _, item in ipairs(content) do
      results[#results + 1] = chunk_params(params, variant, item)
    end
    if #results == 0 then
      return {}, "v2 empty whole-message replacement has no lossless v1 representation"
    end
    return results, loss
  end

  if variant == "tool_call_update" then
    local tool_id = update.toolCallId
    if tool_id and type(update.content) == "table" then
      self.tool_content[tool_id] = copy(update.content)
    end
    return { params }
  end

  if variant == "tool_call_content_chunk" then
    local tool_id = update.toolCallId
    if not tool_id then return {}, "v2 tool content chunk is missing toolCallId" end
    local content = self.tool_content[tool_id] or {}
    content[#content + 1] = copy(update.content)
    self.tool_content[tool_id] = content
    local result = copy(params)
    result.update = {
      sessionUpdate = "tool_call_update",
      toolCallId = tool_id,
      content = copy(content),
    }
    return { result }
  end

  return { params }
end

function Adapter:permission_params(params, request_id)
  if not self.enabled or type(params) ~= "table" then return params end
  local result = copy(params)
  local subject = result.subject
  if type(subject) == "table" and subject.type == "tool_call" and type(subject.toolCall) == "table" then
    result.toolCall = copy(subject.toolCall)
  elseif type(subject) == "table" and subject.type == "command" then
    result.toolCall = {
      toolCallId = subject.commandId or ("permission-" .. tostring(request_id)),
      title = result.title or "Run command",
      kind = "execute",
      rawInput = { command = subject.command, cwd = subject.cwd },
    }
  end
  if type(result.toolCall) ~= "table" then
    result.toolCall = {
      toolCallId = "permission-" .. tostring(request_id),
      title = result.title or "Permission request",
      kind = "other",
    }
  elseif not result.toolCall.title and result.title then
    result.toolCall.title = result.title
  end
  result.subject = nil
  return result
end

return M
