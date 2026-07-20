local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local Conversation = require("lazyagent.acp.backend.conversation").setup({
    diff_utils = {},
    normalize_text = function(value) return tostring(value or ""):gsub("\r\n", "\n") end,
    file_uri = function(path) return path end,
    write_session_transcript = function() end,
    sync_runtime_live_state = function() end,
  })
  local session = {
    pane_id = "summary-test",
    transcript_path = vim.fn.tempname(),
    transcript_has_content = false,
    conversation_timeline = {},
    conversation_timeline_index = {},
    runtime_compaction = { enabled = false },
  }

  Conversation.append_stream_chunk(session, "assistant-1", "Assistant", "完了", { kind = "assistant" })
  Conversation.append_stream_chunk(
    session,
    "assistant-1",
    "Assistant",
    "しました。" .. string.rep("日本語の要約", 30),
    { kind = "assistant" }
  )

  local summary = session.conversation_timeline[1].summary
  assert_equal(summary:sub(1, #"完了しました。"), "完了しました。", "stream summary keeps its first chunk")
  assert_equal(vim.fn.strcharpart(summary, 0, vim.fn.strchars(summary)), summary,
    "stream summary is truncated at a UTF-8 character boundary")
  assert_equal(summary:sub(-#"…"), "…", "long stream summary has an ellipsis")
end

return M
