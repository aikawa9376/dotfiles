local M = {}

local function assert_equal(expected, actual, label)
  if not vim.deep_equal(expected, actual) then
    error(string.format("%s: expected %s, got %s", label, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

function M.run()
  local Elicitation = require("lazyagent.acp.elicitation")

  assert_equal({
    action = "accept",
    content = { persist = "once" },
  }, Elicitation.auto_approve_mcp({
    mode = "form",
    message = 'Allow the lazyagent MCP server to run tool "team_report"?',
    requestedSchema = {
      type = "object",
      properties = {
        persist = {
          type = "string",
          oneOf = {
            { const = "once", title = "Allow once" },
            { const = "session", title = "Allow for this session" },
          },
        },
      },
    },
    _meta = { codex_approval_kind = "mcp_tool_call" },
  }, { lazyagent = true }), "trusted MCP approval")
  assert_equal(nil, Elicitation.auto_approve_mcp({
    message = 'Allow the external MCP server to run tool "publish"?',
    _meta = { codex_approval_kind = "mcp_tool_call" },
  }, { lazyagent = true }), "untrusted MCP remains interactive")
  assert_equal(nil, Elicitation.auto_approve_mcp({
    message = 'Allow the lazyagent MCP server to run tool "team_report"?',
  }, { lazyagent = true }), "ordinary elicitation is not mistaken for MCP approval")
  assert_equal({
    action = "accept",
    content = vim.empty_dict(),
  }, Elicitation.auto_approve_team_mcp({
    message = 'Allow the lazyagent MCP server to run tool "team_report"?',
    _meta = { codex_approval_kind = "mcp_tool_call" },
  }, {
    agent_cfg = { lazyagent_team = { role_id = "reviewer" } },
  }, { lazyagent = true }), "backend-shaped team session trusts its configured MCP server")
  assert_equal(nil, Elicitation.auto_approve_team_mcp({
    message = 'Allow the lazyagent MCP server to run tool "team_report"?',
    _meta = { codex_approval_kind = "mcp_tool_call" },
  }, {
    agent_cfg = {},
  }, { lazyagent = true }), "ordinary ACP session does not inherit team MCP trust")

  local autonomous
  Elicitation.handle({
    mode = "form",
    message = "Choose",
    requestedSchema = vim.empty_dict(),
  }, { question_policy = "autonomous" }, function(result)
    autonomous = result
  end)
  assert_equal({ action = "decline" }, autonomous, "autonomous policy")

  local selected_prompts = {}
  local selected_opts = {}
  local selected_displays = {}
  local response
  Elicitation.handle({
    mode = "form",
    message = "Configure implementation",
    requestedSchema = {
      type = "object",
      properties = {
        count = { type = "integer", title = "Retries", minimum = 1 },
        strategy = {
          type = "string",
          title = "Strategy",
          oneOf = {
            { const = "safe", title = "Safe", description = "Prefer compatibility and validation." },
            { const = "fast", title = "Fast", description = "Prefer the shortest implementation." },
          },
        },
      },
      required = { "strategy", "count" },
    },
  }, { question_policy = "prompt" }, function(result)
    response = result
  end, {
    select = function(items, opts, callback)
      selected_prompts[#selected_prompts + 1] = opts.prompt
      selected_opts[#selected_opts + 1] = opts
      selected_displays[#selected_displays + 1] = opts.format_item(items[1])
      callback(items[1])
    end,
    input = function(_, callback)
      callback("3")
    end,
    notify = function() end,
  })
  assert_equal({
    action = "accept",
    content = { count = 3, strategy = "safe" },
  }, response, "form response")
  assert_equal({ "Strategy (required)" }, selected_prompts, "enum picker")
  assert_equal("lazyagent-acp-elicitation", selected_opts[1].kind, "elicitation picker kind")
  assert_equal(2, selected_opts[1].multiline, "elicitation picker enables multiline entries")
  assert_equal(true, selected_opts[1].fzf_opts["--wrap"], "elicitation picker wraps long lines")
  assert_equal(0.6, selected_opts[1].winopts.width, "elicitation picker uses scratch-like width")
  assert_equal(0.3, selected_opts[1].winopts.height, "elicitation picker uses scratch-like height")
  assert(selected_displays[1]:find("\n", 1, true), "choice description is displayed on another line")

  local described_request = Elicitation.describe_request({
    mode = "form",
    message = "Choose an implementation strategy",
    requestedSchema = {
      type = "object",
      properties = {
        strategy = {
          type = "string", title = "Strategy",
          oneOf = {
            { const = "safe", title = "Safe", description = "Prefer compatibility." },
            { const = "fast", title = "Fast" },
          },
        },
      },
      required = { "strategy" },
    },
  })
  assert(described_request:find("Choose an implementation strategy", 1, true), "transcript request includes message")
  assert(described_request:find("- Strategy (required)", 1, true), "transcript request includes question")
  assert(described_request:find("Safe — Prefer compatibility.", 1, true), "transcript request includes choices")
  local described_response = Elicitation.describe_response({
    message = "Choose an implementation strategy",
    requestedSchema = {
      type = "object",
      properties = { strategy = {
        type = "string", title = "Strategy",
        oneOf = { { const = "safe", title = "Safe" } },
      } },
    },
  }, { action = "accept", content = { strategy = "safe" } })
  assert(described_response:find("Action: accept", 1, true), "transcript answer includes action")
  assert(described_response:find("- Strategy: Safe", 1, true), "transcript answer includes selected label")

  local other_response
  Elicitation.handle({
    mode = "form",
    requestedSchema = {
      type = "object",
      properties = {
        approach = {
          type = "string",
          oneOf = { { const = "A", title = "Approach A" } },
        },
        approach__other = {
          type = "string",
          _meta = { codex = { isOtherAnswer = true, questionId = "approach" } },
        },
      },
    },
  }, {}, function(result)
    other_response = result
  end, {
    select = function(items, _, callback) callback(items[#items]) end,
    input = function(_, callback) callback("Custom") end,
    notify = function() end,
  })
  assert_equal({
    action = "accept",
    content = { approach__other = "Custom" },
  }, other_response, "Codex Other answer")

  local cancelled
  Elicitation.handle({
    mode = "form",
    requestedSchema = {
      type = "object",
      properties = { name = { type = "string" } },
    },
  }, {}, function(result)
    cancelled = result
  end, {
    input = function(_, callback) callback(nil) end,
    select = function() end,
    notify = function() end,
  })
  assert_equal({ action = "cancel" }, cancelled, "cancelled input")

  local Client = require("lazyagent.acp.client")
  local writes = {}
  local deferred_done
  local client = Client.new({
    handlers = {
      elicitation = function(params, done)
        assert_equal("Choose", params.message, "wire elicitation request")
        deferred_done = done
      end,
    },
  })
  client.stdin = {
    is_closing = function() return false end,
    write = function(_, payload) writes[#writes + 1] = payload end,
  }
  client.session_id = "session-1"
  client:_handle_message(vim.json.encode({
    jsonrpc = "2.0",
    id = 42,
    method = "elicitation/create",
    params = {
      sessionId = "session-1",
      mode = "form",
      message = "Choose",
      requestedSchema = { type = "object", properties = {} },
    },
  }))
  assert(vim.wait(100, function() return deferred_done ~= nil end, 5), "elicitation handler scheduled")
  deferred_done({ action = "accept", content = { answer = "A" } })
  assert(vim.wait(100, function() return #writes == 1 end, 5), "elicitation response written")
  local wire_response = vim.json.decode(writes[1])
  assert_equal("accept", wire_response.result.action, "wire elicitation response")

  writes = {}
  deferred_done = nil
  client:_handle_message(vim.json.encode({
    jsonrpc = "2.0",
    id = 43,
    method = "elicitation/create",
    params = {
      sessionId = "session-1",
      mode = "form",
      message = "Choose",
      requestedSchema = { type = "object", properties = {} },
    },
  }))
  assert(vim.wait(100, function() return deferred_done ~= nil end, 5), "cancelled elicitation scheduled")
  client:_handle_message(vim.json.encode({
    jsonrpc = "2.0",
    method = "$/cancel_request",
    params = { requestId = 43 },
  }))
  assert_equal(0, vim.tbl_count(client.pending_elicitation_requests), "cancel clears pending elicitation")
  deferred_done({ action = "accept", content = { answer = "late" } })
  assert_equal(0, #writes, "late elicitation response ignored")
end

return M
