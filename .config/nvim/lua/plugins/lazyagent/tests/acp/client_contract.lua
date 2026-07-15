local M = {}

local function assert_equal(expected, actual, label)
  if not vim.deep_equal(expected, actual) then
    error(string.format(
      "%s: expected %s, got %s",
      label or "values differ",
      vim.inspect(expected),
      vim.inspect(actual)
    ), 2)
  end
end

local function assert_truthy(value, label)
  if not value then
    error(label or "expected a truthy value", 2)
  end
end

local function wait_for(label, predicate, timeout_ms)
  if not vim.wait(timeout_ms or 3000, predicate, 10) then
    error("timed out waiting for " .. label, 2)
  end
end

local function plugin_root()
  local source = debug.getinfo(1, "S").source:gsub("^@", "")
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local function new_client(root, overrides)
  overrides = overrides or {}
  local Client = require("lazyagent.acp.client")
  local updates = {}
  local errors = {}
  local exits = {}
  local permission_requests = {}
  local protocol_events = {}
  local deferred_permission_done

  local opts = {
    command = {
      vim.v.progpath,
      "--headless",
      "--clean",
      "-u",
      "NONE",
      "-l",
      root .. "/tests/acp/fake_agent.lua",
    },
    cwd = root,
    env = overrides.env,
    additional_directories = {
      root .. "/tests",
    },
    request_timeout_ms = overrides.request_timeout_ms,
    prompt_timeout_ms = overrides.prompt_timeout_ms,
    cancel_settle_ms = overrides.cancel_settle_ms,
    handlers = {
      read_text_file = function(params)
        assert_equal("/virtual/fixture.txt", params.path, "read path")
        return { content = "fixture-content" }
      end,
      request_permission = function(params, done)
        permission_requests[#permission_requests + 1] = params
        if overrides.defer_permission then
          deferred_permission_done = done
        else
          done({
            outcome = "selected",
            optionId = "allow-once",
          })
        end
      end,
    },
    on_update = function(params)
      updates[#updates + 1] = params
    end,
    on_error = function(err)
      errors[#errors + 1] = err
    end,
    on_protocol_event = function(event)
      protocol_events[#protocol_events + 1] = event
    end,
    on_exit = function(code, signal, stderr)
      exits[#exits + 1] = {
        code = code,
        signal = signal,
        stderr = stderr,
      }
    end,
  }

  local client = Client.new(opts)
  return client, {
    updates = updates,
    errors = errors,
    exits = exits,
    permission_requests = permission_requests,
    protocol_events = protocol_events,
    deferred_permission_done = function()
      return deferred_permission_done
    end,
  }
end

local function test_capability_semantics()
  local Client = require("lazyagent.acp.client")
  local client = Client.new({})
  client.agent_capabilities = {
    sessionCapabilities = {
      list = false,
      resume = vim.empty_dict(),
      close = vim.NIL,
    },
  }

  assert_equal(false, client:supports_session_list(), "false capability")
  assert_equal(true, client:supports_session_resume(), "empty object capability")
  assert_equal(false, client:supports_session_close(), "null capability")
  assert_equal(false, client:supports_session_delete(), "missing delete capability")
end

local function test_stdio_contract(root)
  local client, observed = new_client(root)
  local started = false
  local start_error

  client:start(function(connected, err, session)
    start_error = err
    assert_equal(client, connected, "connected client")
    assert_equal("test-session", session.sessionId, "new session id")
    started = true
  end)

  wait_for("client startup", function() return started or start_error ~= nil end)
  assert_equal(nil, start_error, "start error")
  assert_truthy(client:is_ready(), "client should be ready")
  assert_equal("lazyagent-test-agent", client.agent_info.name, "agent info")
  assert_equal(true, client:supports_session_list(), "session/list capability")
  assert_equal(true, client:supports_session_resume(), "session/resume capability")
  assert_equal(true, client:supports_session_close(), "session/close capability")
  assert_equal(true, client:supports_session_delete(), "session/delete capability")
  assert_equal(true, client:supports_additional_directories(), "additionalDirectories capability")
  assert_equal(true, client:supports_session_load(), "session/load capability")
  assert_equal("fast", client.config_options[1].id, "boolean config option")

  local listed
  client:list_sessions({ cwd = root }, function(result, err)
    assert_equal(nil, err, "session/list error")
    listed = result
  end)
  wait_for("session/list", function() return listed ~= nil end)
  assert_equal("test-session", listed.sessions[1].sessionId, "listed session")

  local configured
  client:set_config_option("fast", false, function(options, err)
    assert_equal(nil, err, "set_config_option error")
    configured = options
  end)
  wait_for("config update", function() return configured ~= nil end)
  assert_equal(false, configured[1].currentValue, "boolean config value")

  local prompt_result
  client:send_prompt({
    {
      type = "text",
      text = "run contract test",
    },
  }, function(result, err)
    assert_equal(nil, err, "prompt error")
    prompt_result = result
  end)

  wait_for("prompt response", function() return prompt_result ~= nil end)
  wait_for("scheduled updates", function()
    return #observed.updates == 3
      and #observed.errors == 1
      and #observed.permission_requests == 1
      and #observed.protocol_events >= 2
  end)
  assert_equal("end_turn", prompt_result.stopReason, "prompt stop reason")
  assert_equal("agent_message_chunk", observed.updates[1].update.sessionUpdate, "fragmented update")
  assert_equal("tool_call", observed.updates[2].update.sessionUpdate, "batched update")
  assert_equal("future_update_for_contract_test", observed.updates[3].update.sessionUpdate, "unknown update")
  assert_equal("preserved", observed.updates[3].update.value, "unknown update payload")
  assert_equal(-32700, observed.errors[1].code, "parse error code")
  local event_kinds = {}
  for _, event in ipairs(observed.protocol_events) do
    event_kinds[event.kind] = true
  end
  assert_equal(true, event_kinds.parse_error, "parse error logged")
  assert_equal(true, event_kinds.unknown_update, "unknown update logged")
  assert_equal(#observed.protocol_events, #client:get_protocol_events(), "protocol log retained")
  assert_equal("tool-1", observed.permission_requests[1].toolCall.toolCallId, "permission request")

  local loaded = false
  client:load_session("loaded-session", function(_, err)
    assert_equal(nil, err, "session/load error")
    loaded = true
  end)
  wait_for("session/load", function() return loaded end)
  assert_equal("loaded-session", client.session_id, "loaded session id")

  local resumed = false
  client:resume_session("resumed-session", function(_, err)
    assert_equal(nil, err, "session/resume error")
    resumed = true
  end)
  wait_for("session/resume", function() return resumed end)
  assert_equal("resumed-session", client.session_id, "resumed session id")

  local deleted = false
  client:delete_session("old-session", function(_, err)
    assert_equal(nil, err, "session/delete error")
    deleted = true
  end)
  wait_for("session/delete", function() return deleted end)

  local closed = false
  client:close_session(nil, function(_, err)
    assert_equal(nil, err, "session/close error")
    closed = true
  end)
  wait_for("session close", function() return closed end)
  wait_for("agent exit", function() return #observed.exits == 1 end)
  assert_equal(0, observed.exits[1].code, "agent exit code")
  assert_truthy(observed.exits[1].stderr:find("fake%-agent%-exit") ~= nil, "stderr capture")
  assert_equal("stopped", client.state, "stopped state")
  assert_equal(nil, next(client.callbacks), "pending callbacks")
end

local function test_protocol_mismatch_stops_process(root)
  local client, observed = new_client(root, {
    env = {
      LAZYAGENT_FAKE_PROTOCOL_VERSION = "2",
    },
  })
  local completed = false
  local start_error

  client:start(function(connected, err)
    assert_equal(nil, connected, "mismatched client")
    start_error = err
    completed = true
  end)

  wait_for("protocol mismatch", function() return completed end)
  assert_truthy(start_error and start_error.message:find("version mismatch", 1, true), "protocol mismatch error")
  wait_for("mismatched agent exit", function() return #observed.exits == 1 end)
  assert_equal("stopped", client.state, "mismatched client stopped")
  assert_equal(nil, client.process, "mismatched process released")
end

local function test_request_timeout_sends_cancellation(root)
  local client, observed = new_client(root, {
    env = {
      LAZYAGENT_FAKE_HANG_LIST = "1",
    },
    request_timeout_ms = 1000,
  })
  local started = false

  client:start(function(connected, err)
    assert_equal(nil, err, "timeout test startup")
    assert_equal(client, connected, "timeout test client")
    started = true
  end)
  wait_for("timeout test startup", function() return started end)
  client.request_timeout_ms = 50

  local list_error
  client:list_sessions({}, function(result, err)
    assert_equal(nil, result, "timed out result")
    list_error = err
  end)
  wait_for("request timeout", function() return list_error ~= nil end)
  assert_truthy(list_error.message:find("session/list", 1, true), "timeout method")
  wait_for("cancel request notification", function()
    return #observed.updates == 1
      and observed.updates[1].update.sessionUpdate == "cancel_request_observed"
  end)
  assert_truthy(type(observed.updates[1].update.requestId) == "number", "cancelled request id")
  assert_equal(nil, next(client.callbacks), "timeout callbacks")
  assert_equal(nil, next(client.callback_timers), "timeout timers")

  local closed = false
  client:close_session(nil, function(_, err)
    assert_equal(nil, err, "timeout test close")
    closed = true
  end)
  wait_for("timeout test close", function() return closed end)
  wait_for("timeout test agent exit", function() return #observed.exits == 1 end)
end

local function test_cancel_settles_late_updates(root)
  local client, observed = new_client(root, {
    env = {
      LAZYAGENT_FAKE_CANCEL_FLOW = "1",
    },
    defer_permission = true,
    cancel_settle_ms = 30,
  })
  local started = false

  client:start(function(connected, err)
    assert_equal(nil, err, "cancel test startup")
    assert_equal(client, connected, "cancel test client")
    started = true
  end)
  wait_for("cancel test startup", function() return started end)

  local prompt_result
  local updates_at_callback
  client:send_prompt({
    {
      type = "text",
      text = "cancel this turn",
    },
  }, function(result, err)
    assert_equal(nil, err, "cancelled prompt error")
    prompt_result = result
    updates_at_callback = #observed.updates
  end)

  wait_for("pending permission", function()
    return #observed.permission_requests == 1 and observed.deferred_permission_done() ~= nil
  end)
  assert_equal("active", client.prompt_state, "active prompt state")
  assert_equal(1, vim.tbl_count(client.pending_permission_requests), "pending permission count")

  assert_equal(true, client:cancel(), "session cancel notification")
  assert_equal("cancelling", client.prompt_state, "cancelling prompt state")
  assert_equal(0, vim.tbl_count(client.pending_permission_requests), "cancelled permission count")

  wait_for("cancelled prompt response", function() return prompt_result ~= nil end)
  assert_equal("cancelled", prompt_result.stopReason, "cancel stop reason")
  assert_equal("idle", client.prompt_state, "settled prompt state")
  assert_equal(2, updates_at_callback, "late update delivered before callback")
  assert_equal("tool_call_update", observed.updates[2].update.sessionUpdate, "late tool update")
  assert_equal(true, observed.updates[2].update._meta.lateAfterPromptResponse, "late update marker")

  observed.deferred_permission_done()({
    outcome = "selected",
    optionId = "allow-once",
  })
  vim.wait(30, function() return false end, 10)
  assert_equal(2, #observed.updates, "deferred permission callback ignored")

  local closed = false
  client:close_session(nil, function(_, err)
    assert_equal(nil, err, "cancel test close")
    closed = true
  end)
  wait_for("cancel test close", function() return closed end)
  wait_for("cancel test agent exit", function() return #observed.exits == 1 end)
end

function M.run()
  local root = plugin_root()
  test_capability_semantics()
  test_stdio_contract(root)
  test_protocol_mismatch_stops_process(root)
  test_request_timeout_sends_cancellation(root)
  test_cancel_settles_late_updates(root)
end

return M
