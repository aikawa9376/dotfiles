local uv = vim.loop

local Client = {}
Client.__index = Client

local ERR = {
  parse = -32700,
  invalid_request = -32600,
  method_not_found = -32601,
  invalid_params = -32602,
  internal = -32603,
  transport = -32000,
}
local STDERR_MAX_LINES = 200

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
  }
end

local function update_config_option_current_value(config_options, matches, value)
  if type(config_options) ~= "table" then
    return false
  end

  matches = type(matches) == "table" and matches or { matches }
  for _, option in ipairs(config_options) do
    local id = tostring(option.id or "")
    local category = tostring(option.category or "")
    for _, candidate in ipairs(matches) do
      local expected = tostring(candidate or "")
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
    client_info = opts.client_info or default_client_info(),
    client_capabilities = opts.client_capabilities or default_client_capabilities(opts.handlers),
    handlers = opts.handlers or {},
    callbacks = {},
    next_id = 0,
    state = "created",
    stdout_buffer = "",
    stderr_lines = {},
    session_id = nil,
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
    on_update = opts.on_update or function() end,
    on_ready = opts.on_ready or function() end,
    on_error = opts.on_error or function() end,
    on_exit = opts.on_exit or function() end,
  }, Client)
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

function Client:_reject_pending(reason)
  local callbacks = self.callbacks
  self.callbacks = {}
  for _, callback in pairs(callbacks) do
    vim.schedule(function()
      pcall(callback, nil, {
        code = ERR.transport,
        message = reason or "ACP transport stopped",
      })
    end)
  end
end

function Client:_send_raw(payload)
  if not self.stdin or self.stdin:is_closing() then
    return false
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
    if cb then
      vim.schedule(function()
        pcall(cb, nil, {
          code = ERR.transport,
          message = "ACP transport not available",
        })
      end)
    end
  end
end

function Client:_send_notification(method, params)
  return self:_send_raw(encode_json({
    jsonrpc = "2.0",
    method = method,
    params = params or vim.empty_dict(),
  }))
end

function Client:_build_mcp_servers()
  local servers = {}
  if type(self.mcp_servers) == "table" then
    for _, server in ipairs(self.mcp_servers) do
      table.insert(servers, vim.deepcopy(server))
    end
  end

  local caps = self.agent_capabilities and self.agent_capabilities.mcpCapabilities or {}
  local supports_http = caps == nil or caps.http ~= false
  if self.mcp_url and self.mcp_url ~= "" and supports_http then
    table.insert(servers, {
      type = "http",
      name = self.mcp_name,
      url = self.mcp_url,
      headers = self.mcp_headers,
    })
  end
  return servers
end

function Client:_handle_initialize_response(result, callback)
  if not result or type(result) ~= "table" then
    callback(nil, {
      code = ERR.invalid_request,
      message = "ACP initialize returned an invalid response",
    })
    return
  end

  self.agent_capabilities = result.agentCapabilities or {}
  self.agent_info = result.agentInfo or {}
  self.auth_methods = result.authMethods or {}

  local session_params = {
    cwd = self.cwd,
    mcpServers = self:_build_mcp_servers(),
  }

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

    self:_convert_legacy_session_fields(session_result)
    self.session_id = session_result.sessionId
    self:_set_state("ready")
    callback(self, nil, session_result)
  end)
end

function Client:_handle_update(params)
  if not params or type(params) ~= "table" then return end
  local update = params.update
  if type(update) == "table" then
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

  if method == "session/request_permission" then
    if not handlers.request_permission then
      self:_send_result(id, { outcome = { outcome = "cancelled" } })
      return
    end
    self:_dispatch_async(id, function(done)
      handlers.request_permission(params or {}, function(outcome, err)
        if err then
          done(nil, err)
          return
        end
        done({
          outcome = outcome or { outcome = "cancelled" },
        })
      end)
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
end

function Client:_handle_message(line)
  local ok, message = pcall(decode_json, line)
  if not ok or type(message) ~= "table" then
    vim.schedule(function()
      pcall(self.on_error, {
        code = ERR.parse,
        message = "Failed to decode ACP message",
        data = line,
      })
    end)
    return
  end

  if message.method then
    if message.id ~= nil then
      self:_handle_server_request(message.id, message.method, message.params or {})
    elseif message.method == "session/update" then
      self:_handle_update(message.params or {})
    end
    return
  end

  if message.id == nil then
    return
  end

  local callback = self.callbacks[message.id]
  if not callback then
    return
  end
  self.callbacks[message.id] = nil
  vim.schedule(function()
    pcall(callback, message.result, message.error)
  end)
end

function Client:start(callback)
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

  local handle, pid = uv.spawn(self.command, {
    args = self.args,
    cwd = self.cwd,
    env = build_env(self.env),
    stdio = { stdin, stdout, stderr },
    detached = false,
  }, function(code, signal)
    safe_close(stdin)
    safe_close(stdout)
    safe_close(stderr)
    safe_close(handle)
    self.stdin = nil
    self.stdout = nil
    self.stderr = nil
    self.process = nil
    self.pid = nil
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

    self.stdout_buffer = self.stdout_buffer .. data
    while true do
      local idx = self.stdout_buffer:find("\n", 1, true)
      if not idx then break end
      local line = trim(self.stdout_buffer:sub(1, idx - 1))
      self.stdout_buffer = self.stdout_buffer:sub(idx + 1)
      if line ~= "" then
        self:_handle_message(line)
      end
    end
  end)

  stderr:read_start(function(err, data)
    if err then return end
    if not data or data == "" then return end
    local message = trim(data)
    if message ~= "" then
      append_stderr_line(self.stderr_lines, message)
    end
  end)

  local params = {
    protocolVersion = 1,
    clientCapabilities = {
      fs = empty_dict_if_needed(self.client_capabilities.fs or {}),
      terminal = self.client_capabilities.terminal == true,
    },
    clientInfo = self.client_info,
  }

  self:_send_request("initialize", params, function(result, err)
    if err then
      callback(nil, err)
      return
    end
    self:_handle_initialize_response(result, function(client, init_err, session_result)
      if init_err then
        callback(nil, init_err)
        return
      end
      vim.schedule(function()
        pcall(self.on_ready, session_result or {})
      end)
      callback(client, nil, session_result)
    end)
  end)
end

function Client:send_prompt(prompt, callback)
  if not self.session_id then
    callback(nil, {
      code = ERR.invalid_request,
      message = "ACP session is not ready",
    })
    return
  end

  self:_send_request("session/prompt", {
    sessionId = self.session_id,
    prompt = prompt,
  }, callback)
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
  return self:_send_notification("session/cancel", {
    sessionId = self.session_id,
  })
end

function Client:is_ready()
  return self.state == "ready" and self.session_id ~= nil
end

function Client:stop()
  if self.process and not self.process:is_closing() then
    pcall(function() self.process:kill(15) end)
    vim.defer_fn(function()
      if self.process and not self.process:is_closing() then
        pcall(function() self.process:kill(9) end)
      end
    end, 100)
  end
end

return Client
