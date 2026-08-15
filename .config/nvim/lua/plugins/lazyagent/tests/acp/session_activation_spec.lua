local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function methods(plan)
  return vim.tbl_map(function(attempt) return attempt.method end, plan.attempts)
end

local function base(overrides)
  return vim.tbl_deep_extend("force", {
    requested_mode = "auto",
    origin = "native_import",
    history_state = "missing",
    has_local_history = false,
    capabilities = { load = false, resume = false },
  }, overrides or {})
end

local function assert_plan(Activation, id, input, expected_methods, expected_reason)
  local plan, err = Activation.plan(input)
  assert_equal(err, nil, id .. " planning error")
  assert_equal(methods(plan), expected_methods, id .. " candidate order")
  assert_equal(plan.reason, expected_reason, id .. " reason")
  assert_equal(plan.schema_version, 1, id .. " schema")
  return plan
end

local function test_planner(Activation)
  local plan01 = assert_plan(Activation, "PLAN-01", base({ session_id = vim.NIL }), { "new" }, "no_native_session")
  assert_equal(plan01.attempts[1], {
    method = "new", context_continuity = "new", visible_history = "unavailable", hydration = false,
  }, "PLAN-01 new intent")

  local plan02 = assert_plan(Activation, "PLAN-02", base({
    session_id = "native", capabilities = { load = true, resume = true },
  }), { "load", "resume" }, "prefer_native_replay")
  assert_equal(plan02.attempts[1].hydration, true, "PLAN-02 load hydrates")
  assert_equal(plan02.attempts[1].visible_history, "native_replay", "PLAN-02 load visible history")
  assert_equal(plan02.attempts[2].visible_history, "unavailable", "PLAN-02 resume visible history")

  local plan03 = assert_plan(Activation, "PLAN-03", base({
    session_id = "native", origin = "lazyagent", history_state = "complete", has_local_history = true,
    capabilities = { load = true, resume = true },
  }), { "resume", "load", "new" }, "prefer_local_history")
  assert_equal(plan03.attempts[1].visible_history, "local_snapshot", "PLAN-03 resume uses local display")
  assert_equal(plan03.attempts[3].context_continuity, "local_carryover", "PLAN-03 safe local fallback")

  assert_plan(Activation, "PLAN-04", base({
    session_id = "native", capabilities = { load = true },
  }), { "load" }, "prefer_native_replay")

  local plan05 = assert_plan(Activation, "PLAN-05", base({
    session_id = "native", capabilities = { resume = true },
  }), { "resume" }, "resume_without_visible_history")
  assert_equal(plan05.attempts[1].visible_history, "unavailable", "PLAN-05 history unavailable")

  local plan06 = assert_plan(Activation, "PLAN-06", base({
    session_id = "native", origin = "lazyagent", history_state = "complete", has_local_history = true,
  }), { "new" }, "local_carryover")
  assert_equal(plan06.attempts[1].context_continuity, "local_carryover", "PLAN-06 reconstructed continuity")

  local plan07 = assert_plan(Activation, "PLAN-07", base({ session_id = "native" }), {}, "history_unavailable")
  assert_equal(plan07.stop_if_exhausted, true, "PLAN-07 stops without RPC")

  for _, input in ipairs({
    base({ requested_mode = "load", session_id = vim.NIL, capabilities = { load = true } }),
    base({ requested_mode = "load", session_id = "native", capabilities = { load = false } }),
    base({ requested_mode = "resume", session_id = vim.NIL, capabilities = { resume = true } }),
    base({ requested_mode = "resume", session_id = "native", capabilities = { resume = false } }),
  }) do
    local invalid, err = Activation.plan(input)
    assert_equal(invalid, nil, "PLAN-08 explicit validation has no plan")
    assert(type(err) == "table" and err.kind == "validation_error", "PLAN-08 explicit validation error")
  end

  assert_plan(Activation, "PLAN-09", base({
    session_id = "native", history_state = "partial", has_local_history = true,
    capabilities = { load = true, resume = true },
  }), { "load", "resume", "new" }, "prefer_native_replay")

  for _, input in ipairs({
    base({ requested_mode = "automatic" }),
    base({ origin = "provider" }),
    base({ history_state = "unknown" }),
  }) do
    local invalid, err = Activation.plan(input)
    assert_equal(invalid, nil, "PLAN-10 invalid enum has no plan")
    assert(type(err) == "table" and err.kind == "validation_error", "PLAN-10 invalid enum error")
  end

  local mutable = base({
    session_id = "native", history_state = "complete", has_local_history = true,
    capabilities = { resume = true },
  })
  local copied = assert(Activation.plan(mutable))
  mutable.capabilities.resume = false
  assert_equal(methods(copied), { "resume", "new" }, "planner result does not share input references")
end

local function test_errors(Activation)
  assert_equal(Activation.classify_error({ code = -32601, message = "anything" }), "method_unsupported", "ERROR-01")
  assert_equal(Activation.classify_error({
    code = -32000, message = "Authentication required", data = { lazyagent = { kind = "timeout" } },
  }), "timeout", "ERROR-02 tagged timeout wins")
  for _, message in ipairs({ "Authentication required", "Not authenticated", "Unauthenticated" }) do
    assert_equal(Activation.classify_error({ code = -32000, message = message }), "auth_required", "ERROR-03 " .. message)
  end
  for _, message in ipairs({ "Session not found", "Unknown session", "No such session" }) do
    assert_equal(Activation.classify_error({ code = -32000, message = message }), "session_not_found", "ERROR-04 " .. message)
  end
  for _, err in ipairs({
    { code = -32000, message = "session failed" },
    { code = -32000, message = "arbitrary provider failure" },
    { code = -32042, message = "Authentication required later" },
  }) do
    assert_equal(Activation.classify_error(err), "agent_error", "ERROR-05 conservative classification")
  end
  assert_equal(Activation.classify_error({ data = { lazyagent = { kind = "process_exit" } } }),
    "transport_failed", "tagged process exit")
end

local function test_trace(Activation)
  local attempts = {}
  for index = 1, 10 do
    attempts[index] = {
      method = "load", outcome = "agent_error", code = -32000,
      message = "token=secret-" .. index .. "\nAuthorization: Bearer hidden password=hunter2 " .. string.rep("x", 220),
      started_at = "start-" .. index, finished_at = "finish-" .. index,
      prompt = "must not persist", headers = { Authorization = "secret" },
    }
  end
  local bounded = Activation.bound_trace(attempts)
  assert_equal(#bounded, 8, "trace keeps latest eight attempts")
  assert_equal(bounded[1].started_at, "start-3", "trace drops oldest attempts")
  assert_equal(bounded[1].prompt, nil, "trace drops prompt payload")
  assert_equal(bounded[1].headers, nil, "trace drops header payload")
  assert(#bounded[1].message <= 160, "trace message is bounded to 160 bytes")
  assert(not bounded[1].message:find("secret", 1, true), "trace redacts token values")
  assert(not bounded[1].message:find("hunter2", 1, true), "trace redacts password values")
  assert(not bounded[1].message:find("hidden", 1, true), "trace redacts bearer values")
  assert(not bounded[1].message:find("\n", 1, true), "trace removes control characters")
  attempts[3].message = "mutated"
  assert(not bounded[1].message:find("mutated", 1, true), "trace does not share mutable input")
end

local function test_history_inference(Activation)
  local complete, complete_diagnostic = Activation.infer_history({ structured_history_count = 2 })
  assert_equal(complete, {
    schema_version = 1,
    origin = "legacy",
    history_state = "complete",
    history_source = "local_structured",
  }, "META-02 valid structured history is complete")
  assert_equal(complete_diagnostic, nil, "META-02 complete diagnostic")

  local partial = assert(Activation.infer_history({ transcript_has_user = true }))
  assert_equal(partial.history_state, "partial", "META-03 User transcript is partial")
  assert_equal(partial.history_source, "transcript_only", "META-03 transcript source")

  local missing = assert(Activation.infer_history({
    title = "Provider title", native_summary = "Summary", native_session_id = "native", has_user_prompt = true,
  }))
  assert_equal(missing.history_state, "missing", "META-04 summary and identity do not imply history")
  assert_equal(missing.history_source, "none", "META-04 missing history source")

  local corrupt, diagnostic = Activation.infer_history({
    structured_history_error = "invalid structured history at line 1",
  })
  assert_equal(corrupt.history_state, "missing", "META-05 corrupt structured history is not complete")
  assert(type(diagnostic) == "table" and diagnostic.kind == "structured_history_invalid",
    "META-05 corrupt structured history diagnostic")
end

local function stub_client(responses)
  local client = { calls = {}, auth_calls = 0 }
  local positions = {}
  local function invoke(method, callback)
    client.calls[#client.calls + 1] = method
    positions[method] = (positions[method] or 0) + 1
    local response = responses[method] and responses[method][positions[method]] or { result = { sessionId = method } }
    callback(response.result, response.err)
  end
  client.load_session = function(_, _, callback) invoke("load", callback) end
  client.resume_session = function(_, _, callback) invoke("resume", callback) end
  client.new_session = function(_, callback) invoke("new", callback) end
  client.request_authentication = function(_, callback)
    client.auth_calls = client.auth_calls + 1
    invoke("authenticate", callback)
  end
  return client
end

local function run_activation(Activation, client, plan, hooks)
  local calls, result, err = 0
  Activation.run(client, plan, hooks or {}, function(value, run_err)
    calls = calls + 1
    result, err = value, run_err
  end)
  assert_equal(calls, 1, "runner callback fires exactly once")
  return result, err
end

local function test_runner(Activation)
  local success_plan = assert(Activation.plan(base({
    session_id = "native", capabilities = { load = true },
  })))
  local first = stub_client({ load = { { result = { sessionId = "native" } } } })
  local result01, err01 = run_activation(Activation, first, success_plan)
  assert_equal(err01, nil, "RUN-01 success error")
  assert_equal(first.calls, { "load" }, "RUN-01 attempt order")
  assert_equal(result01.trace[1].outcome, "success", "RUN-01 success trace")

  local auth = { code = -32000, message = "Authentication required" }
  local second = stub_client({
    load = { { err = auth }, { result = { sessionId = "native" } } },
    authenticate = { { result = {} } },
  })
  local result02, err02 = run_activation(Activation, second, success_plan)
  assert_equal(err02, nil, "RUN-02 auth retry error")
  assert_equal(second.calls, { "load", "authenticate", "load" }, "RUN-02 retries same method")
  assert_equal(second.auth_calls, 1, "RUN-02 authenticates once")
  assert_equal(vim.tbl_map(function(item) return item.outcome end, result02.trace),
    { "auth_required", "success", "success" }, "RUN-02 ordered trace")

  local third = stub_client({
    load = { { err = auth }, { err = auth } },
    authenticate = { { result = {} } },
  })
  local result03, err03 = run_activation(Activation, third, success_plan)
  assert_equal(result03, nil, "RUN-03 repeated auth result")
  assert_equal(err03.kind, "auth_required", "RUN-03 repeated auth stops")
  assert_equal(third.auth_calls, 1, "RUN-03 does not authenticate twice")

  local fallback_plan = assert(Activation.plan(base({
    session_id = "native", capabilities = { load = true, resume = true },
  })))
  local discarded = 0
  local fourth = stub_client({
    load = { { err = { code = -32601, message = "Method not found: session/load" } } },
    resume = { { result = { sessionId = "native" } } },
  })
  local result04, err04 = run_activation(Activation, fourth, fallback_plan, {
    after_attempt = function(attempt, _, normalized)
      if attempt.method == "load" and normalized == "method_unsupported" then discarded = discarded + 1 end
      return true
    end,
  })
  assert_equal(err04, nil, "RUN-04 fallback error")
  assert_equal(fourth.calls, { "load", "resume" }, "RUN-04 method fallback")
  assert_equal(discarded, 1, "RUN-04 failed load hook discards collector")
  assert_equal(vim.tbl_map(function(item) return item.outcome end, result04.trace),
    { "unsupported", "success" }, "RUN-04 ordered trace")

  local explicit = assert(Activation.plan(base({
    requested_mode = "load", session_id = "native", capabilities = { load = true, resume = true },
  })))
  local fifth = stub_client({ load = { { err = { code = -32601, message = "Method not found: session/load" } } } })
  local result05, err05 = run_activation(Activation, fifth, explicit)
  assert_equal(result05, nil, "RUN-05 explicit unsupported result")
  assert_equal(err05.kind, "method_unsupported", "RUN-05 explicit unsupported stops")
  assert_equal(fifth.calls, { "load" }, "RUN-05 explicit has no fallback")

  local local_plan = assert(Activation.plan(base({
    session_id = "native", origin = "lazyagent", history_state = "complete", has_local_history = true,
    capabilities = { load = true, resume = true },
  })))
  local sixth = stub_client({
    resume = { { err = { code = -32000, message = "Session not found" } } },
    new = { { result = { sessionId = "replacement" } } },
  })
  local result06, err06 = run_activation(Activation, sixth, local_plan)
  assert_equal(err06, nil, "RUN-06 local recovery error")
  assert_equal(sixth.calls, { "resume", "new" }, "RUN-06 skips remaining native attempts")
  assert_equal(result06.invalidated_session_id, true, "RUN-06 invalidates missing native identity")

  local seventh = stub_client({
    load = { { err = { code = -32000, message = "Session not found" } } },
  })
  local result07, err07 = run_activation(Activation, seventh, fallback_plan)
  assert_equal(result07, nil, "RUN-07 missing history result")
  assert_equal(err07.kind, "session_not_found", "RUN-07 missing history stops")
  assert_equal(seventh.calls, { "load" }, "RUN-07 does not start empty session")

  for id, internal_kind in pairs({ ["RUN-08"] = "timeout", ["RUN-09"] = "process_exit" }) do
    local transport = stub_client({ load = { { err = {
      code = -32000, message = id, data = { lazyagent = { kind = internal_kind } },
    } } } })
    local stopped, stop_err = run_activation(Activation, transport, fallback_plan)
    assert_equal(stopped, nil, id .. " result")
    assert_equal(transport.calls, { "load" }, id .. " no fallback")
    assert(stop_err.kind == "timeout" or stop_err.kind == "transport_failed", id .. " classified stop")
  end

  local tenth = stub_client({ load = { { result = { sessionId = "native" } } } })
  local result10, err10 = run_activation(Activation, tenth, success_plan, {
    after_attempt = function() return nil, "publication failed" end,
  })
  assert_equal(result10, nil, "RUN-10 hook failure result")
  assert_equal(err10.kind, "hydration_failed", "RUN-10 hook failure is fatal")
  assert_equal(tenth.calls, { "load" }, "RUN-10 hook failure has no fallback")

  local many_attempts = { schema_version = 1, requested_mode = "auto", attempts = {}, stop_if_exhausted = true }
  local responses = { load = {} }
  for index = 1, 10 do
    many_attempts.attempts[index] = {
      method = "load", context_continuity = "native_load", visible_history = "native_replay", hydration = true,
    }
    responses.load[index] = {
      err = { code = -32601, message = "token=secret-" .. index .. " " .. string.rep("x", 200) },
    }
  end
  local traces
  local twelfth = stub_client(responses)
  local result12, err12 = run_activation(Activation, twelfth, many_attempts, {
    on_trace = function(trace) traces = trace end,
  })
  assert_equal(result12, nil, "RUN-12 exhausted result")
  assert(err12 ~= nil, "RUN-12 exhausted error")
  assert_equal(#traces, 8, "RUN-12 bounded trace")
  assert(not traces[1].message:find("secret", 1, true), "RUN-12 redacted trace")
  assert(#traces[1].message <= 160, "RUN-12 truncated trace")
end

function M.run()
  local Activation = require("lazyagent.acp.session_activation")
  test_planner(Activation)
  test_errors(Activation)
  test_trace(Activation)
  test_history_inference(Activation)
  test_runner(Activation)
end

return M
