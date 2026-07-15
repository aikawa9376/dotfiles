local uv = vim.uv or vim.loop

local Client = {}
Client.__index = Client
local mcp_servers = require("lazyagent.acp.mcp_servers")
local ProtocolLog = require("lazyagent.acp.protocol_log")

local PROTOCOL_VERSION = 1
local ERR = {
  parse = -32700,
  invalid_request = -32600,
  method_not_found = -32601,
  invalid_params = -32602,
  internal = -32603,
  transport = -32000,
}
local STDERR_MAX_LINES = 200
local PROTOCOL_EVENT_MAX = 200
local KNOWN_SESSION_UPDATES = {
  agent_message_chunk = true,
  agent_thought_chunk = true,
  available_commands_update = true,
  config_option_update = true,
  current_mode_update = true,
  current_model_update = true,
  plan = true,
  session_info_update = true,
  tool_call = true,
  tool_call_update = true,
  usage_update = true,
  user_message_chunk = true,
}
local SESSION_SCOPED_SERVER_METHODS = {
  ["session/request_permission"] = true,
  ["fs/read_text_file"] = true,
  ["fs/write_text_file"] = true,
  ["terminal/create"] = true,
  ["terminal/output"] = true,
  ["terminal/wait_for_exit"] = true,
  ["terminal/kill"] = true,
  ["terminal/release"] = true,
}

local function normalize_command_spec(spec)
  if type(spec) == "string" then
    return spec, {}
  end
  if type(spec) == "table" and #spec > 0 then
    local parts = vim.deepcopy(spec)
    local command = table.remove(parts, 1)
    return command, parts
  end
  return nil, {}
end

local function build_env(env)
  local merged = {}
  for key, value in pairs(vim.fn.environ()) do
    merged[key] = value
  end
  merged.NODE_NO_WARNINGS = merged.NODE_NO_WARNINGS or "1"
  merged.IS_AI_TERMINAL = merged.IS_AI_TERMINAL or "1"
  for key, value in pairs(env or {}) do
    merged[key] = value
  end

  local out = {}
  for key, value in pairs(merged) do
    if value ~= nil then
      table.insert(out, key .. "=" .. tostring(value))
    end
  end
  return out
end

local function safe_close(handle)
  if handle and not handle:is_closing() then
    pcall(function() handle:close() end)
  end
end

local function encode_json(data)
  return vim.json.encode(data)
end

local function decode_json(data)
  return vim.json.decode(data)
end

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function append_stderr_line(lines, message)
  lines[#lines + 1] = message
  local overflow = #lines - STDERR_MAX_LINES
  if overflow > 0 then
    for _ = 1, overflow do
      table.remove(lines, 1)
    end
  end
end

local function append_stdout_chunk(client, chunk)
  if not chunk or chunk == "" then
    return
  end
  local chunks = client.stdout_buffer_chunks
  if type(chunks) ~= "table" then
    chunks = {}
    client.stdout_buffer_chunks = chunks
  end
  chunks[#chunks + 1] = chunk
  client.stdout_buffer_size = (tonumber(client.stdout_buffer_size) or 0) + #chunk
end

local function take_stdout_line(client)
  local chunks = client.stdout_buffer_chunks
  local line = ""
  if type(chunks) == "table" and #chunks > 0 then
    line = #chunks == 1 and chunks[1] or table.concat(chunks)
  end
  client.stdout_buffer_chunks = {}
  client.stdout_buffer_size = 0
  client.stdout_buffer = ""
  return trim(line)
end

local function handle_stdout_data(client, data)
  if not data or data == "" then
    return
  end

  local start = 1
  while true do
    local idx = data:find("\n", start, true)
    if not idx then
      break
    end
    append_stdout_chunk(client, data:sub(start, idx - 1))
    local line = take_stdout_line(client)
    if line ~= "" then
      client:_handle_message(line)
    end
    start = idx + 1
  end

  if start <= #data then
    append_stdout_chunk(client, data:sub(start))
  end
end

local function empty_dict_if_needed(value)
  if type(value) == "table" and vim.tbl_isempty(value) then
    return vim.empty_dict()
  end
  return value
end

local function default_client_info()
  return {
    name = "lazyagent",
    title = "lazyagent.nvim",
    version = "0.1.0",
  }
end

local function default_client_capabilities(handlers)
  local fs_caps = {
    readTextFile = handlers and handlers.read_text_file ~= nil or false,
    writeTextFile = handlers and handlers.write_text_file ~= nil or false,
  }
  return {
    fs = fs_caps,
    terminal = handlers and handlers.create_terminal ~= nil or false,
    session = {
      configOptions = {
        boolean = vim.empty_dict(),
      },
    },
  }
end

local function update_config_option_current_value(config_options, matches, value)
  if type(config_options) ~= "table" then
    return false
  end

  local function normalize_config_key(candidate)
    return tostring(candidate or ""):lower():gsub("[^%w]+", "")
  end

  matches = type(matches) == "table" and matches or { matches }
  for _, option in ipairs(config_options) do
    local id = normalize_config_key(option.id)
    local category = normalize_config_key(option.category)
    for _, candidate in ipairs(matches) do
      local expected = normalize_config_key(candidate)
      if expected ~= "" and (id == expected or category == expected) then
        option.currentValue = value
        return true
      end
    end
  end

  return false
end

function Client.new(opts)
  opts = opts or {}
  local command, args = normalize_command_spec(opts.command)
  return setmetatable({
    command = command,
    args = args,
    cwd = opts.cwd or vim.fn.getcwd(),
    env = opts.env or {},
    mcp_url = opts.mcp_url,
    mcp_name = opts.mcp_name or "lazyagent",
    mcp_headers = opts.mcp_headers or {},
    mcp_servers = opts.mcp_servers or {},
    additional_directories = vim.deepcopy(opts.additional_directories or {}),
    client_info = opts.client_info or default_client_info(),
    client_capabilities = opts.client_capabilities or default_client_capabilities(opts.handlers),
    handlers = opts.handlers or {},
    callbacks = {},
    callback_timers = {},
    pending_permission_requests = {},
    next_id = 0,
    request_timeout_ms = math.max(0, tonumber(opts.request_timeout_ms) or 60000),
    prompt_timeout_ms = math.max(0, tonumber(opts.prompt_timeout_ms) or 0),
    cancel_settle_ms = math.max(0, tonumber(opts.cancel_settle_ms) or 50),
    prompt_state = "idle",
    prompt_request_id = nil,
    prompt_generation = 0,
    state = "created",
    stdout_buffer = "",
    stdout_buffer_chunks = {},
    stdout_buffer_size = 0,
    stderr_lines = {},
    protocol_events = {},
    protocol_log = opts.protocol_log_path and ProtocolLog.new(opts.protocol_log_path) or nil,
    session_id = nil,
    pending_session_id = nil,
    agent_capabilities = nil,
    agent_info = nil,
    auth_methods = {},
    config_options = nil,
    _legacy_api = false,
    process = nil,
    stdin = nil,
    stdout = nil,
    stderr = nil,
    pid = nil,
    stop_timer = nil,
    on_update = opts.on_update or function() end,
    on_ready = opts.on_ready or function() end,
    on_error = opts.on_error or function() end,
    on_protocol_event = opts.on_protocol_event or function() end,
    on_exit = opts.on_exit or function() end,
  }, Client)
end

function Client:_record_protocol_event(kind, data)
  local event = vim.tbl_extend("force", {
    kind = tostring(kind or "unknown"),
    timestamp = os.time(),
  }, type(data) == "table" and vim.deepcopy(data) or {})
  self.protocol_events[#self.protocol_events + 1] = event
  while #self.protocol_events > PROTOCOL_EVENT_MAX do
    table.remove(self.protocol_events, 1)
  end
  vim.schedule(function()
    pcall(self.on_protocol_event, vim.deepcopy(event))
  end)
end

function Client:get_protocol_events()
  return vim.deepcopy(self.protocol_events or {})
end

function Client:_clear_stop_timer()
  local timer = self.stop_timer
  self.stop_timer = nil
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

function Client:debug_snapshot()
  return {
    state = self.state,
    pid = self.pid,
    process = self.process ~= nil,
    stdin = self.stdin ~= nil,
    stdout = self.stdout ~= nil,
    stderr = self.stderr ~= nil,
    callbacks = vim.tbl_count(self.callbacks or {}),
    callback_timers = vim.tbl_count(self.callback_timers or {}),
    stop_timer = self.stop_timer ~= nil and 1 or 0,
    pending_permissions = vim.tbl_count(self.pending_permission_requests or {}),
    stdout_buffer_bytes = tonumber(self.stdout_buffer_size) or 0,
    prompt_state = self.prompt_state,
  }
end

function Client:_convert_legacy_session_fields(result)
  if result.configOptions then
    self.config_options = vim.deepcopy(result.configOptions)
    self._legacy_api = false
    return
  end

  local config_options = {}

  if result.modes and result.modes.availableModes then
    local options = {}
    for _, mode in ipairs(result.modes.availableModes) do
      table.insert(options, {
        value = mode.id,
        name = mode.name or mode.id,
        description = mode.description,
      })
    end
    if #options > 0 then
      table.insert(config_options, {
        id = "mode",
        name = "Mode",
        category = "mode",
        type = "select",
        currentValue = result.modes.currentModeId or "",
        options = options,
      })
    end
  end

  if result.models and result.models.availableModels then
    local options = {}
    for _, model in ipairs(result.models.availableModels) do
      table.insert(options, {
        value = model.modelId,
        name = model.name or model.modelId,
        description = model.description,
      })
    end
    if #options > 0 then
      table.insert(config_options, {
        id = "model",
        name = "Model",
        category = "model",
        type = "select",
        currentValue = result.models.currentModelId or "",
        options = options,
      })
    end
  end

  if #config_options > 0 then
    self.config_options = config_options
    self._legacy_api = true
    result.configOptions = vim.deepcopy(config_options)
  else
    self.config_options = nil
    self._legacy_api = false
  end
end

function Client:_set_state(next_state)
  self.state = next_state
end

function Client:_next_id()
  self.next_id = self.next_id + 1
  return self.next_id
end

function Client:_clear_request_timer(id)
  local timer = self.callback_timers[id]
  self.callback_timers[id] = nil
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

function Client:_reject_pending(reason)
  local callbacks = self.callbacks
  self.callbacks = {}
  for id, callback in pairs(callbacks) do
    self:_clear_request_timer(id)
    vim.schedule(function()
      pcall(callback, nil, {
        code = ERR.transport,
        message = reason or "ACP transport stopped",
      })
    end)
  end
  self.pending_permission_requests = {}
end

function Client:_finish_permission_request(id, pending, outcome, err)
  if self.pending_permission_requests[id] ~= pending then
    return false
  end
  self.pending_permission_requests[id] = nil
  if err then
    self:_send_error(id, err.code or ERR.internal, err.message or tostring(err), err.data)
  else
    self:_send_result(id, {
      outcome = outcome or { outcome = "cancelled" },
    })
  end
  return true
end

function Client:_cancel_pending_permissions(session_id)
  local cancelled = 0
  local pending_ids = {}
  for id, pending in pairs(self.pending_permission_requests) do
    if not session_id or not pending.session_id or pending.session_id == session_id then
      pending_ids[#pending_ids + 1] = id
    end
  end
  for _, id in ipairs(pending_ids) do
    local pending = self.pending_permission_requests[id]
    if pending and self:_finish_permission_request(id, pending, { outcome = "cancelled" }) then
      cancelled = cancelled + 1
    end
  end
  return cancelled
end

function Client:_send_raw(payload)
  if not self.stdin or self.stdin:is_closing() then
    return false
  end
  if self.protocol_log then
    local ok, message = pcall(decode_json, payload)
    if ok then self.protocol_log:record("out", message) end
  end
  self.stdin:write(payload .. "\n")
  return true
end

function Client:_send_result(id, result)
  return self:_send_raw(encode_json({
    jsonrpc = "2.0",
    id = id,
    result = result == nil and vim.NIL or result,
  }))
end

function Client:_send_error(id, code, message, data)
  return self:_send_raw(encode_json({
    jsonrpc = "2.0",
    id = id,
    error = {
      code = code or ERR.internal,
      message = message or "Internal error",
      data = data,
    },
  }))
end

function Client:_send_request(method, params, callback)
  local id = self:_next_id()
  self.callbacks[id] = callback or function() end
  local ok = self:_send_raw(encode_json({
    jsonrpc = "2.0",
    id = id,
    method = method,
    params = params or vim.empty_dict(),
  }))
  if not ok then
    local cb = self.callbacks[id]
    self.callbacks[id] = nil
    self:_clear_request_timer(id)
    if cb then
      vim.schedule(function()
        pcall(cb, nil, {
          code = ERR.transport,
          message = "ACP transport not available",
        })
      end)
    end
    return id
  end

  local timeout_ms = method == "session/prompt" and self.prompt_timeout_ms or self.request_timeout_ms
  if timeout_ms > 0 then
    local timer = uv.new_timer()
    self.callback_timers[id] = timer
    timer:start(timeout_ms, 0, function()
      local cb = self.callbacks[id]
      if not cb then
        self:_clear_request_timer(id)
        return
      end
      self.callbacks[id] = nil
      self:_clear_request_timer(id)
      self:_send_notification("$/cancel_request", { requestId = id })
      vim.schedule(function()
        pcall(cb, nil, {
          code = ERR.transport,
          message = string.format("ACP request timed out after %dms: %s", timeout_ms, method),
        })
      end)
    end)
  end
  return id
end

function Client:_send_notification(method, params)
  return self:_send_raw(encode_json({
    jsonrpc = "2.0",
    method = method,
    params = params or vim.empty_dict(),
  }))
end

function Client:_build_mcp_servers()
  local caps = self.agent_capabilities and self.agent_capabilities.mcpCapabilities or {}
  local servers = mcp_servers.for_capabilities(mcp_servers.normalize(self.mcp_servers), caps)
  if self.mcp_url and self.mcp_url ~= "" and caps.http == true then
    table.insert(servers, {
      type = "http",
      name = self.mcp_name,
      url = self.mcp_url,
      headers = mcp_servers.normalize({ {
        type = "http", name = self.mcp_name, url = self.mcp_url, headers = self.mcp_headers,
      } })[1].headers,
    })
  end
  return servers
end

function Client:_attach_session(session_id, session_result)
  session_result = type(session_result) == "table" and session_result or {}
  self:_convert_legacy_session_fields(session_result)
  self.session_id = session_id
  self.pending_session_id = nil
  self:_set_state("ready")
  return session_result
end

function Client:_supports_session_capability(name)
  local session_caps = self.agent_capabilities and self.agent_capabilities.sessionCapabilities or {}
  if type(session_caps) ~= "table" then
    return false
  end
  local capability = session_caps[name]
  return capability ~= nil and capability ~= false and capability ~= vim.NIL
end

function Client:supports_session_list()
  return self:_supports_session_capability("list")
end

function Client:supports_session_resume()
  return self:_supports_session_capability("resume")
end

function Client:supports_session_close()
  return self:_supports_session_capability("close")
end

function Client:supports_session_delete()
  return self:_supports_session_capability("delete")
end

function Client:supports_additional_directories()
  return self:_supports_session_capability("additionalDirectories")
end

function Client:supports_session_load()
  return self.agent_capabilities and self.agent_capabilities.loadSession == true
end

function Client:supports_logout()
  local auth = self.agent_capabilities and self.agent_capabilities.auth or nil
  if type(auth) ~= "table" then
    return false
  end
  local capability = auth.logout
  return capability ~= nil and capability ~= false and capability ~= vim.NIL
end

function Client:_build_session_params(session_id)
  local params = {
    cwd = self.cwd,
    mcpServers = self:_build_mcp_servers(),
  }
  if session_id ~= nil then
    params.sessionId = session_id
  end
  if self:supports_additional_directories() and type(self.additional_directories) == "table" then
    local directories = {}
    for _, path in ipairs(self.additional_directories) do
      if type(path) == "string" and path ~= "" then
        directories[#directories + 1] = path
      end
    end
    if #directories > 0 then
      params.additionalDirectories = directories
    end
  end
  return params
end

function Client:is_connected()
  return self.process ~= nil and self.state ~= "stopped"
end

function Client:_ensure_connected(callback)
  callback = callback or function() end
  if self:is_connected() then
    return true
  end
  callback(nil, {
    code = ERR.invalid_request,
    message = "ACP client is not connected",
  })
  return false
end

function Client:authenticate(method_id, callback)
  callback = callback or function() end
  if not self:_ensure_connected(callback) then
    return
  end
  local advertised = false
  for _, method in ipairs(self.auth_methods or {}) do
    if type(method) == "table" and tostring(method.id or "") == tostring(method_id or "") then
      advertised = true
      break
    end
  end
  if not advertised then
    callback(nil, {
      code = ERR.invalid_params,
      message = "ACP authentication method was not advertised: " .. tostring(method_id),
    })
    return
  end
  self:_send_request("authenticate", { methodId = method_id }, callback)
end

function Client:logout(callback)
  callback = callback or function() end
  if not self:_ensure_connected(callback) then
    return
  end
  if not self:supports_logout() then
    callback(nil, {
      code = ERR.invalid_request,
      message = "ACP agent does not support logout",
    })
    return
  end
  self:_send_request("logout", vim.empty_dict(), callback)
end

function Client:_authenticate_for_session(callback)
  local methods = vim.deepcopy(self.auth_methods or {})
  local picker = self.handlers and self.handlers.select_auth_method or nil
  if #methods == 0 or type(picker) ~= "function" then
    callback(nil, {
      code = ERR.transport,
      message = "ACP authentication is required but no supported authentication method is available",
    })
    return
  end

  local finished = false
  local function selected(method_id, select_err)
    if finished then
      return
    end
    finished = true
    if select_err or not method_id then
      callback(nil, select_err or {
        code = ERR.transport,
        message = "ACP authentication was cancelled",
      })
      return
    end
    self:authenticate(method_id, callback)
  end
  local ok, err = pcall(picker, methods, selected)
  if not ok then
    selected(nil, { code = ERR.internal, message = tostring(err) })
  end
end

function Client:request_authentication(callback)
  self:_authenticate_for_session(callback or function() end)
end

function Client:new_session(callback)
  callback = callback or function() end
  if not self:_ensure_connected(callback) then
    return
  end

  local session_params = self:_build_session_params()

  self:_send_request("session/new", session_params, function(session_result, session_err)
    if session_err then
      callback(nil, session_err)
      return
    end
    if not session_result or type(session_result) ~= "table" or not session_result.sessionId then
      callback(nil, {
        code = ERR.invalid_request,
        message = "ACP session/new did not return a sessionId",
      })
      return
    end

    callback(self:_attach_session(session_result.sessionId, session_result), nil)
  end)
end

function Client:list_sessions(params, callback)
  callback = callback or function() end
  if not self:_ensure_connected(callback) then
    return
  end
  if not self:supports_session_list() then
    callback(nil, {
      code = ERR.invalid_request,
      message = "ACP agent does not support session/list",
    })
    return
  end

  self:_send_request("session/list", params or vim.empty_dict(), callback)
end

function Client:load_session(session_id, callback)
  callback = callback or function() end
  if not self:_ensure_connected(callback) then
    return
  end
  if not self:supports_session_load() then
    callback(nil, {
      code = ERR.invalid_request,
      message = "ACP agent does not support session/load",
    })
    return
  end

  self.pending_session_id = session_id
  self:_send_request("session/load", self:_build_session_params(session_id), function(result, err)
    if err then
      self.pending_session_id = nil
      callback(nil, err)
      return
    end
    callback(self:_attach_session(session_id, result), nil)
  end)
end

function Client:resume_session(session_id, callback)
  callback = callback or function() end
  if not self:_ensure_connected(callback) then
    return
  end
  if not self:supports_session_resume() then
    callback(nil, {
      code = ERR.invalid_request,
      message = "ACP agent does not support session/resume",
    })
    return
  end

  self.pending_session_id = session_id
  self:_send_request("session/resume", self:_build_session_params(session_id), function(result, err)
    if err then
      self.pending_session_id = nil
      callback(nil, err)
      return
    end
    callback(self:_attach_session(session_id, result), nil)
  end)
end

function Client:close_session(session_id, callback)
  callback = callback or function() end
  if not self:_ensure_connected(callback) then
    return
  end
  if not self:supports_session_close() then
    callback(nil, {
      code = ERR.invalid_request,
      message = "ACP agent does not support session/close",
    })
    return
  end

  local target_session_id = session_id or self.session_id
  if not target_session_id or target_session_id == "" then
    callback(nil, {
      code = ERR.invalid_request,
      message = "ACP session is not ready",
    })
    return
  end

  self:_send_request("session/close", {
    sessionId = target_session_id,
  }, function(result, err)
    if not err and self.session_id == target_session_id then
      self.session_id = nil
      self:_set_state("initialized")
    end
    callback(result, err)
  end)
end

function Client:delete_session(session_id, callback)
  callback = callback or function() end
  if not self:_ensure_connected(callback) then
    return
  end
  if not self:supports_session_delete() then
    callback(nil, {
      code = ERR.invalid_request,
      message = "ACP agent does not support session/delete",
    })
    return
  end
  if not session_id or session_id == "" then
    callback(nil, {
      code = ERR.invalid_params,
      message = "session/delete requires a sessionId",
    })
    return
  end

  self:_send_request("session/delete", {
    sessionId = session_id,
  }, callback)
end

function Client:_handle_initialize_response(result, callback)
  if not result or type(result) ~= "table" then
    callback(nil, {
      code = ERR.invalid_request,
      message = "ACP initialize returned an invalid response",
    })
    return
  end
  if result.protocolVersion ~= PROTOCOL_VERSION then
    callback(nil, {
      code = ERR.invalid_request,
      message = string.format(
        "ACP protocol version mismatch: client=%d agent=%s",
        PROTOCOL_VERSION,
        tostring(result.protocolVersion)
      ),
    })
    return
  end

  self.agent_capabilities = result.agentCapabilities or {}
  self.agent_info = result.agentInfo or {}
  self.auth_methods = result.authMethods or {}
  self:_set_state("initialized")
  callback(self, nil)
end

function Client:_handle_update(params)
  if not params or type(params) ~= "table" then return end
  local expected_session = self.session_id or self.pending_session_id
  if expected_session and params.sessionId ~= expected_session then
    self:_record_protocol_event("session_scope_mismatch", {
      method = "session/update",
      expected_session_id = expected_session,
      received_session_id = params.sessionId,
    })
    return
  end
  local update = params.update
  if type(update) == "table" then
    local variant = update.sessionUpdate
    if type(variant) ~= "string" or not KNOWN_SESSION_UPDATES[variant] then
      self:_record_protocol_event("unknown_update", {
        method = "session/update",
        session_id = params.sessionId,
        variant = variant,
      })
    end
    if update.sessionUpdate == "config_option_update" and update.configOptions then
      self.config_options = vim.deepcopy(update.configOptions)
      self._legacy_api = false
    elseif update.sessionUpdate == "current_mode_update" then
      update_config_option_current_value(self.config_options, { "mode" }, update.modeId or update.currentModeId or update.currentMode)
    elseif update.sessionUpdate == "current_model_update" then
      update_config_option_current_value(self.config_options, { "model" }, update.modelId or update.currentModelId or update.currentModel)
    end
  end
  vim.schedule(function()
    pcall(self.on_update, params)
  end)
end

function Client:_dispatch_sync(id, fn)
  local ok, result, err = pcall(fn)
  if not ok then
    self:_send_error(id, ERR.internal, tostring(result))
    return
  end
  if err then
    self:_send_error(id, err.code or ERR.internal, err.message or tostring(err), err.data)
    return
  end
  self:_send_result(id, result)
end

function Client:_dispatch_async(id, fn)
  local ok, err = pcall(fn, function(result, callback_err)
    if callback_err then
      self:_send_error(id, callback_err.code or ERR.internal, callback_err.message or tostring(callback_err), callback_err.data)
      return
    end
    self:_send_result(id, result)
  end)
  if not ok then
    self:_send_error(id, ERR.internal, tostring(err))
  end
end

function Client:_handle_server_request(id, method, params)
  local handlers = self.handlers or {}
  local expected_session = self.session_id or self.pending_session_id
  if SESSION_SCOPED_SERVER_METHODS[method]
    and expected_session
    and (not params or params.sessionId ~= expected_session)
  then
    self:_record_protocol_event("session_scope_mismatch", {
      id = id,
      method = method,
      expected_session_id = expected_session,
      received_session_id = params and params.sessionId or nil,
    })
    self:_send_error(id, ERR.invalid_params, "ACP request sessionId does not match the active session")
    return
  end

  if method == "session/request_permission" then
    if not handlers.request_permission then
      self:_send_result(id, { outcome = { outcome = "cancelled" } })
      return
    end
    local pending = {
      session_id = params and params.sessionId or nil,
    }
    self.pending_permission_requests[id] = pending
    vim.schedule(function()
      if self.pending_permission_requests[id] ~= pending then return end
      local ok, err = pcall(handlers.request_permission, params or {}, function(outcome, callback_err)
        self:_finish_permission_request(id, pending, outcome, callback_err)
      end)
      if not ok then
        self:_record_protocol_event("handler_error", { id = id, method = method, message = tostring(err) })
        self:_finish_permission_request(id, pending, nil, {
          code = ERR.internal,
          message = tostring(err),
        })
      end
    end)
    return
  end

  if method == "fs/read_text_file" then
    if not handlers.read_text_file then
      self:_send_error(id, ERR.method_not_found, "fs/read_text_file is not supported")
      return
    end
    self:_dispatch_sync(id, function()
      return handlers.read_text_file(params or {})
    end)
    return
  end

  if method == "fs/write_text_file" then
    if not handlers.write_text_file then
      self:_send_error(id, ERR.method_not_found, "fs/write_text_file is not supported")
      return
    end
    self:_dispatch_sync(id, function()
      return handlers.write_text_file(params or {})
    end)
    return
  end

  if method == "terminal/create" then
    if not handlers.create_terminal then
      self:_send_error(id, ERR.method_not_found, "terminal/create is not supported")
      return
    end
    self:_dispatch_async(id, function(done)
      handlers.create_terminal(params or {}, done)
    end)
    return
  end

  if method == "terminal/output" then
    if not handlers.terminal_output then
      self:_send_error(id, ERR.method_not_found, "terminal/output is not supported")
      return
    end
    self:_dispatch_sync(id, function()
      return handlers.terminal_output(params or {})
    end)
    return
  end

  if method == "terminal/wait_for_exit" then
    if not handlers.terminal_wait_for_exit then
      self:_send_error(id, ERR.method_not_found, "terminal/wait_for_exit is not supported")
      return
    end
    self:_dispatch_async(id, function(done)
      handlers.terminal_wait_for_exit(params or {}, done)
    end)
    return
  end

  if method == "terminal/kill" then
    if not handlers.terminal_kill then
      self:_send_error(id, ERR.method_not_found, "terminal/kill is not supported")
      return
    end
    self:_dispatch_sync(id, function()
      return handlers.terminal_kill(params or {})
    end)
    return
  end

  if method == "terminal/release" then
    if not handlers.terminal_release then
      self:_send_error(id, ERR.method_not_found, "terminal/release is not supported")
      return
    end
    self:_dispatch_sync(id, function()
      return handlers.terminal_release(params or {})
    end)
    return
  end

  self:_send_error(id, ERR.method_not_found, "Unknown ACP request: " .. tostring(method))
  self:_record_protocol_event("unknown_method", {
    id = id,
    method = tostring(method),
    request = true,
  })
end

function Client:_handle_message(line)
  local ok, message = pcall(decode_json, line)
  if not ok or type(message) ~= "table" then
    self:_record_protocol_event("parse_error", {
      data = tostring(line):sub(1, 4096),
      truncated = #tostring(line) > 4096,
    })
    vim.schedule(function()
      pcall(self.on_error, {
        code = ERR.parse,
        message = "Failed to decode ACP message",
        data = line,
      })
    end)
    return
  end

  if self.protocol_log then self.protocol_log:record("in", message) end

  if message.method then
    if message.id ~= nil then
      self:_handle_server_request(message.id, message.method, message.params or {})
    elseif message.method == "session/update" then
      self:_handle_update(message.params or {})
    else
      self:_record_protocol_event("unknown_method", {
        method = tostring(message.method),
        request = false,
      })
    end
    return
  end

  if message.id == nil then
    return
  end

  local callback = self.callbacks[message.id]
  if not callback then
    self:_record_protocol_event("orphan_response", {
      id = message.id,
      error = message.error ~= nil,
    })
    return
  end
  self.callbacks[message.id] = nil
  self:_clear_request_timer(message.id)
  vim.schedule(function()
    pcall(callback, message.result, message.error)
  end)
end

function Client:start(callback, opts)
  opts = opts or {}
  if not self.command or self.command == "" then
    callback(nil, {
      code = ERR.invalid_params,
      message = "ACP command is not configured",
    })
    return
  end

  local stdin = uv.new_pipe(false)
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)

  local spawn_opts = {
    args = self.args,
    cwd = self.cwd,
    env = build_env(self.env),
    stdio = { stdin, stdout, stderr },
    detached = false,
    uid = type(uv.getuid) == "function" and uv.getuid() or nil,
    gid = type(uv.getgid) == "function" and uv.getgid() or nil,
    hide = false,
    verbatim = false,
  }
  local handle
  local pid
  handle, pid = uv.spawn(self.command, spawn_opts, function(code, signal)
    self:_clear_stop_timer()
    safe_close(stdin)
    safe_close(stdout)
    safe_close(stderr)
    safe_close(handle)
    self.stdin = nil
    self.stdout = nil
    self.stderr = nil
    self.process = nil
    self.pid = nil
    self.session_id = nil
    self.pending_session_id = nil
    self.prompt_state = "idle"
    self.prompt_request_id = nil
    self.stdout_buffer = ""
    self.stdout_buffer_chunks = {}
    self.stdout_buffer_size = 0
    self:_set_state("stopped")
    self:_reject_pending("ACP process exited")
    vim.schedule(function()
      pcall(self.on_exit, code, signal, table.concat(self.stderr_lines, "\n"))
    end)
  end)

  if not handle then
    safe_close(stdin)
    safe_close(stdout)
    safe_close(stderr)
    callback(nil, {
      code = ERR.transport,
      message = "Failed to spawn ACP process: " .. tostring(self.command),
    })
    return
  end

  self.stdin = stdin
  self.stdout = stdout
  self.stderr = stderr
  self.process = handle
  self.pid = pid
  self:_set_state("connecting")

  stdout:read_start(function(err, data)
    if err then
      vim.schedule(function()
        pcall(self.on_error, {
          code = ERR.transport,
          message = "ACP stdout error: " .. tostring(err),
        })
      end)
      return
    end
    if not data then return end

    handle_stdout_data(self, data)
  end)

  stderr:read_start(function(err, data)
    if err then return end
    if not data or data == "" then return end
    local message = trim(data)
    if message ~= "" then
      append_stderr_line(self.stderr_lines, message)
    end
  end)

  local advertised_capabilities = {
    fs = empty_dict_if_needed(self.client_capabilities.fs or {}),
    terminal = self.client_capabilities.terminal == true,
  }
  if self.client_capabilities.session ~= nil then
    advertised_capabilities.session = vim.deepcopy(self.client_capabilities.session)
  end

  local params = {
    protocolVersion = PROTOCOL_VERSION,
    clientCapabilities = advertised_capabilities,
    clientInfo = self.client_info,
  }

  self:_send_request("initialize", params, function(result, err)
    if err then
      self:stop()
      callback(nil, err)
      return
    end
    self:_handle_initialize_response(result, function(client, init_err)
      if init_err then
        self:stop()
        callback(nil, init_err)
        return
      end
      if opts.create_session == false then
        vim.schedule(function()
          pcall(self.on_ready, {})
        end)
        callback(client, nil, {})
        return
      end

      local mode = opts.session_mode or "new"
      local resume_strategy = "new"
      if mode == "auto" then
        if opts.session_id and opts.session_id ~= "" and self:supports_session_resume() then
          mode = "resume"
          resume_strategy = "native_resume"
        elseif opts.session_id and opts.session_id ~= "" and self:supports_session_load() then
          mode = "load"
          resume_strategy = "native_load"
        else
          mode = "new"
          resume_strategy = "local_carryover"
        end
      elseif mode == "resume" then
        resume_strategy = "native_resume"
      elseif mode == "load" then
        resume_strategy = "native_load"
      end
      local attempted_auth = false
      local start_session
      local done = function(session_result, session_err)
        if session_err and tonumber(session_err.code) == -32000 and not attempted_auth then
          attempted_auth = true
          self:_authenticate_for_session(function(_, auth_err)
            if auth_err then
              self:stop()
              callback(nil, auth_err)
              return
            end
            start_session()
          end)
          return
        end
        if session_err then
          self:stop()
          callback(nil, session_err)
          return
        end
        session_result = type(session_result) == "table" and session_result or {}
        session_result._meta = type(session_result._meta) == "table" and session_result._meta or {}
        session_result._meta.lazyagentResumeStrategy = resume_strategy
        vim.schedule(function()
          pcall(self.on_ready, session_result or {})
        end)
        callback(client, nil, session_result or {})
      end

      start_session = function()
        if mode == "load" then
          self:load_session(opts.session_id, done)
        elseif mode == "resume" then
          self:resume_session(opts.session_id, done)
        else
          self:new_session(done)
        end
      end
      start_session()
    end)
  end)
end

function Client:send_prompt(prompt, callback)
  callback = callback or function() end
  if not self.session_id then
    callback(nil, {
      code = ERR.invalid_request,
      message = "ACP session is not ready",
    })
    return
  end
  if self.prompt_state ~= "idle" then
    callback(nil, {
      code = ERR.invalid_request,
      message = "ACP prompt is already active",
    })
    return
  end

  self.prompt_generation = self.prompt_generation + 1
  self.prompt_state = "active"
  local request_id
  request_id = self:_send_request("session/prompt", {
    sessionId = self.session_id,
    prompt = prompt,
  }, function(result, err)
    local was_cancelling = self.prompt_state == "cancelling"
    self.prompt_request_id = nil
    if err and tonumber(err.code) == -32800 then
      result = { stopReason = "cancelled" }
      err = nil
    end

    local cancelled = was_cancelling or (result and result.stopReason == "cancelled")
    local finish = function()
      self.prompt_state = "idle"
      callback(result, err)
    end
    if cancelled and self.cancel_settle_ms > 0 then
      self.prompt_state = "settling"
      vim.defer_fn(finish, self.cancel_settle_ms)
    else
      finish()
    end
  end)
  self.prompt_request_id = request_id
end

function Client:set_config_option(config_id, value, callback)
  callback = callback or function() end
  if not self.session_id then
    callback(nil, {
      code = ERR.invalid_request,
      message = "ACP session is not ready",
    })
    return
  end

  self:_send_request("session/set_config_option", {
    sessionId = self.session_id,
    configId = config_id,
    value = value,
  }, function(result, err)
    if err then
      callback(nil, err, result)
      return
    end
    if result and result.configOptions then
      self.config_options = vim.deepcopy(result.configOptions)
      self._legacy_api = false
    else
      update_config_option_current_value(self.config_options, { config_id }, value)
    end
    callback(self.config_options, nil, result)
  end)
end

function Client:set_mode(mode_id, callback)
  callback = callback or function() end
  if not self.session_id then
    callback(nil, {
      code = ERR.invalid_request,
      message = "ACP session is not ready",
    })
    return
  end

  self:_send_request("session/set_mode", {
    sessionId = self.session_id,
    modeId = mode_id,
  }, function(result, err)
    if err then
      callback(nil, err, result)
      return
    end
    update_config_option_current_value(self.config_options, { "mode" }, mode_id)
    callback(self.config_options, nil, result)
  end)
end

function Client:set_model(model_id, callback)
  callback = callback or function() end
  if not self.session_id then
    callback(nil, {
      code = ERR.invalid_request,
      message = "ACP session is not ready",
    })
    return
  end

  self:_send_request("session/set_model", {
    sessionId = self.session_id,
    modelId = model_id,
  }, function(result, err)
    if err then
      callback(nil, err, result)
      return
    end
    update_config_option_current_value(self.config_options, { "model" }, model_id)
    callback(self.config_options, nil, result)
  end)
end

function Client:cancel()
  if not self.session_id then return false end
  if self.prompt_state == "active" then
    self.prompt_state = "cancelling"
  end
  self:_cancel_pending_permissions(self.session_id)
  return self:_send_notification("session/cancel", {
    sessionId = self.session_id,
  })
end

function Client:is_ready()
  return self.state == "ready" and self.session_id ~= nil
end

function Client:stop()
  self:_cancel_pending_permissions(self.session_id)
  if self.process and not self.process:is_closing() then
    pcall(function() self.process:kill(15) end)
    self:_clear_stop_timer()
    self.stop_timer = vim.defer_fn(function()
      self.stop_timer = nil
      if self.process and not self.process:is_closing() then
        pcall(function() self.process:kill(9) end)
      end
    end, 100)
  end
end

return Client
