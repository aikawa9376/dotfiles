local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local Journal = require("lazyagent.acp.turn_journal")
  local journal, turn = Journal.start({}, "thread-1", {
    captured_at = "2026-07-15T01:02:03Z",
    root = "/repo",
  })
  assert_equal(turn.turn_id, "thread-1:1", "turn identity")
  assert_equal(journal.next_turn_sequence, 2, "turn sequence")
  assert_equal(turn.baseline.root, "/repo", "turn baseline")

  journal = assert(Journal.record(journal, turn.turn_id, "tool", {
    tool_call_id = "tool-1",
    status = "in_progress",
    paths = { "a.lua" },
  }))
  journal = assert(Journal.record(journal, turn.turn_id, "tool", {
    tool_call_id = "tool-1",
    status = "completed",
    locations = { { path = "a.lua", line = 9 } },
  }))
  local persisted_turn = journal.turns[1]
  assert_equal(#persisted_turn.tools, 1, "tool updates are upserted")
  assert_equal(persisted_turn.tools[1].status, "completed", "terminal tool status")
  assert_equal(persisted_turn.tools[1].paths, { "a.lua" }, "tool paths survive updates")
  assert_equal(persisted_turn.tools[1].locations[1].line, 9, "tool location")

  journal = assert(Journal.record(journal, turn.turn_id, "file", {
    path = "/repo/a.lua",
    operation = "modified",
    source = "acp_fs",
  }))
  assert_equal(journal.turns[1].file_events[1].operation, "modified", "filesystem event")

  journal = assert(Journal.record(journal, turn.turn_id, "buffer", {
    event = "BufWritePost",
    path = "/repo/a.lua",
    tool_call_id = "tool-1",
  }))
  assert_equal(journal.turns[1].buffer_events[1].tool_call_id, "tool-1", "buffer event tool association")

  journal = assert(Journal.finish(journal, turn.turn_id, {
    state = "completed",
    finished_at = "2026-07-15T01:03:00Z",
    final_snapshot = { root = "/repo" },
    changes = { { path = "a.lua", operation = "modified" } },
  }))
  assert_equal(Journal.get(journal, turn.turn_id).state, "completed", "completed turn state")
  assert_equal(journal.turns[1].changes[1].operation, "modified", "completed turn changes")

  local missing, err = Journal.record(journal, "missing", "buffer", { path = "/repo/a.lua" })
  assert_equal(missing, nil, "missing turn result")
  assert(tostring(err):match("turn not found"), "missing turn error")
end

return M
