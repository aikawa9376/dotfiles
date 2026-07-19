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
    files = { { path = "a.lua" }, { path = "b.lua" } },
    dirty = { { path = "a.lua" } },
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
    final_snapshot = { root = "/repo", files = { { path = "a.lua" } } },
    changes = { { path = "a.lua", operation = "modified" } },
  }))
  assert_equal(Journal.get(journal, turn.turn_id).state, "completed", "completed turn state")
  assert_equal(journal.turns[1].changes[1].operation, "modified", "completed turn changes")
  assert_equal(journal.turns[1].baseline.files, nil, "completed baseline file list compacted")
  assert_equal(journal.turns[1].baseline.file_count, 2, "completed baseline file count retained")
  assert_equal(journal.turns[1].final_snapshot.file_count, 1, "final snapshot file count retained")
  local compacted_again = Journal.compact(journal)
  assert_equal(compacted_again.turns[1].baseline.file_count, 2, "repeated compaction preserves baseline file count")
  assert_equal(compacted_again.turns[1].final_snapshot.file_count, 1, "repeated compaction preserves final file count")
  local recovered_journal, recovered_count = Journal.recover_file_event_changes({ turns = { {
    baseline = { root = "/repo", vcs = { kind = "git", head = "before" } },
    file_events = { {
      relative_path = "/same.lua",
      after_blob = { hash = string.rep("f", 64), size = 5 },
    } },
    changes = {},
  } } }, function(_, path)
    assert_equal(path, "same.lua", "recovered event path normalization")
    return { hash = string.rep("e", 64), size = 5 }
  end)
  assert_equal(recovered_count, 1, "missing change recovered from realtime file event")
  assert_equal(recovered_journal.turns[1].changes[1].operation, "modified", "recovered event classification")
  assert_equal(recovered_journal.turns[1].changes[1].after_blob.hash, string.rep("f", 64), "recovered after blob")
  journal = assert(Journal.decide(journal, turn.turn_id, { 1 }, "kept", "2026-07-15T01:04:00Z"))
  assert_equal(journal.turns[1].changes[1].decision, "kept", "change decision")

  local hunk_journal, hunk_turn = Journal.start({}, "thread-2", {
    captured_at = "2026-07-15T02:00:00Z",
  })
  hunk_journal = assert(Journal.finish(hunk_journal, hunk_turn.turn_id, {
    changes = { { operation = "modified", path = "hunk.lua" } },
  }))
  hunk_journal = assert(Journal.decide_hunk(hunk_journal, hunk_turn.turn_id, 1, {
    { index = 1, before_start = 2, before_count = 1, after_start = 2, after_count = 1 },
  }, 1, "rejected", { hash = string.rep("e", 64) }, "2026-07-15T02:01:00Z"))
  assert_equal(hunk_journal.turns[1].changes[1].hunks[1].decision, "rejected", "hunk decision")
  assert_equal(hunk_journal.turns[1].changes[1].review_blob.hash, string.rep("e", 64), "hunk review blob")

  local missing, err = Journal.record(journal, "missing", "buffer", { path = "/repo/a.lua" })
  assert_equal(missing, nil, "missing turn result")
  assert(tostring(err):match("turn not found"), "missing turn error")
end

return M
