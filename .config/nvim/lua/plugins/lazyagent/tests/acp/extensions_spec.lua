local M = {}

local function assert_equal(expected, actual, label)
  if not vim.deep_equal(expected, actual) then
    error(string.format("%s: expected %s, got %s", label, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local function test_cursor_translation()
  local Extensions = require("lazyagent.acp.extensions")
  local request = {
    toolCallId = "ask-1",
    title = "Choose",
    questions = {
      { id = "mode", prompt = "Mode?", options = { { id = "a", label = "Agent" }, { id = "p", label = "Plan" } } },
      { id = "checks", prompt = "Checks?", allowMultiple = true, options = { { id = "test", label = "Tests" } } },
    },
  }
  local elicitation = Extensions.cursor_question_as_elicitation(request)
  assert_equal("Choose", elicitation.message, "cursor question title")
  assert_equal("a", elicitation.requestedSchema.properties.mode.oneOf[1].const, "cursor scalar option id")
  assert_equal("array", elicitation.requestedSchema.properties.checks.type, "cursor multiple choice")

  local response = Extensions.cursor_question_response(request, {
    action = "accept",
    content = { mode = "p", checks = { "test" } },
  })
  assert_equal("answered", response.outcome.outcome, "cursor answered outcome")
  assert_equal({ "p" }, response.outcome.answers[1].selectedOptionIds, "cursor selected ids")
  assert_equal("cancelled", Extensions.cursor_question_response(request, { action = "cancel" }).outcome.outcome,
    "cursor cancelled outcome")

  local plan = Extensions.cursor_notification("cursor/update_todos", {
    toolCallId = "todo-1",
    merge = true,
    todos = { { id = "1", content = "Ship", status = "in_progress" } },
  })
  assert_equal("plan", plan.sessionUpdate, "cursor todos normalize to plan")
  assert_equal(true, plan._meta.lazyagent.merge, "cursor todo merge")
  assert_equal("subagent_task", Extensions.cursor_notification("cursor/task", {
    toolCallId = "task-1", description = "Explore", agentId = "agent-1",
  }).sessionUpdate, "cursor task normalization")
  assert_equal("generated_image", Extensions.cursor_notification("cursor/generate_image", {
    toolCallId = "image-1", filePath = "/tmp/image.png",
  }).sessionUpdate, "cursor image normalization")
end

local function test_client_extension_contract()
  local Client = require("lazyagent.acp.client")
  local updates, notifications, responses = {}, {}, {}
  local client = Client.new({
    handlers = {
      extension_request = function(method, params, done)
        if method ~= "cursor/create_plan" then return false end
        done({ outcome = { outcome = "accepted" } })
        return true
      end,
      extension_notification = function(method, params)
        notifications[#notifications + 1] = { method = method, params = params }
        return method == "cursor/task"
      end,
    },
    on_update = function(params) updates[#updates + 1] = params end,
  })
  assert_equal("table", type(client.client_capabilities.plan), "plan capability")
  assert_equal("table", type(client.client_capabilities.subagents), "subagent capability")
  assert_equal({ "nativeSubagentSessions", "asyncTasks", "sessionFailure" },
    client.client_capabilities._meta.jetbrains.air.capabilities, "AIR extension capabilities")
  client.session_id = "root"
  client:_handle_update({ sessionId = "root", update = {
    sessionUpdate = "subagent_spawned", subagentSessionId = "child", name = "Explore", task = "Find files", capabilities = {},
  } })
  client:_handle_update({ sessionId = "child", update = {
    sessionUpdate = "agent_message_chunk", content = { type = "text", text = "found" },
  } })
  client:_handle_update({ sessionId = "stranger", update = {
    sessionUpdate = "agent_message_chunk", content = { type = "text", text = "drop" },
  } })
  client:_handle_update({ sessionId = "root", update = { sessionUpdate = "plan_removed", planId = "plan-1" } })
  client:_handle_update({ sessionId = "root", update = {
    sessionUpdate = "compaction_summary_chunk", compactionId = "compact-1", content = { type = "text", text = "summary" },
  } })
  client:_handle_update({ sessionId = "root", update = {
    sessionUpdate = "compaction_update", compactionId = "compact-1", status = "completed",
  } })
  vim.wait(1000, function() return #updates == 5 end, 10)
  assert_equal(5, #updates, "root, negotiated child, plan removal, and compaction updates only")
  assert_equal("child", updates[2].sessionId, "child update identity")

  client._send_result = function(_, id, result) responses[#responses + 1] = { id = id, result = result } end
  client:_handle_server_request(9, "cursor/create_plan", { toolCallId = "plan-1" })
  assert_equal("accepted", responses[1].result.outcome.outcome, "extension request response")
  client:_handle_message(vim.json.encode({ jsonrpc = "2.0", method = "cursor/task", params = { toolCallId = "task-1" } }))
  assert_equal("cursor/task", notifications[1].method, "extension notification dispatch")

  client.process = true
  client.state = "ready"
  client.agent_meta = { goal = { controlMethod = "_session/goal", actions = { "set", "clear" } } }
  local sent
  client._send_request = function(_, method, params) sent = { method = method, params = params } end
  client:control_goal("set", "Ship it", function() end)
  assert_equal("_session/goal", sent.method, "goal control method")
  assert_equal("Ship it", sent.params.objective, "goal objective")
  assert_equal(false, client:supports_goal("pause"), "unadvertised goal action")
end

function M.run()
  test_cursor_translation()
  test_client_extension_contract()
end

return M
