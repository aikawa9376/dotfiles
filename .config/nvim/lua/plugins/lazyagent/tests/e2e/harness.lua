local M = {}

local providers = { fake = true, codex = true, claude = true, gemini = true, copilot = true }
local scenarios = { ["read-only-smoke"] = true, mutation = true }
local sensitive_keys = { token = true, authorization = true, password = true, secret = true, key = true, headers = true, env = true }

local function redact_text(value)
  local text = tostring(value or ""):gsub("Bearer%s+[^%s,;]+", "Bearer [REDACTED]")
  text = text:gsub("([Tt][Oo][Kk][Ee][Nn]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Kk][Ee][Yy])%s*[:=]%s*[^%s,;]+", "%1=[REDACTED]")
  return text:sub(1, 512)
end

local function redact(value, key)
  if sensitive_keys[tostring(key or ""):lower()] then return "[REDACTED]" end
  if type(value) == "string" then return redact_text(value) end
  if type(value) ~= "table" then return value end
  local result = {}
  for item_key, item in pairs(value) do result[item_key] = redact(item, item_key) end
  return result
end

local function matrix(status)
  local result = {}
  for _, name in ipairs({
    "initialize", "auth", "new", "prompt", "cancel", "close", "list", "load", "resume",
    "native_import", "permission", "elicitation", "filesystem", "terminal", "image_resource",
    "config_option", "mcp_additional_directories", "restart", "crash", "timeout", "late_update",
    "close_pending_permission",
  }) do result[name] = status end
  return result
end

local function write_result(path, result)
  local parent = vim.fn.fnamemodify(path, ":h")
  assert(vim.fn.isdirectory(parent) == 1 or vim.fn.mkdir(parent, "p") == 1)
  assert(vim.fn.writefile({ vim.json.encode(redact(result)) }, path) == 0)
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
    scope = scenario == "mutation" and "mutation" or "read-only",
    status = status,
    capabilities = {},
    results = matrix(status),
    costs = "not-recorded",
    mutations = scenario == "mutation" and "not-run" or "none",
  }
end

local function await_callback(label, timeout_ms, invoke)
  local done, value, callback_err = false, nil, nil
  invoke(function(result, err)
    value, callback_err, done = result, err, true
  end)
  assert(vim.wait(timeout_ms, function() return done end, 10), label .. " timed out")
  if callback_err then error(redact_text(callback_err.message or callback_err)) end
  return value
end

local function first_allow_option(options)
  for _, option in ipairs(options or {}) do
    if option.kind == "allow_once" then return option end
  end
  for _, option in ipairs(options or {}) do
    if tostring(option.kind or ""):match("^allow") then return option end
  end
end

function M.run(opts)
  opts = opts or {}
  local output = assert(opts.output, "an explicit output path is required")
  local provider = opts.provider
  local scenario = opts.scenario or "read-only-smoke"
  if not provider or provider == "" then
    local result = base_result(nil, scenario, "blocked-by-authorization")
    result.reason = "No provider selected; dry-run did not spawn a process."
    write_result(output, result)
    return result
  end
  assert(providers[provider], "provider is not in the explicit allowlist")
  assert(scenarios[scenario], "scenario is not in the explicit allowlist")
  if provider ~= "fake" and opts.authorized ~= "I_UNDERSTAND" then
    local result = base_result(provider, scenario, "blocked-by-authorization")
    result.reason = "Explicit credentialed/network execution authorization is missing."
    write_result(output, result)
    return result
  end
  if scenario == "mutation" and opts.mutation_authorized ~= "I_UNDERSTAND_MUTATION" then
    local result = base_result(provider, scenario, "blocked-by-authorization")
    result.reason = "Mutation authorization is missing."
    write_result(output, result)
    return result
  end

  local command = opts.command
  assert(type(command) == "table" and #command > 0, "an argv command is required for an authorized provider")
  local workspace = vim.fn.tempname() .. "-lazyagent-e2e"
  assert(vim.fn.mkdir(workspace, "p") == 1)
  local result = base_result(provider, scenario, "not-run")
  local Client = require("lazyagent.acp.client")
  local connected, connect_err, exited
  local timeout_ms = tonumber(opts.timeout_ms) or 30000
  local marker_path = workspace .. "/e2e-marker.txt"
  local permission_requests, filesystem_writes, update_count = 0, 0, 0
  local function e2e_path(path)
    path = tostring(path or "")
    if not vim.fs.is_absolute(path) then path = workspace .. "/" .. path end
    return vim.fs.normalize(path)
  end
  local client = Client.new({
    command = command,
    cwd = workspace,
    additional_directories = vim.deepcopy(opts.additional_directories or { workspace }),
    request_timeout_ms = timeout_ms,
    prompt_timeout_ms = timeout_ms,
    handlers = {
      request_permission = function(params, done)
        permission_requests = permission_requests + 1
        local option = first_allow_option(params.options)
        if option then
          done({ outcome = "selected", optionId = option.optionId })
        else
          done({ outcome = "cancelled" })
        end
      end,
      read_text_file = function(params)
        local path = e2e_path(params.path)
        if path ~= marker_path then return nil, { code = -32602, message = "E2E read path is outside the marker allowlist" } end
        local lines = vim.fn.readfile(path)
        return { content = table.concat(lines, "\n") }
      end,
      write_text_file = function(params)
        local path = e2e_path(params.path)
        if path ~= marker_path then return nil, { code = -32602, message = "E2E write path is outside the marker allowlist" } end
        local content = tostring(params.content or "")
        assert(vim.fn.writefile(vim.split(content, "\n", { plain = true }), path) == 0)
        filesystem_writes = filesystem_writes + 1
        return vim.empty_dict()
      end,
    },
    on_update = function() update_count = update_count + 1 end,
    on_exit = function() exited = true end,
  })
  local ok, run_err = xpcall(function()
    client:start(function(active, err, session)
      connected, connect_err = active, err
      if active then result.session = session and { created = session.sessionId ~= nil } or {} end
    end)
    assert(vim.wait(timeout_ms, function() return connected ~= nil or connect_err ~= nil end, 10),
      "provider smoke timed out")
    if connect_err then error(redact_text(connect_err.message or connect_err)) end
    result.provider_version = client.agent_info and client.agent_info.version or "unknown"
    result.capabilities = redact(client.agent_capabilities or {})
    result.results.initialize = "pass"
    result.results.new = "pass"
    result.results.auth = "pass"
    local original_session_id = client.session_id

    if provider ~= "fake" and scenario == "read-only-smoke" then
      await_callback("read-only prompt", timeout_ms, function(done)
        client:send_prompt({ {
          type = "text",
          text = "Reply with exactly LAZYAGENT_E2E_OK. Do not use tools or modify files.",
        } }, done)
      end)
      result.results.prompt = "pass"

      local cancel_done, cancel_err = false, nil
      client:send_prompt({ {
        type = "text",
        text = "Compute the first 200 prime numbers silently, then reply with only the last one.",
      } }, function(_, err)
        cancel_err, cancel_done = err, true
      end)
      vim.schedule(function() client:cancel() end)
      assert(vim.wait(timeout_ms, function() return cancel_done end, 10), "cancel prompt timed out")
      if cancel_err then error(redact_text(cancel_err.message or cancel_err)) end
      result.results.cancel = "pass"

      local listed
      if client:supports_session_list() then
        listed = await_callback("session list", timeout_ms, function(done)
          client:list_sessions({ cwd = workspace }, done)
        end)
        result.results.list = "pass"
      else
        result.results.list = "unsupported"
      end

      if client:supports_session_close() then
        await_callback("pre-reopen close", timeout_ms, function(done) client:close_session(nil, done) end)
        result.results.close = "pass"
      end
      if client:supports_session_load() then
        await_callback("session load", timeout_ms, function(done) client:load_session(original_session_id, done) end)
        result.results.load = "pass"
        result.results.native_import = type(listed) == "table"
          and type(listed.sessions) == "table"
          and #listed.sessions > 0
          and "pass"
          or "not-run"
        if client:supports_session_close() then
          await_callback("post-load close", timeout_ms, function(done) client:close_session(nil, done) end)
        end
      else
        result.results.load = "unsupported"
      end
      if client:supports_session_resume() then
        await_callback("session resume", timeout_ms, function(done) client:resume_session(original_session_id, done) end)
        result.results.resume = "pass"
      else
        result.results.resume = "unsupported"
      end
    elseif provider ~= "fake" and scenario == "mutation" then
      await_callback("mutation prompt", timeout_ms, function(done)
        client:send_prompt({ {
          type = "text",
          text = "Create e2e-marker.txt in the current working directory containing exactly LAZYAGENT_E2E_OK and a trailing newline. Do not use terminal or shell commands and do not modify any other file. Then reply with exactly done.",
        } }, done)
      end)
      result.results.prompt = "pass"
      local marker = table.concat(vim.fn.readfile(marker_path), "\n")
      assert(marker == "LAZYAGENT_E2E_OK", "provider did not create the exact isolated marker")
      result.results.filesystem = "pass"
      result.results.permission = permission_requests > 0 and "pass" or "not-run"
      result.mutations = "isolated-workspace-marker-created"
      result.mutation_source = filesystem_writes > 0 and "acp-fs-write" or "provider-process"
    end

    if client.session_id and client:supports_session_close() then
      await_callback("provider close", timeout_ms, function(done) client:close_session(nil, done) end)
      result.results.close = "pass"
    elseif not client:supports_session_close() then
      result.results.close = "unsupported"
    end
    result.update_count = update_count
    result.status = "pass"
  end, debug.traceback)
  if client:is_connected() then client:stop() end
  vim.wait(3000, function() return exited == true or not client:debug_snapshot().process end, 10)
  vim.fn.delete(workspace, "rf")
  if not ok then
    result.status = "fail"
    result.error = redact_text(run_err)
    if result.results.initialize ~= "pass" then result.results.initialize = "fail" end
  end
  write_result(output, result)
  return result
end

M.redact = redact
M.providers = vim.deepcopy(providers)
M.scenarios = vim.deepcopy(scenarios)

return M
