local M = {}

local STREAMS = {
  agent_message_chunk = { key = "assistant", kind = "assistant" },
  agent_thought_chunk = { key = "thought", kind = "thought" },
  user_message_chunk = { key = "user", kind = "user" },
}

function M.identity(update)
  update = type(update) == "table" and update or {}
  local stream = STREAMS[update.sessionUpdate]
  if not stream then
    return nil
  end
  local message_id = update.messageId
  if message_id ~= nil then
    message_id = tostring(message_id)
    if message_id == "" then
      message_id = nil
    end
  end

  return {
    key = message_id and (stream.key .. ":" .. message_id) or stream.key,
    kind = stream.kind,
    message_id = message_id,
  }
end

return M
