local M = {}

function M.run()
  local Replay = require("lazyagent.acp.replay")
  local records = {
    { direction = "out", message = { id = 1, method = "initialize" } },
    { direction = "in", message = { id = 1, result = { agentCapabilities = { loadSession = true } } } },
    { direction = "out", message = { id = 2, method = "session/new" } },
    { direction = "in", message = { id = 2, result = { sessionId = "session-1" } } },
    { direction = "out", message = { id = 3, method = "session/prompt", params = {
      prompt = { { type = "text", text = "hello" } },
    } } },
    { direction = "in", message = { method = "session/update", params = { update = {
      sessionUpdate = "agent_message_chunk", content = { type = "text", text = "world" },
    } } } },
    { direction = "in", message = { id = 3, result = { stopReason = "end_turn" } } },
  }
  local halfway = Replay.rebuild(records, 5)
  assert(halfway.runtime.status == "busy", "replay intermediate runtime state")
  local replay = Replay.rebuild(records)
  assert(replay.runtime.status == "ready" and replay.runtime.session_id == "session-1", "replay ready state")
  assert(replay.runtime.stop_reason == "end_turn", "replay stop reason")
  local transcript = table.concat(replay.lines, "\n")
  assert(transcript:match("User") and transcript:match("hello") and transcript:match("Assistant") and transcript:match("world"),
    "replay transcript reconstruction")
end

return M
