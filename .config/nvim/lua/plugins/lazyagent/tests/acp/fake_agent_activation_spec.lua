local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function plugin_root()
  local source = debug.getinfo(1, "S").source:gsub("^@", "")
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local function start_fixture(root, mode, env, opts)
  opts = opts or {}
  local Client = require("lazyagent.acp.client")
  local observed = { updates = {}, exits = {}, auth = 0, order = {} }
  local client = Client.new({
    command = { vim.v.progpath, "--headless", "--clean", "-u", "NONE", "-l", root .. "/tests/acp/fake_agent.lua" },
    cwd = root,
    additional_directories = { root .. "/tests" },
    env = env,
    request_timeout_ms = opts.direct_call and (opts.initialize_timeout_ms or 500)
      or opts.request_timeout_ms or 500,
    handlers = opts.handlers or {
      select_auth_method = function(methods, done)
        observed.auth = observed.auth + 1
        done(methods[1].id)
      end,
    },
    on_update = function(params)
      observed.updates[#observed.updates + 1] = params.update
      observed.order[#observed.order + 1] = params.update.sessionUpdate
    end,
    on_exit = function(code, signal, stderr)
      observed.exits[#observed.exits + 1] = { code = code, signal = signal, stderr = stderr }
    end,
  })
  local result, result_err
  if opts.direct_call then
    local initialized, initialize_err
    client:start(function(connected, err)
      initialized = connected
      initialize_err = err
    end, { create_session = false })
    assert(vim.wait(3000, function() return initialized ~= nil or initialize_err ~= nil end, 10),
      "activation fixture initialize")
    if initialize_err then
      result_err = initialize_err
    else
      if opts.request_timeout_ms then client.request_timeout_ms = opts.request_timeout_ms end
      local invoke = mode == "load" and client.load_session or client.resume_session
      invoke(client, "activation-session", function(session, err)
        result = session
        result_err = err
        observed.order[#observed.order + 1] = "response"
      end)
    end
  else
    client:start(function(connected, err, session)
      result = connected and session or nil
      result_err = err
      observed.order[#observed.order + 1] = "response"
    end, { session_mode = mode, session_id = "activation-session" })
  end
  assert(vim.wait(3000, function() return result ~= nil or result_err ~= nil end, 10),
    "activation fixture " .. mode .. " should complete")
  return client, observed, result, result_err
end

local function close_fixture(client, observed)
  if client:is_connected() and client.session_id then
    local closed
    client:close_session(nil, function(_, err)
      assert_equal(err, nil, "fixture close error")
      closed = true
    end)
    assert(vim.wait(2000, function() return closed == true end, 10), "fixture close response")
  elseif client:is_connected() then
    client:stop()
  end
  assert(vim.wait(2000, function() return #observed.exits == 1 end, 10), "fixture child exit")
  assert_equal(client:debug_snapshot().callbacks, 0, "fixture callback cleanup")
end

local function test_replay(root, include_tool)
  local env = { LAZYAGENT_FAKE_REPLAY_ON_LOAD = "1" }
  if include_tool then env.LAZYAGENT_FAKE_REPLAY_TOOL = "1" end
  local client, observed, result, err = start_fixture(root, "load", env)
  assert_equal(err, nil, "canonical replay load error")
  assert(result ~= nil, "canonical replay load result")
  assert(vim.wait(1000, function() return #observed.updates == (include_tool and 7 or 5) end, 10),
    "canonical replay updates")
  assert_equal(vim.list_slice(observed.order, 1, 4), {
    "user_message_chunk", "user_message_chunk", "agent_message_chunk", "agent_message_chunk",
  }, "canonical replay message order")
  assert_equal(observed.order[#observed.order], "response", "load replay precedes response")
  assert_equal(observed.updates[1].messageId, "replay-user-1", "canonical replay user message ID")
  assert_equal(observed.updates[3].messageId, "replay-agent-1", "canonical replay agent message ID")
  if include_tool then
    assert_equal(observed.updates[5].sessionUpdate, "tool_call", "canonical replay tool start")
    assert_equal(observed.updates[6].status, "completed", "canonical replay tool completion")
  end
  close_fixture(client, observed)
end

local function test_errors(root, mode)
  local variable = mode == "load" and "LAZYAGENT_FAKE_LOAD_ERROR" or "LAZYAGENT_FAKE_RESUME_ERROR"
  local expected = {
    method_not_found = { -32601, "Method not found: session/" .. mode },
    session_not_found = { -32000, "Session not found" },
    auth_required = { -32000, "Authentication required" },
    agent_error = { -32042, "Fake activation failure" },
  }
  for value, shape in pairs(expected) do
    local client, observed, result, err = start_fixture(root, mode, { [variable] = value }, { direct_call = true })
    assert_equal(result, nil, mode .. " " .. value .. " result")
    assert_equal(err.code, shape[1], mode .. " " .. value .. " code")
    assert_equal(err.message, shape[2], mode .. " " .. value .. " message")
    close_fixture(client, observed)
  end
end

local function test_hang(root)
  local client, observed, result, err = start_fixture(root, "load", { LAZYAGENT_FAKE_HANG_LOAD = "1" }, {
    request_timeout_ms = 50,
    direct_call = true,
  })
  assert_equal(result, nil, "hanging load result")
  assert(err and err.message:find("session/load", 1, true), "hanging load times out deterministically")
  close_fixture(client, observed)
end

local function test_auth_on_load(root)
  local client, observed, result, err = start_fixture(root, "load", { LAZYAGENT_FAKE_AUTH_ON_LOAD = "1" })
  assert_equal(err, nil, "auth-on-load result")
  assert(result ~= nil, "auth-on-load succeeds after authentication")
  assert_equal(observed.auth, 1, "auth-on-load authenticates exactly once")
  close_fixture(client, observed)
end

local function test_host_requests(root)
  for _, kind in ipairs({ "fs_write", "terminal", "permission" }) do
    local client, observed, result, err = start_fixture(root, "load", {
      LAZYAGENT_FAKE_LOAD_HOST_REQUEST = kind,
    }, { handlers = {} })
    assert_equal(err, nil, "load host request " .. kind .. " error")
    assert(result ~= nil, "load host request " .. kind .. " records rejection")
    close_fixture(client, observed)
  end
end

local function test_conflicts(root)
  local client, observed, result, err = start_fixture(root, "load", {
    LAZYAGENT_FAKE_LOAD_ERROR = "agent_error",
    LAZYAGENT_FAKE_HANG_LOAD = "1",
  })
  assert_equal(result, nil, "conflicting controls result")
  assert(err ~= nil, "conflicting controls fail")
  close_fixture(client, observed)
  assert(observed.exits[1].stderr:find("conflicting activation controls", 1, true),
    "conflicting controls explain fixture failure")
end

function M.run()
  local root = plugin_root()
  test_replay(root, false)
  test_replay(root, true)
  test_errors(root, "load")
  test_errors(root, "resume")
  test_hang(root)
  test_auth_on_load(root)
  test_host_requests(root)
  test_conflicts(root)
end

return M
