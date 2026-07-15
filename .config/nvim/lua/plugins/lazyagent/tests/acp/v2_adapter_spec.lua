local M = {}

function M.run()
  local Adapter = require("lazyagent.acp.v2_adapter")
  local adapter = Adapter.new({ enabled = true })

  local method, initialize = adapter:outbound("initialize", {
    protocolVersion = 1,
    clientCapabilities = { fs = { readTextFile = true } },
    clientInfo = { name = "lazyagent", version = "0.1.0" },
  })
  assert(method == "initialize" and initialize.protocolVersion == 2, "v2 initialize version")
  assert(initialize.info.name == "lazyagent" and initialize.clientCapabilities == nil, "v2 initialize shape")

  local result = adapter:initialize_result({
    protocolVersion = 2,
    capabilities = {
      session = {
        resume = {}, close = {}, additionalDirectories = {},
        mcp = { stdio = {}, http = {} },
      },
      auth = {},
    },
    info = { name = "v2-agent" },
  })
  assert(result.protocolVersion == 1 and result.agentInfo.name == "v2-agent", "v2 result normalized")
  assert(result.agentCapabilities.sessionCapabilities.resume ~= nil, "v2 resume capability")
  assert(result.agentCapabilities.loadSession == false, "removed v2 load is not advertised")
  assert(result.agentCapabilities.mcpCapabilities.http == true, "v2 HTTP MCP capability")

  method, initialize = adapter:outbound("session/new", {
    mcpServers = {
      { name = "stdio", command = "server" },
      { name = "http", type = "http", url = "http://localhost" },
      { name = "legacy", type = "sse", url = "http://localhost/sse" },
    },
  })
  assert(method == "session/new" and #initialize.mcpServers == 2, "v2 omits removed SSE MCP")
  assert(initialize.mcpServers[1].type == "stdio", "v2 MCP transport is explicit")

  local updates, loss = adapter:updates({
    sessionId = "session-1",
    update = {
      sessionUpdate = "agent_message",
      messageId = "message-1",
      content = {
        { type = "text", text = "hello" },
        { type = "text", text = " world" },
      },
    },
  })
  assert(loss == nil and #updates == 2, "v2 whole message fans out into v1 chunks")
  assert(updates[1].update.sessionUpdate == "agent_message_chunk", "v2 message variant normalized")

  updates, loss = adapter:updates({
    sessionId = "session-1",
    update = {
      sessionUpdate = "agent_message",
      messageId = "message-1",
      content = { { type = "text", text = "replacement" } },
    },
  })
  assert(#updates == 1 and loss:match("replacement"), "lossy whole-message replacement is reported")

  updates = adapter:updates({
    sessionId = "session-1",
    update = {
      sessionUpdate = "tool_call_update",
      toolCallId = "tool-1",
      content = { { type = "text", text = "first" } },
    },
  })
  updates = adapter:updates({
    sessionId = "session-1",
    update = {
      sessionUpdate = "tool_call_content_chunk",
      toolCallId = "tool-1",
      content = { type = "text", text = "second" },
    },
  })
  assert(#updates == 1 and #updates[1].update.content == 2, "v2 tool content chunks accumulate")
  assert(updates[1].update.sessionUpdate == "tool_call_update", "v2 tool chunk normalized")

  local permission = adapter:permission_params({
    title = "Allow shell command?",
    subject = {
      type = "tool_call",
      toolCall = { toolCallId = "tool-1", kind = "execute" },
    },
  }, 7)
  assert(permission.subject == nil and permission.toolCall.toolCallId == "tool-1", "v2 permission subject normalized")
  assert(permission.toolCall.title == "Allow shell command?", "v2 permission title preserved")

  method = adapter:outbound("authenticate", { methodId = "oauth" })
  assert(method == "auth/login", "v2 login method")
  method = adapter:outbound("logout", {})
  assert(method == "auth/logout", "v2 logout method")

  local disabled = Adapter.new({ enabled = false })
  method, initialize = disabled:outbound("initialize", { protocolVersion = 1 })
  assert(method == "initialize" and initialize.protocolVersion == 1, "adapter is off by default")
end

return M
