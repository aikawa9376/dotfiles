local M = {}

local function assert_equal(expected, actual, label)
  if not vim.deep_equal(expected, actual) then
    error(string.format("%s: expected %s, got %s", label, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

function M.run()
  local MessageStream = require("lazyagent.acp.backend.message_stream")
  local first = MessageStream.identity({
    sessionUpdate = "agent_message_chunk",
    messageId = "message-a",
  })
  local same = MessageStream.identity({
    sessionUpdate = "agent_message_chunk",
    messageId = "message-a",
  })
  local second = MessageStream.identity({
    sessionUpdate = "agent_message_chunk",
    messageId = "message-b",
  })
  assert_equal("assistant:message-a", first.key, "assistant message key")
  assert_equal(first.key, same.key, "same message grouped")
  assert_equal("assistant:message-b", second.key, "different message split")
  assert_equal("message-a", first.message_id, "opaque message ID")

  assert_equal("thought:message-a", MessageStream.identity({
    sessionUpdate = "agent_thought_chunk",
    messageId = "message-a",
  }).key, "role separates identical IDs")
  assert_equal("user", MessageStream.identity({
    sessionUpdate = "user_message_chunk",
  }).key, "missing ID fallback")
  assert_equal(nil, MessageStream.identity({ sessionUpdate = "tool_call" }), "non-message update")
end

return M
