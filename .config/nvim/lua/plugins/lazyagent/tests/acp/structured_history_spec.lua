local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local StructuredHistory = require("lazyagent.acp.structured_history")
  local TurnJournal = require("lazyagent.acp.turn_journal")
  local dir = vim.fn.tempname() .. "-structured-history"
  local path = StructuredHistory.path(dir, "thread-1")
  local conversation = {
    { seq = 1, kind = "system", body = "ready" },
    { seq = 2, kind = "user", body = "first" },
    { seq = 3, kind = "thinking", body_ref = { path = "/tmp/source", start_line = 1, end_line = 1 } },
    { seq = 4, kind = "assistant", body = "answer", created_at = 1785850500 },
    { seq = 5, kind = "user", body = "later" },
  }
  local first = StructuredHistory.turn_record({
    turn_id = "thread-1:1",
    state = "completed",
    conversation_start_seq = 1,
    conversation_end_seq = 4,
    transcript_end_line = 12,
    tools = { { tool_call_id = "tool-1", status = "completed" } },
    changes = { { path = "first.lua", operation = "modified" } },
  }, conversation, function(item)
    return item.body ~= "" and item.body or "resolved reasoning"
  end)
  assert_equal(#first.conversation, 3, "turn conversation slice")
  assert_equal(first.conversation[2].body, "resolved reasoning", "portable referenced body")
  assert_equal(first.conversation[2].body_ref, nil, "portable history removes transcript reference")
  assert_equal(first.conversation[3].created_at, 1785850500, "portable history preserves message timestamp")
  assert(StructuredHistory.append(path, first))
  local second = vim.tbl_extend("force", vim.deepcopy(first), { turn_id = "thread-1:2" })
  assert(StructuredHistory.append(path, second))
  local records = assert(StructuredHistory.read(path))
  assert_equal(#records, 2, "JSONL history records")
  local sliced = assert(StructuredHistory.slice(records, "thread-1:1"))
  assert_equal(#sliced, 1, "structured history slice")
  local copied_path = StructuredHistory.path(dir, "thread-2")
  assert(StructuredHistory.write(copied_path, sliced))
  assert_equal(#assert(StructuredHistory.read(copied_path)), 1, "structured history rewrite")

  local journal = {
    turns = { { turn_id = "thread-1:1" }, { turn_id = "thread-1:2" } },
    next_turn_sequence = 3,
  }
  local journal_slice = assert(TurnJournal.slice(journal, "thread-1:1"))
  assert_equal(#journal_slice.turns, 1, "turn journal slice")
  assert_equal(journal_slice.next_turn_sequence, 2, "sliced journal next sequence")

  local transcript = {
    "─ icon System", " ready", "",
    "─ icon User ─────", " first", "", "─ icon Assistant ─────", " answer", "",
    "─ icon User ─────", " later", "", "─ icon Assistant ─────", " later answer",
  }
  local transcript_slice = StructuredHistory.transcript_slice(transcript, 1)
  assert_equal(transcript_slice[#transcript_slice], " answer", "legacy transcript slice ends before next user")
  assert_equal(#StructuredHistory.transcript_slice(transcript, 1, 5), 5, "explicit transcript boundary")
end

return M
