local uv = vim.uv or vim.loop

local function encode(value)
  return vim.json.encode(value)
end

local function send_raw(value)
  io.stdout:write(value)
  io.stdout:flush()
end

local function send(value)
  send_raw(encode(value) .. "\n")
end

local function send_fragmented(value)
  local payload = encode(value) .. "\n"
  local split = math.max(1, math.floor(#payload / 2))
  send_raw(payload:sub(1, split))
  uv.sleep(5)
  send_raw(payload:sub(split + 1))
end

local function response(id, result)
  return {
    jsonrpc = "2.0",
    id = id,
    result = result,
  }
end

local function fail(id, message)
  send({
    jsonrpc = "2.0",
    id = id,
    error = {
      code = -32602,
      message = message,
    },
  })
end

local pending_prompt_id
local permission_complete = false
local read_complete = false
local cancel_received = false
local permission_cancelled = false
local cancel_prompt_finished = false

local function has_additional_directory(params)
  local directories = params and params.additionalDirectories
  return type(directories) == "table"
    and type(directories[1]) == "string"
    and directories[1]:match("/tests$") ~= nil
end

local function finish_prompt_if_ready()
  if not pending_prompt_id or not permission_complete or not read_complete then
    return
  end
  send(response(pending_prompt_id, {
    stopReason = "end_turn",
  }))
  pending_prompt_id = nil
end

local function finish_cancel_prompt_if_ready()
  if cancel_prompt_finished or not pending_prompt_id or not cancel_received or not permission_cancelled then
    return
  end
  cancel_prompt_finished = true
  send(response(pending_prompt_id, {
    stopReason = "cancelled",
  }))
  pending_prompt_id = nil
  uv.sleep(10)
  send({
    jsonrpc = "2.0",
    method = "session/update",
    params = {
      sessionId = "test-session",
      update = {
        sessionUpdate = "tool_call_update",
        toolCallId = "cancel-tool",
        status = "in_progress",
        _meta = {
          lateAfterPromptResponse = true,
        },
      },
    },
  })
end

for line in io.lines() do
  local ok, message = pcall(vim.json.decode, line)
  if not ok or type(message) ~= "table" then
    io.stderr:write("fake-agent received invalid JSON\n")
    io.stderr:flush()
  elseif message.method == "initialize" then
    local params = message.params or {}
    local client_caps = params.clientCapabilities or {}
    local boolean_caps = client_caps.session
      and client_caps.session.configOptions
      and client_caps.session.configOptions.boolean
    if params.protocolVersion ~= 1 then
      fail(message.id, "expected protocolVersion=1")
    elseif type(boolean_caps) ~= "table" then
      fail(message.id, "boolean config capability was not advertised")
    else
      local protocol_version = tonumber(vim.env.LAZYAGENT_FAKE_PROTOCOL_VERSION) or 1
      send_fragmented(response(message.id, {
        protocolVersion = protocol_version,
        agentCapabilities = {
          loadSession = true,
          promptCapabilities = {
            image = true,
            embeddedContext = true,
          },
          sessionCapabilities = {
            list = vim.empty_dict(),
            resume = vim.empty_dict(),
            close = vim.empty_dict(),
            delete = vim.empty_dict(),
            additionalDirectories = vim.empty_dict(),
          },
        },
        agentInfo = {
          name = "lazyagent-test-agent",
          version = "1.0.0",
        },
        authMethods = {},
      }))
    end
  elseif message.method == "session/new" then
    if not has_additional_directory(message.params) then
      fail(message.id, "session/new additionalDirectories missing")
    else
      send(response(message.id, {
        sessionId = "test-session",
        configOptions = {
          {
            id = "fast",
            name = "Fast",
            type = "boolean",
            currentValue = true,
          },
        },
      }))
    end
  elseif message.method == "session/load" or message.method == "session/resume" then
    if not has_additional_directory(message.params) then
      fail(message.id, message.method .. " additionalDirectories missing")
    else
      send(response(message.id, vim.empty_dict()))
    end
  elseif message.method == "session/list" then
    if vim.env.LAZYAGENT_FAKE_HANG_LIST ~= "1" then
      send(response(message.id, {
        sessions = {
          {
            sessionId = "test-session",
            cwd = message.params and message.params.cwd,
            title = "Contract test",
          },
        },
      }))
    end
  elseif message.method == "session/set_config_option" then
    send(response(message.id, {
      configOptions = {
        {
          id = message.params.configId,
          name = "Fast",
          type = "boolean",
          currentValue = message.params.value,
        },
      },
    }))
  elseif message.method == "session/delete" then
    send(response(message.id, vim.empty_dict()))
  elseif message.method == "session/prompt" then
    pending_prompt_id = message.id
    if vim.env.LAZYAGENT_FAKE_CANCEL_FLOW == "1" then
      cancel_received = false
      permission_cancelled = false
      cancel_prompt_finished = false
      send({
        jsonrpc = "2.0",
        method = "session/update",
        params = {
          sessionId = "test-session",
          update = {
            sessionUpdate = "tool_call",
            toolCallId = "cancel-tool",
            title = "Cancelable tool",
            kind = "execute",
            status = "in_progress",
          },
        },
      })
      send({
        jsonrpc = "2.0",
        id = 950,
        method = "session/request_permission",
        params = {
          sessionId = "test-session",
          toolCall = {
            toolCallId = "cancel-tool",
            title = "Cancelable tool",
            kind = "execute",
            status = "pending",
          },
          options = {
            {
              optionId = "allow-once",
              name = "Allow once",
              kind = "allow_once",
            },
          },
        },
      })
    else
      permission_complete = false
      read_complete = false

      send_raw("{not valid json}\n")
      send_fragmented({
        jsonrpc = "2.0",
        method = "session/update",
        params = {
          sessionId = "test-session",
          update = {
            sessionUpdate = "agent_message_chunk",
            messageId = "message-1",
            content = {
              type = "text",
              text = "hello from fake agent",
            },
          },
        },
      })

      local tool_update = encode({
        jsonrpc = "2.0",
        method = "session/update",
        params = {
          sessionId = "test-session",
          update = {
            sessionUpdate = "tool_call",
            toolCallId = "tool-1",
            title = "Read fixture",
            kind = "read",
            status = "in_progress",
          },
        },
      })
      local permission_request = encode({
        jsonrpc = "2.0",
        id = 900,
        method = "session/request_permission",
        params = {
          sessionId = "test-session",
          toolCall = {
            toolCallId = "tool-1",
            title = "Read fixture",
            kind = "read",
            status = "pending",
          },
          options = {
            {
              optionId = "allow-once",
              name = "Allow once",
              kind = "allow_once",
            },
          },
        },
      })
      local unknown_update = encode({
        jsonrpc = "2.0",
        method = "session/update",
        params = {
          sessionId = "test-session",
          update = {
            sessionUpdate = "future_update_for_contract_test",
            value = "preserved",
          },
        },
      })
      local read_request = encode({
        jsonrpc = "2.0",
        id = 901,
        method = "fs/read_text_file",
        params = {
          sessionId = "test-session",
          path = "/virtual/fixture.txt",
        },
      })
      send_raw(
        tool_update
          .. "\n"
          .. unknown_update
          .. "\n"
          .. permission_request
          .. "\n"
          .. read_request
          .. "\n"
      )
    end
  elseif message.id == 950 then
    local outcome = message.result and message.result.outcome
    if outcome and outcome.outcome == "cancelled" then
      permission_cancelled = true
    else
      send({
        jsonrpc = "2.0",
        method = "session/update",
        params = {
          sessionId = "test-session",
          update = {
            sessionUpdate = "duplicate_permission_response",
          },
        },
      })
    end
    finish_cancel_prompt_if_ready()
  elseif message.id == 900 then
    local outcome = message.result and message.result.outcome
    if outcome and outcome.outcome == "selected" and outcome.optionId == "allow-once" then
      permission_complete = true
    else
      io.stderr:write("unexpected permission response\n")
      io.stderr:flush()
    end
    finish_prompt_if_ready()
  elseif message.id == 901 then
    if message.result and message.result.content == "fixture-content" then
      read_complete = true
    else
      io.stderr:write("unexpected fs response\n")
      io.stderr:flush()
    end
    finish_prompt_if_ready()
  elseif message.method == "session/cancel" then
    cancel_received = true
    finish_cancel_prompt_if_ready()
  elseif message.method == "$/cancel_request" then
    send({
      jsonrpc = "2.0",
      method = "session/update",
      params = {
        sessionId = "test-session",
        update = {
          sessionUpdate = "cancel_request_observed",
          requestId = message.params and message.params.requestId,
        },
      },
    })
  elseif message.method == "session/close" then
    send(response(message.id, vim.empty_dict()))
    io.stderr:write("fake-agent-exit\n")
    io.stderr:flush()
    break
  end
end
