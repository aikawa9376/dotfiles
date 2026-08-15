local M = {}

local Harness = require("tests.e2e.harness")
local Client = require("lazyagent.acp.client")

local providers = { fake = true, codex = true, copilot = true }
local scenarios = {
  ["restart-reopen"] = true,
  ["owned-process-crash"] = true,
  ["timeout-late-update"] = true,
  ["pending-permission-close"] = true,
}

local function redact_text(value)
  return tostring(Harness.redact(tostring(value or ""))):sub(1, 512)
end

local function matrix()
  return {
    restart = "not-run",
    crash = "not-run",
    timeout = "not-run",
    late_update = "not-run",
    close_pending_permission = "not-run",
  }
end

local function write_result(path, result)
  local parent = vim.fn.fnamemodify(path, ":h")
  assert(vim.fn.isdirectory(parent) == 1 or vim.fn.mkdir(parent, "p") == 1)
  assert(vim.fn.writefile({ vim.json.encode(Harness.redact(result)) }, path) == 0)
end

local function base_result(provider, scenario, status)
  local uname = vim.system({ "uname", "-srmo" }, { text = true }):wait().stdout:gsub("%s+$", "")
  return {
    schema_version = 1,
    generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    provider = provider or "none",
    provider_version = "not-run",
    platform = uname,
    scenario = scenario or "none",
    scope = scenario == "pending-permission-close" and "isolated-mutation" or "read-only",
    status = status,
    capabilities = {},
    results = matrix(),
    costs = "not-recorded",
    mutations = "none",
  }
end

local function wait_for(label, timeout_ms, predicate)
  assert(vim.wait(timeout_ms, predicate, 10), label .. " timed out")
end

local function snapshot_is_zero(snapshot)
  return snapshot.process == false
    and snapshot.stdin == false
    and snapshot.stdout == false
    and snapshot.stderr == false
    and snapshot.callbacks == 0
    and snapshot.callback_timers == 0
    and snapshot.stop_timer == 0
    and snapshot.pending_permissions == 0
    and snapshot.pending_elicitations == 0
end

local function await_release(label, client, timeout_ms)
  wait_for(label, timeout_ms, function() return snapshot_is_zero(client:debug_snapshot()) end)
  return client:debug_snapshot()
end

local function start_client(client, timeout_ms, activation)
  local done, active, start_err, session = false, nil, nil, nil
  client:start(function(value, err, session_result)
    active, start_err, session, done = value, err, session_result, true
  end, activation and { activation = activation } or nil)
  wait_for("provider start", timeout_ms, function() return done end)
  if start_err then error(redact_text(start_err.message or start_err)) end
  assert(active and client.session_id, "provider did not create or attach a session")
  return session
end

local function await_close(client, timeout_ms)
  if not client.session_id or not client:supports_session_close() then return "unsupported" end
  local done, close_err = false, nil
  client:close_session(nil, function(_, err)
    close_err, done = err, true
  end)
  wait_for("session close", timeout_ms, function() return done end)
  if close_err then error(redact_text(close_err.message or close_err)) end
  return "pass"
end

local function stop_and_release(client, timeout_ms)
  if client:is_connected() then client:stop() end
  return await_release("client resource release", client, timeout_ms)
end

local function fixed_prompt(kind)
  if kind == "permission" then
    return { {
      type = "text",
      text = "Create e2e-marker.txt in the current working directory containing exactly LAZYAGENT_E2E_OK and a trailing newline. Do not modify any other file. Then reply with exactly done.",
    } }
  end
  return { {
    type = "text",
    text = "Compute the first 10000 prime numbers silently, then reply with only the last one. Do not use tools or modify files.",
  } }
end

local function await_prompt(client, prompt, timeout_ms)
  local done, prompt_err = false, nil
  client:send_prompt(prompt, function(_, err)
    prompt_err, done = err, true
  end)
  wait_for("provider prompt", timeout_ms, function() return done end)
  if prompt_err then error(redact_text(prompt_err.message or prompt_err)) end
end

local function run_restart(opts, result, workspace, make_client, timeout_ms)
  local first = make_client()
  start_client(first, timeout_ms)
  local session_id = assert(first.session_id)
  result.provider_version = first.agent_info and first.agent_info.version or "unknown"
  result.capabilities = Harness.redact(first.agent_capabilities or {})
  local reopen_mode
  if first:supports_session_load() then
    reopen_mode = "load"
  elseif first:supports_session_resume() then
    reopen_mode = "resume"
  else
    first:stop()
    result.first_release = await_release("unsupported first process release", first, timeout_ms)
    result.results.restart = "unsupported"
    return
  end
  if opts.provider ~= "fake" then
    await_prompt(first, { {
      type = "text",
      text = "Reply with exactly LAZYAGENT_E2E_OK. Do not use tools or modify files.",
    } }, timeout_ms)
  end
  assert(first.process and first.pid, "first client has no owned child process")
  first:stop()
  result.first_release = await_release("first process release", first, timeout_ms)

  local second = make_client()
  start_client(second, timeout_ms, {
    request = {
      requested_mode = reopen_mode,
      session_id = session_id,
      origin = "native_import",
      history_state = "missing",
      has_local_history = false,
    },
    hooks = {},
  })
  assert(second.session_id == session_id, "fresh process did not reopen the original session")
  result.close = await_close(second, timeout_ms)
  result.second_release = stop_and_release(second, timeout_ms)
  result.results.restart = "pass"
end

local function run_crash(opts, result, workspace, make_client, timeout_ms)
  local callback_count, callback_err, exited = 0, nil, false
  local client = make_client({ on_exit = function() exited = true end })
  start_client(client, timeout_ms)
  result.provider_version = client.agent_info and client.agent_info.version or "unknown"
  result.capabilities = Harness.redact(client.agent_capabilities or {})
  client:send_prompt(fixed_prompt("compute"), function(_, err)
    callback_count = callback_count + 1
    callback_err = err
  end)
  assert(client.prompt_state == "active", "prompt did not enter active state")
  local owned_handle, owned_pid = client.process, client.pid
  assert(owned_handle and owned_pid, "client has no owned process to terminate")
  assert(client.process == owned_handle and client.pid == owned_pid, "owned process identity changed")
  -- Client:stop targets this exact handle with SIGTERM and a bounded SIGKILL fallback.
  client:stop()
  wait_for("owned process exit", timeout_ms, function() return exited end)
  wait_for("prompt process-exit callback", timeout_ms, function() return callback_count > 0 end)
  assert(callback_count == 1, "prompt callback was not completed exactly once")
  assert(callback_err and callback_err.data and callback_err.data.lazyagent
    and callback_err.data.lazyagent.kind == "process_exit", "prompt did not report process_exit")
  result.release = await_release("crashed client resource release", client, timeout_ms)
  result.prompt_callback_count = callback_count
  result.results.crash = "pass"
end

local function run_timeout(opts, result, workspace, make_client, timeout_ms)
  local updates, callback_count, callback_err = 0, 0, nil
  local callback_updates
  local prompt_timeout_ms = tonumber(opts.prompt_timeout_ms) or (opts.provider == "fake" and 30 or 10)
  local client = make_client({
    prompt_timeout_ms = prompt_timeout_ms,
    on_update = function() updates = updates + 1 end,
  })
  start_client(client, timeout_ms)
  result.provider_version = client.agent_info and client.agent_info.version or "unknown"
  result.capabilities = Harness.redact(client.agent_capabilities or {})
  local session_id = client.session_id
  client:send_prompt(fixed_prompt("compute"), function(_, err)
    callback_count = callback_count + 1
    callback_err = err
    callback_updates = updates
  end)
  wait_for("intentional prompt timeout", timeout_ms, function() return callback_count > 0 end)
  assert(callback_count == 1, "timed-out prompt callback was not completed exactly once")
  assert(callback_err and callback_err.data and callback_err.data.lazyagent
    and callback_err.data.lazyagent.kind == "timeout", "prompt did not report timeout")
  assert(client.session_id == session_id, "timeout unexpectedly replaced the session")
  vim.wait(math.min(2000, timeout_ms), function() return updates > callback_updates end, 10)
  local late_updates = updates - callback_updates
  client:cancel()
  vim.wait(math.min(1000, timeout_ms), function() return client.prompt_state == "idle" end, 10)
  result.close = await_close(client, timeout_ms)
  result.release = stop_and_release(client, timeout_ms)
  result.prompt_callback_count = callback_count
  result.prompt_requests = 1
  result.late_update_count = late_updates
  result.results.timeout = "pass"
  result.results.late_update = "pass"
end

local function run_pending_permission(opts, result, workspace, make_client, timeout_ms)
  local permission_count, prompt_done, prompt_callback_count = 0, false, 0
  local client = make_client({
    request_permission = function(_, _)
      permission_count = permission_count + 1
      -- Intentionally retain no callback: Client:cancel owns and releases the pending request.
    end,
  })
  start_client(client, timeout_ms)
  result.provider_version = client.agent_info and client.agent_info.version or "unknown"
  result.capabilities = Harness.redact(client.agent_capabilities or {})
  if opts.provider == "codex" then
    local configured, config_err = false, nil
    client:set_config_option("mode", "read-only", function(_, err)
      config_err, configured = err, true
    end)
    wait_for("Codex read-only permission fixture mode", timeout_ms, function() return configured end)
    if config_err then error(redact_text(config_err.message or config_err)) end
    result.permission_fixture_mode = "read-only"
  end
  client:send_prompt(fixed_prompt("permission"), function()
    prompt_callback_count = prompt_callback_count + 1
    prompt_done = true
  end)
  vim.wait(timeout_ms, function()
    return permission_count > 0 or prompt_done
  end, 10)

  if permission_count == 0 then
    client:cancel()
    vim.wait(math.min(3000, timeout_ms), function() return prompt_done end, 10)
    result.close = await_close(client, timeout_ms)
    result.release = stop_and_release(client, timeout_ms)
    result.permission_requests = 0
    result.results.close_pending_permission = "not-run"
    return
  end

  assert(client:debug_snapshot().pending_permissions == 1, "permission was not pending before cancel")
  assert(client:cancel(), "session cancel was not sent")
  wait_for("pending permission release", timeout_ms, function()
    return client:debug_snapshot().pending_permissions == 0
  end)
  vim.wait(math.min(3000, timeout_ms), function() return prompt_done end, 10)
  result.close = await_close(client, timeout_ms)
  result.release = stop_and_release(client, timeout_ms)
  assert(prompt_callback_count <= 1, "prompt callback completed more than once")
  result.permission_requests = permission_count
  result.prompt_callback_count = prompt_callback_count
  result.results.close_pending_permission = "pass"
end

function M.run(opts)
  opts = opts or {}
  local output = assert(opts.output, "an explicit output path is required")
  local provider, scenario = opts.provider, opts.scenario
  if not provider or provider == "" then
    local result = base_result(nil, scenario, "blocked-by-authorization")
    result.reason = "No provider selected; dry-run did not spawn a process."
    write_result(output, result)
    return result
  end
  assert(providers[provider], "provider is not in the failure-harness allowlist")
  assert(scenarios[scenario], "scenario is not in the failure-harness allowlist")
  if provider ~= "fake" and opts.failure_authorized ~= "I_UNDERSTAND_FAILURE" then
    local result = base_result(provider, scenario, "blocked-by-authorization")
    result.reason = "Explicit failure-lifecycle authorization is missing."
    write_result(output, result)
    return result
  end
  if scenario == "pending-permission-close" and provider ~= "fake"
    and opts.mutation_authorized ~= "I_UNDERSTAND_MUTATION"
  then
    local result = base_result(provider, scenario, "blocked-by-authorization")
    result.reason = "Isolated mutation authorization is missing."
    write_result(output, result)
    return result
  end

  local command = opts.command
  assert(type(command) == "table" and #command > 0, "an argv command is required")
  local workspace = vim.fn.tempname() .. "-lazyagent-e2e-failure"
  assert(vim.fn.mkdir(workspace, "p") == 1)
  local result = base_result(provider, scenario, "not-run")
  local timeout_ms = tonumber(opts.timeout_ms) or 60000
  local clients = {}
  local function make_client(overrides)
    overrides = overrides or {}
    local env = vim.deepcopy(opts.env or {})
    if provider == "fake" and scenario ~= "restart-reopen" then
      env.LAZYAGENT_FAKE_CANCEL_FLOW = "1"
    end
    local handlers = {}
    if overrides.request_permission then handlers.request_permission = overrides.request_permission end
    local client = Client.new({
      command = command,
      cwd = workspace,
      env = env,
      additional_directories = provider == "fake" and opts.additional_directories or { workspace },
      request_timeout_ms = timeout_ms,
      prompt_timeout_ms = overrides.prompt_timeout_ms or timeout_ms,
      handlers = handlers,
      on_update = overrides.on_update,
      on_exit = overrides.on_exit,
    })
    clients[#clients + 1] = client
    return client
  end

  local ok, run_err = xpcall(function()
    if scenario == "restart-reopen" then
      run_restart(opts, result, workspace, make_client, timeout_ms)
    elseif scenario == "owned-process-crash" then
      run_crash(opts, result, workspace, make_client, timeout_ms)
    elseif scenario == "timeout-late-update" then
      run_timeout(opts, result, workspace, make_client, timeout_ms)
    else
      run_pending_permission(opts, result, workspace, make_client, timeout_ms)
    end
    result.status = "pass"
  end, debug.traceback)

  for _, client in ipairs(clients) do
    if client:is_connected() then client:stop() end
    vim.wait(3000, function() return snapshot_is_zero(client:debug_snapshot()) end, 10)
  end
  assert(vim.fn.delete(workspace, "rf") == 0, "failed to remove isolated workspace")
  result.workspace_released = vim.fn.isdirectory(workspace) == 0
  if not ok then
    result.status = "fail"
    result.error = redact_text(run_err)
  end
  write_result(output, result)
  return result
end

M.providers = vim.deepcopy(providers)
M.scenarios = vim.deepcopy(scenarios)

return M
