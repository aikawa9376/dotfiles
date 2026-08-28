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

local replay_on_load = vim.env.LAZYAGENT_FAKE_REPLAY_ON_LOAD == "1"
local replay_tool = vim.env.LAZYAGENT_FAKE_REPLAY_TOOL == "1"
local load_error = vim.env.LAZYAGENT_FAKE_LOAD_ERROR
local resume_error = vim.env.LAZYAGENT_FAKE_RESUME_ERROR
local hang_load = vim.env.LAZYAGENT_FAKE_HANG_LOAD == "1"
local auth_on_load = vim.env.LAZYAGENT_FAKE_AUTH_ON_LOAD == "1"
local load_host_request = vim.env.LAZYAGENT_FAKE_LOAD_HOST_REQUEST
local auth_enabled = vim.env.LAZYAGENT_FAKE_AUTH_FLOW == "1" or auth_on_load

local conflicts = 0
for _, enabled in ipairs({
  load_error ~= nil and load_error ~= "",
  hang_load,
  auth_on_load,
}) do
  if enabled then conflicts = conflicts + 1 end
end
if conflicts > 1
  or (hang_load and (replay_on_load or load_host_request ~= nil))
  or (load_error ~= nil and load_error ~= "" and (replay_on_load or load_host_request ~= nil))
  or (replay_tool and not replay_on_load)
then
  io.stderr:write("conflicting activation controls\n")
  io.stderr:flush()
  os.exit(2)
end

local valid_activation_errors = {
  method_not_found = true,
  session_not_found = true,
  auth_required = true,
  agent_error = true,
}
if (load_error and not valid_activation_errors[load_error]) or (resume_error and not valid_activation_errors[resume_error]) then
  io.stderr:write("invalid activation error control\n")
  io.stderr:flush()
  os.exit(2)
end
if load_host_request
  and load_host_request ~= "fs_write"
  and load_host_request ~= "terminal"
  and load_host_request ~= "permission"
then
  io.stderr:write("invalid load host request control\n")
  io.stderr:flush()
  os.exit(2)
end

local pending_prompt_id
local permission_complete = false
local read_complete = false
local cancel_received = false
local permission_cancelled = false
local cancel_prompt_finished = false
local authenticated = not auth_enabled
local scope_rejected = false
local write_complete = false
local terminal_complete = false
local pending_activation

local function activation_error(id, method, value)
  local shapes = {
    method_not_found = { code = -32601, message = "Method not found: " .. method },
    session_not_found = { code = -32000, message = "Session not found" },
    auth_required = { code = -32000, message = "Authentication required" },
    agent_error = { code = -32042, message = "Fake activation failure" },
  }
  local shape = shapes[value]
  send({ jsonrpc = "2.0", id = id, error = shape })
end

local function replay(session_id)
  local function update(value)
    send({ jsonrpc = "2.0", method = "session/update", params = { sessionId = session_id, update = value } })
  end
  update({ sessionUpdate = "user_message_chunk", messageId = "replay-user-1", content = { type = "text", text = "older " } })
  update({ sessionUpdate = "user_message_chunk", messageId = "replay-user-1", content = { type = "text", text = "question" } })
  update({ sessionUpdate = "agent_message_chunk", messageId = "replay-agent-1", content = { type = "text", text = "older " } })
  update({ sessionUpdate = "agent_message_chunk", messageId = "replay-agent-1", content = { type = "text", text = "answer" } })
  if replay_tool then
    update({
      sessionUpdate = "tool_call",
      toolCallId = "replay-tool-1",
      title = "Historical edit",
      kind = "edit",
      status = "pending",
      locations = { { path = "fixture.lua", line = 1 } },
    })
    update({
      sessionUpdate = "tool_call_update",
      toolCallId = "replay-tool-1",
      kind = "edit",
      status = "completed",
    })
  end
  update({ sessionUpdate = "session_info_update", title = "Replayed native session" })
end

local function finish_activation_request()
  if not pending_activation then return end
  local request = pending_activation
  pending_activation = nil
  send(response(request.id, vim.empty_dict()))
end

local function request_during_load(message)
  if not load_host_request then return false end
  pending_activation = { id = message.id, method = message.method, session_id = message.params.sessionId }
  local methods = {
    fs_write = {
      method = "fs/write_text_file",
      params = { sessionId = message.params.sessionId, path = "/fixture/replay.txt", content = "historical content" },
    },
    terminal = {
      method = "terminal/create",
      params = { sessionId = message.params.sessionId, command = "historical-command", args = {} },
    },
    permission = {
      method = "session/request_permission",
      params = {
        sessionId = message.params.sessionId,
        toolCall = { toolCallId = "replay-permission", title = "Historical permission", status = "pending" },
        options = {},
      },
    },
  }
  local request = methods[load_host_request]
  send({ jsonrpc = "2.0", id = 980, method = request.method, params = request.params })
  return true
end

local function has_additional_directory(params)
  local directories = params and params.additionalDirectories
  return type(directories) == "table"
    and type(directories[1]) == "string"
    and directories[1]:match("/tests$") ~= nil
end

local function has_mcp_servers(params)
  if vim.env.LAZYAGENT_FAKE_EXPECT_MCP ~= "1" then return true end
  local servers = params and params.mcpServers
  local stdio = type(servers) == "table" and servers[1] or nil
  local http = type(servers) == "table" and servers[2] or nil
  return stdio and stdio.name == "contract-stdio"
    and type(stdio.command) == "string" and stdio.command:sub(1, 1) == "/"
    and stdio.env and stdio.env[1] and stdio.env[1].name == "CONTRACT_TOKEN"
    and http and http.type == "http" and http.name == "contract-http"
    and http.headers and http.headers[1] and http.headers[1].name == "Authorization"
end

local function finish_prompt_if_ready()
  if not pending_prompt_id
    or not permission_complete
    or not read_complete
    or not scope_rejected
    or not write_complete
    or not terminal_complete
  then
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
          auth = auth_enabled and {
            logout = vim.empty_dict(),
          } or nil,
          loadSession = vim.env.LAZYAGENT_FAKE_DISABLE_LOAD ~= "1",
          promptCapabilities = {
            image = true,
            embeddedContext = true,
          },
          mcpCapabilities = {
            http = true,
            sse = false,
          },
          sessionCapabilities = {
            list = vim.empty_dict(),
            resume = vim.env.LAZYAGENT_FAKE_DISABLE_RESUME ~= "1" and vim.empty_dict() or nil,
            close = vim.empty_dict(),
            delete = vim.empty_dict(),
            additionalDirectories = vim.empty_dict(),
          },
        },
        agentInfo = {
          name = "lazyagent-test-agent",
          version = "1.0.0",
        },
        _meta = {
          steering = {
            supported = true,
          },
        },
        authMethods = auth_enabled and {
          {
            id = "test-auth",
            name = "Test authentication",
            description = "Authenticate the contract fake agent",
          },
        } or {},
      }))
    end
  elseif message.method == "authenticate" then
    if message.params and message.params.methodId == "test-auth" then
      authenticated = true
      send(response(message.id, vim.empty_dict()))
    else
      fail(message.id, "unexpected authentication method")
    end
  elseif message.method == "logout" then
    authenticated = false
    send(response(message.id, vim.empty_dict()))
  elseif message.method == "session/new" then
    if not authenticated then
      send({
        jsonrpc = "2.0",
        id = message.id,
        error = { code = -32000, message = "Authentication required" },
      })
    elseif not has_additional_directory(message.params) then
      fail(message.id, "session/new additionalDirectories missing")
    elseif not has_mcp_servers(message.params) then
      fail(message.id, "session/new mcpServers missing")
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
    elseif not has_mcp_servers(message.params) then
      fail(message.id, message.method .. " mcpServers missing")
    elseif message.method == "session/load" and hang_load then
      -- Intentionally leave the request pending for timeout coverage.
    elseif message.method == "session/load" and load_error then
      activation_error(message.id, "session/load", load_error)
    elseif message.method == "session/resume" and resume_error then
      activation_error(message.id, "session/resume", resume_error)
    elseif message.method == "session/load" and auth_on_load and not authenticated then
      activation_error(message.id, "session/load", "auth_required")
    else
      if message.method == "session/load" and replay_on_load then replay(message.params.sessionId) end
      if message.method ~= "session/load" or not request_during_load(message) then
        send(response(message.id, vim.empty_dict()))
      end
    end
  elseif message.id == 980 and pending_activation then
    local rejected = message.error ~= nil
      or (load_host_request == "permission"
        and message.result
        and message.result.outcome
        and message.result.outcome.outcome == "cancelled")
    if rejected then
      finish_activation_request()
    else
      io.stderr:write("load host request was not rejected\n")
      io.stderr:flush()
      os.exit(3)
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
  elseif message.method == "_session/steering" then
    send(response(message.id, {
      outcome = "injected",
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
      if vim.env.LAZYAGENT_FAKE_SESSION_INFO_TITLE then
        send({
          jsonrpc = "2.0",
          method = "session/update",
          params = {
            sessionId = "test-session",
            update = {
              sessionUpdate = "session_info_update",
              title = vim.env.LAZYAGENT_FAKE_SESSION_INFO_TITLE,
            },
          },
        })
      end
      if vim.env.LAZYAGENT_FAKE_PROVIDER_EXTENSIONS == "1" then
        for _, update_value in ipairs({
          {
            sessionUpdate = "plan_update",
            plan = { type = "markdown", planId = "fixture-plan", content = "# Fixture plan" },
          },
          { sessionUpdate = "plan_removed", planId = "fixture-plan" },
          {
            sessionUpdate = "compaction_summary_chunk",
            compactionId = "compact-1",
            content = { type = "text", text = "Earlier work was summarized." },
          },
          { sessionUpdate = "compaction_update", compactionId = "compact-1", status = "completed" },
          {
            sessionUpdate = "session_info_update",
            _meta = {
              jetbrains = {
                air = {
                  version = 1,
                  sessionFailure = {
                    id = "fixture-turn:error",
                    revision = 1,
                    category = "connection",
                    severity = "warning",
                    title = "Retrying fixture connection",
                    actions = { "retry" },
                  },
                },
              },
            },
          },
        }) do
          send({
            jsonrpc = "2.0",
            method = "session/update",
            params = { sessionId = "test-session", update = update_value },
          })
        end
      end
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
      local wrong_session_request = encode({
        jsonrpc = "2.0",
        id = 899,
        method = "session/request_permission",
        params = {
          sessionId = "other-session",
          toolCall = { toolCallId = "wrong-session-tool", title = "Wrong session", status = "pending" },
          options = {},
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
      local write_request = encode({
        jsonrpc = "2.0",
        id = 902,
        method = "fs/write_text_file",
        params = {
          sessionId = "test-session",
          path = "/virtual/output.txt",
          content = "fixture-content",
        },
      })
      local terminal_request = encode({
        jsonrpc = "2.0",
        id = 903,
        method = "terminal/create",
        params = {
          sessionId = "test-session",
          command = "fixture-command",
          args = { "arg" },
        },
      })
      send_raw(
        tool_update
          .. "\n"
          .. unknown_update
          .. "\n"
          .. wrong_session_request
          .. "\n"
          .. permission_request
          .. "\n"
          .. read_request
          .. "\n"
          .. write_request
          .. "\n"
          .. terminal_request
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
  elseif message.id == 899 then
    if message.error and message.error.code == -32602 then
      scope_rejected = true
    else
      io.stderr:write("wrong-session request was not rejected\n")
      io.stderr:flush()
    end
    finish_prompt_if_ready()
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
  elseif message.id == 902 then
    write_complete = message.error == nil
    finish_prompt_if_ready()
  elseif message.id == 903 then
    if message.result and message.result.terminalId == "fixture-terminal" then
      for id, method in ipairs({ "terminal/output", "terminal/wait_for_exit", "terminal/kill", "terminal/release" }) do
        send({
          jsonrpc = "2.0",
          id = 903 + id,
          method = method,
          params = { sessionId = "test-session", terminalId = "fixture-terminal" },
        })
      end
    else
      io.stderr:write("unexpected terminal/create response\n")
      io.stderr:flush()
    end
  elseif type(message.id) == "number" and message.id >= 904 and message.id <= 907 then
    if message.error then
      io.stderr:write("terminal lifecycle request failed\n")
      io.stderr:flush()
    end
    if message.id == 907 then
      terminal_complete = message.error == nil
      finish_prompt_if_ready()
    end
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
