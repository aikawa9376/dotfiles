local M = {}

local valid_modes = { auto = true, new = true, load = true, resume = true }
local valid_origins = { lazyagent = true, native_import = true, legacy = true }
local valid_history_states = { complete = true, partial = true, missing = true }

local function validation_error(message)
  return nil, { kind = "validation_error", message = message }
end

local function attempt(method, continuity, visible_history, hydration)
  return {
    method = method,
    context_continuity = continuity,
    visible_history = visible_history,
    hydration = hydration == true,
  }
end

local function new_attempt(local_history)
  if local_history then
    return attempt("new", "local_carryover", "local_snapshot", false)
  end
  return attempt("new", "new", "unavailable", false)
end

function M.plan(input)
  input = type(input) == "table" and input or {}
  local mode = input.requested_mode
  local origin = input.origin
  local history_state = input.history_state
  if not valid_modes[mode] then return validation_error("invalid requested_mode: " .. tostring(mode)) end
  if not valid_origins[origin] then return validation_error("invalid origin: " .. tostring(origin)) end
  if not valid_history_states[history_state] then
    return validation_error("invalid history_state: " .. tostring(history_state))
  end

  local session_id = type(input.session_id) == "string" and input.session_id ~= "" and input.session_id or nil
  local capabilities = type(input.capabilities) == "table" and input.capabilities or {}
  local supports_load = capabilities.load == true
  local supports_resume = capabilities.resume == true
  local has_local_history = input.has_local_history == true
  local result = {
    schema_version = 1,
    requested_mode = mode,
    session_id = session_id,
    attempts = {},
    stop_if_exhausted = true,
  }

  if mode == "new" then
    result.attempts[1] = new_attempt(false)
    result.reason = session_id and "explicit_new" or "no_native_session"
    return vim.deepcopy(result)
  end
  if mode == "load" then
    if not session_id then return validation_error("session_id is required for explicit load") end
    if not supports_load then return validation_error("session/load is not supported") end
    result.attempts[1] = attempt("load", "native_load", "native_replay", true)
    result.reason = "explicit_load"
    return vim.deepcopy(result)
  end
  if mode == "resume" then
    if not session_id then return validation_error("session_id is required for explicit resume") end
    if not supports_resume then return validation_error("session/resume is not supported") end
    result.attempts[1] = attempt(
      "resume", "native_resume", has_local_history and "local_snapshot" or "unavailable", false
    )
    result.reason = "explicit_resume"
    return vim.deepcopy(result)
  end

  if not session_id then
    result.attempts[1] = new_attempt(false)
    result.reason = "no_native_session"
    return vim.deepcopy(result)
  end

  if history_state == "complete" then
    if supports_resume then
      result.attempts[#result.attempts + 1] = attempt(
        "resume", "native_resume", has_local_history and "local_snapshot" or "unavailable", false
      )
    end
    if supports_load then
      result.attempts[#result.attempts + 1] = attempt(
        "load", "native_load", has_local_history and "local_snapshot" or "native_replay", true
      )
    end
    if has_local_history then result.attempts[#result.attempts + 1] = new_attempt(true) end
    if supports_resume then
      result.reason = "prefer_local_history"
    elseif supports_load then
      result.reason = "prefer_native_replay"
    elseif has_local_history then
      result.reason = "local_carryover"
    else
      result.reason = "history_unavailable"
    end
    return vim.deepcopy(result)
  end

  if supports_load then
    result.attempts[#result.attempts + 1] = attempt("load", "native_load", "native_replay", true)
  end
  if supports_resume then
    result.attempts[#result.attempts + 1] = attempt(
      "resume", "native_resume", has_local_history and "local_snapshot" or "unavailable", false
    )
  end
  if has_local_history then result.attempts[#result.attempts + 1] = new_attempt(true) end
  if supports_load then
    result.reason = "prefer_native_replay"
  elseif supports_resume then
    result.reason = "resume_without_visible_history"
  elseif has_local_history then
    result.reason = "local_carryover"
  else
    result.reason = "history_unavailable"
  end
  return vim.deepcopy(result)
end

local function structured_kind(err)
  local data = type(err) == "table" and err.data or nil
  local lazyagent = type(data) == "table" and data.lazyagent or nil
  local kind = type(lazyagent) == "table" and lazyagent.kind or nil
  if kind == "timeout" then return "timeout" end
  if kind == "transport" or kind == "process_exit" then return "transport_failed" end
  local provider_kind = type(data) == "table" and (data.kind or (type(data.provider) == "table" and data.provider.kind)) or nil
  if provider_kind == "auth_required" then return "auth_required" end
  if provider_kind == "session_not_found" then return "session_not_found" end
  return nil
end

function M.classify_error(err)
  err = type(err) == "table" and err or {}
  local tagged = structured_kind(err)
  if tagged then return tagged end
  if tonumber(err.code) == -32601 then return "method_unsupported" end
  local message = vim.trim(tostring(err.message or "")):lower()
  if message == "authentication required" or message == "not authenticated" or message == "unauthenticated" then
    return "auth_required"
  end
  if message == "session not found" or message == "unknown session" or message == "no such session" then
    return "session_not_found"
  end
  return "agent_error"
end

local function redact(message)
  message = message:gsub("%c", " "):gsub("%s+", " ")
  message = message:gsub("([Bb][Ee][Aa][Rr][Ee][Rr]%s+)[^%s,;]+", "%1[REDACTED]")
  local keys = {
    "[Tt][Oo][Kk][Ee][Nn]",
    "[Kk][Ee][Yy]",
    "[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]",
    "[Ss][Ee][Cc][Rr][Ee][Tt]",
    "[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]",
    "[Hh][Ee][Aa][Dd][Ee][Rr]",
  }
  for _, key in ipairs(keys) do
    message = message:gsub("(" .. key .. "%s*[:=]%s*)[^%s,;]+", "%1[REDACTED]")
  end
  while #message > 160 do
    message = vim.fn.strcharpart(message, 0, math.max(0, vim.fn.strchars(message) - 1))
  end
  return message
end

function M.sanitize_message(message)
  return redact(tostring(message or ""))
end

function M.bound_trace(attempts)
  local source = type(attempts) == "table" and attempts or {}
  local result = {}
  local first = math.max(1, #source - 7)
  for index = first, #source do
    local item = type(source[index]) == "table" and source[index] or {}
    local bounded = {}
    for _, key in ipairs({ "method", "outcome", "code", "started_at", "finished_at" }) do
      local value = item[key]
      if type(value) == "string" or type(value) == "number" then bounded[key] = value end
    end
    if item.message ~= nil then bounded.message = redact(tostring(item.message)) end
    result[#result + 1] = bounded
  end
  return result
end

function M.infer_history(evidence)
  evidence = type(evidence) == "table" and evidence or {}
  local activation = {
    schema_version = 1,
    origin = "legacy",
    history_state = "missing",
    history_source = "none",
  }
  local diagnostic
  if tonumber(evidence.structured_history_count) and tonumber(evidence.structured_history_count) > 0 then
    activation.history_state = "complete"
    activation.history_source = "local_structured"
  elseif evidence.transcript_has_user == true then
    activation.history_state = "partial"
    activation.history_source = "transcript_only"
  end
  if evidence.structured_history_error ~= nil then
    diagnostic = {
      kind = "structured_history_invalid",
      message = redact(tostring(evidence.structured_history_error)),
    }
  end
  return activation, diagnostic
end

local function normalized_error(err, kind)
  local result = type(err) == "table" and vim.deepcopy(err) or { message = tostring(err or kind) }
  result.kind = kind
  return result
end

local function trace_outcome(kind)
  if kind == "method_unsupported" then return "unsupported" end
  if kind == "session_not_found" then return "session_not_found" end
  if kind == "auth_required" then return "auth_required" end
  if kind == "timeout" or kind == "transport_failed" then return "transport_failed" end
  if kind == "hydration_failed" then return "hydration_failed" end
  return "agent_error"
end

function M.run(client, plan, hooks, callback)
  hooks = type(hooks) == "table" and hooks or {}
  callback = type(callback) == "function" and callback or function() end
  local finished = false
  local trace = {}
  local attempted_auth = false
  local invalidated_session_id = false
  local index = 1
  local last_error

  local function publish_trace()
    local bounded = M.bound_trace(trace)
    if type(hooks.on_trace) == "function" then pcall(hooks.on_trace, vim.deepcopy(bounded)) end
    return bounded
  end

  local function finish(result, err)
    if finished then return end
    finished = true
    local final_err = err and vim.deepcopy(err) or nil
    if final_err and final_err.trace == nil then final_err.trace = M.bound_trace(trace) end
    if final_err and invalidated_session_id then final_err.invalidated_session_id = true end
    callback(result and vim.deepcopy(result) or nil, final_err)
  end

  local function add_trace(method, outcome, err)
    trace[#trace + 1] = {
      method = method,
      outcome = outcome,
      code = type(err) == "table" and err.code or nil,
      message = type(err) == "table" and err.message or nil,
      started_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      finished_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
    return publish_trace()
  end

  if type(client) ~= "table" or type(plan) ~= "table" or type(plan.attempts) ~= "table" then
    finish(nil, { kind = "validation_error", message = "invalid activation runner input" })
    return
  end

  local execute
  local function invoke(attempt, done)
    if attempt.method == "load" and type(client.load_session) == "function" then
      client:load_session(plan.session_id, done)
    elseif attempt.method == "resume" and type(client.resume_session) == "function" then
      client:resume_session(plan.session_id, done)
    elseif attempt.method == "new" and type(client.new_session) == "function" then
      client:new_session(done)
    else
      done(nil, { code = -32601, message = "Activation method is unavailable: " .. tostring(attempt.method) })
    end
  end

  local function after(attempt, result, err, done)
    if type(hooks.after_attempt) ~= "function" then done(); return end
    local kind = err and M.classify_error(err) or nil
    local ok, hook_result, hook_err = pcall(hooks.after_attempt, vim.deepcopy(attempt), vim.deepcopy(result), kind)
    if not ok or hook_result == nil or hook_result == false then
      local failure = {
        kind = "hydration_failed",
        message = M.sanitize_message(ok and hook_err or hook_result),
      }
      add_trace(attempt.method, "hydration_failed", failure)
      finish(nil, failure)
      return
    end
    done()
  end

  local function authenticate(attempt)
    if attempted_auth or type(client.request_authentication) ~= "function" then
      finish(nil, last_error)
      return
    end
    attempted_auth = true
    client:request_authentication(function(result, err)
      if err then
        local kind = M.classify_error(err)
        local normalized = normalized_error(err, kind)
        add_trace("authenticate", trace_outcome(kind), err)
        finish(nil, normalized)
        return
      end
      add_trace("authenticate", "success")
      execute(attempt, true)
    end)
  end

  local function next_local_carryover()
    for candidate = index + 1, #plan.attempts do
      local item = plan.attempts[candidate]
      if item.method == "new" and item.context_continuity == "local_carryover" then
        index = candidate
        return item
      end
    end
    return nil
  end

  execute = function(attempt, _)
    if finished then return end
    if type(hooks.before_attempt) == "function" then
      local ok, allowed, hook_err = pcall(hooks.before_attempt, vim.deepcopy(attempt))
      if not ok or allowed == nil or allowed == false then
        local failure = {
          kind = "hydration_failed",
          message = M.sanitize_message(ok and hook_err or allowed),
        }
        add_trace(attempt.method, "hydration_failed", failure)
        finish(nil, failure)
        return
      end
    end
    invoke(attempt, function(result, err)
      if finished then return end
      if not err then
        add_trace(attempt.method, "success")
        after(attempt, result, nil, function()
          finish({
            attempt = vim.deepcopy(attempt),
            result = vim.deepcopy(result or {}),
            trace = M.bound_trace(trace),
            invalidated_session_id = invalidated_session_id,
          }, nil)
        end)
        return
      end
      local kind = M.classify_error(err)
      last_error = normalized_error(err, kind)
      add_trace(attempt.method, trace_outcome(kind), err)
      after(attempt, nil, err, function()
        if kind == "auth_required" and not attempted_auth then
          authenticate(attempt)
          return
        end
        if kind == "session_not_found" then
          invalidated_session_id = true
          local carryover = next_local_carryover()
          if carryover then
            execute(carryover, false)
            return
          end
          finish(nil, last_error)
          return
        end
        if kind == "method_unsupported" and plan.requested_mode == "auto" then
          index = index + 1
          local candidate = plan.attempts[index]
          if candidate then
            execute(candidate, false)
          else
            finish(nil, last_error)
          end
          return
        end
        finish(nil, last_error)
      end)
    end)
  end

  if #plan.attempts == 0 then
    finish(nil, { kind = "history_unavailable", message = tostring(plan.reason or "activation has no safe attempt") })
    return
  end
  execute(plan.attempts[index], false)
end

return M
