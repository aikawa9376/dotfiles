local M = {}

function M.run()
  local Review = require("lazyagent.acp.cockpit_review")
  local thread = {
    thread_id = "review-thread", title = "Review fixture", status = "closed", cwd = "/tmp/review",
    metadata = {}, change_journal = { turns = { {
      turn_id = "turn-1", state = "active", tools = { { id = "tool-1" } },
      changes = { { path = "source.lua", operation = "modified", before_blob = { hash = "old" }, after_blob = { hash = "one" } } },
    } } },
  }
  assert(not Review.since(thread).established, "history is not implicitly checked")
  assert(not Review.enabled(thread) and Review.summary(thread).state == "off", "review tracking defaults off")
  thread.metadata.cockpit_review = { state = "reviewing", thread_id = thread.thread_id }
  assert(Review.summary(thread).state == "off", "legacy automatic review states do not enable tracking")
  thread.metadata.cockpit_observation = Review.snapshot(thread)
  assert(not Review.since(thread).changed, "explicit checkpoint starts with no delta")
  local turn = thread.change_journal.turns[1]
  turn.state = "completed"
  turn.tools[2] = { id = "tool-2" }
  turn.file_events = { { relative_path = "source.lua" } }
  local delta = Review.since(thread)
  assert(delta.new_turns == 0 and delta.completed_turns == 1 and delta.tool_events == 1 and delta.file_events == 1,
    "active-to-completed transition and incremental events are counted once")
  local baseline_revision = Review.code_revision(thread)
  turn.changes[1].decision = "kept"
  assert(Review.code_revision(thread) == baseline_revision, "approval bookkeeping does not change code identity")
  thread.metadata.cockpit_review = { enabled = true, state = "done", thread_id = thread.thread_id, revision = baseline_revision, fingerprint = "workspace" }
  assert(Review.summary(thread, { fingerprint = "workspace" }).state == "done", "matching review basis is done")
  assert(Review.summary(thread).state == "unverified", "unverified workspace cannot claim review freshness")
  assert(Review.summary(thread, { fingerprint_pending = true }).state == "checking", "pending verification is explicit")
  assert(Review.summary(thread, { fingerprint = "edited" }).state == "needs_review", "out-of-journal edits require review")
  assert(Review.summary(thread, { fingerprint = "workspace", busy = true }).state == "needs_review", "active work cannot look settled")
  local version = Review.version(thread)
  thread.metadata.cockpit_review.enabled = false
  assert(Review.version(thread) ~= version and Review.summary(thread).state == "off", "disable invalidates a pending review confirmation")
  thread.metadata.cockpit_review.enabled = true
  thread.unread, thread.metadata.cockpit_ack_completion, thread.metadata.cockpit_pinned = true, "seen", true
  assert(Review.version(thread) == version, "read, pin and completion acknowledgement do not change review version")
  turn.changes[1].after_blob.hash = "two"
  assert(Review.summary(thread, { fingerprint = "workspace" }).state == "needs_review", "journal edits invalidate review")
  thread.metadata.cockpit_review.state = "changes_requested"
  assert(Review.summary(thread).state == "ready_for_review", "changed code after feedback is ready for another review")
  assert(Review.summary(thread, { busy = true }).state == "changes_requested", "feedback remains pending while agent works")

  thread.change_journal.turns[2] = {
    turn_id = "turn-2", state = "completed", changes = {
      { path = "source.lua", operation = "modified", after_blob = { hash = "three" } },
      { path = "new.lua", previous_path = "old.lua", operation = "moved", after_blob = { hash = "new" } },
    }, annotations = { { id = "note-1", summary = "Fix edge case", author = { type = "user" } } },
  }
  thread.metadata.test_result = { run_id = "test-1", status = "failed" }
  delta = Review.since(thread)
  assert(delta.new_turns == 1 and delta.completed_turns == 2 and #delta.files == 3 and delta.test_changed,
    "new turns, unique file paths, rename paths and test changes are summarized")
  assert(Review.summary(thread).counts.notes == 1 and Review.summary(thread).counts.pending == 2,
    "review progress uses actual journal decisions and user notes")
  thread.metadata.cockpit_observation = Review.snapshot(thread)
  turn.changes[1].hunks = { { index = 1, decision = "kept" } }
  assert(Review.since(thread).review_updates == 1, "new hunk decisions are changes since check")
  local prior = thread.metadata.cockpit_observation
  thread.change_journal.turns = { thread.change_journal.turns[2] }
  delta = Review.since(thread)
  assert(delta.history_gap and delta.new_turns == 0, "truncated history reports a gap rather than invented turns")
  local branch = vim.deepcopy(thread)
  branch.thread_id = "branched-thread"
  branch.metadata.cockpit_observation = prior
  assert(not Review.since(branch).established and Review.summary(branch).state == "off",
    "another thread cannot inherit observation or review completion")
end

return M
