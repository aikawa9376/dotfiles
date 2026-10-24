local M = {}

function M.run()
  local Cockpit = require("lazyagent.acp.cockpit")
  local Details = require("lazyagent.acp.cockpit_details")
  local thread = {
    thread_id = "attention-thread", title = "Implement auth", provider_id = "Codex", cwd = "/tmp/attention",
    status = "closed", unread = false,
    metadata = { cockpit_completion = { id = "turn-1" } },
  }
  local runtime = {
    acp_ready = true,
    acp_ui_requests = { active = { id = 1, kind = "elicitation", label = "Keep old API?" }, pending = {} },
    acp_prompt_queue = { { id = "q1", text = "Add a regression test" } },
    acp_goal = { title = "Support OAuth" }, acp_plan = { { content = "Implement callback", status = "in_progress" } },
  }
  local attention = Cockpit.attention(thread, runtime)
  assert(#attention.items == 2 and attention.items[1].kind == "elicitation", "input and unacknowledged completion are separate")
  assert(Cockpit.needs_attention(thread, runtime), "read transcript does not acknowledge completion")
  local snoozed = { [thread.thread_id] = { signature = attention.signature, until_at = 200 } }
  assert(not Cockpit.needs_attention(thread, runtime, { snoozed = snoozed, now = 100 }), "snooze hides matching attention")
  assert(Cockpit.needs_attention(thread, runtime, { snoozed = snoozed, now = 200 }), "snooze expires")
  runtime.acp_ui_requests.active.id = 2
  assert(Cockpit.needs_attention(thread, runtime, { snoozed = snoozed, now = 100 }), "new request bypasses an old snooze")
  runtime.acp_ui_requests = {}
  thread.metadata.cockpit_ack_completion = "turn-1"
  assert(not Cockpit.needs_attention(thread, runtime), "acknowledgement is scoped to one completion")
  thread.metadata.cockpit_completion.id = "turn-2"
  assert(Cockpit.needs_attention(thread, runtime), "another completion needs acknowledgement")

  local other = { thread_id = "quiet", title = "Quiet", cwd = "/tmp/quiet", status = "closed", provider_id = "Codex" }
  local lines, map = Cockpit.render({ thread, other }, { [thread.thread_id] = runtime }, { attention_only = true, width = 40 })
  assert(vim.tbl_count(map) == 1 and table.concat(lines, "\n"):find("attention:1", 1, true), "attention view filters quiet threads")
  for row in pairs(map) do
    assert(lines[row]:find("!", 1, true) and vim.fn.strdisplaywidth(lines[row]) <= 40, "narrow rows keep the attention marker")
  end
  local folded, folded_map = Cockpit.render({ thread }, { [thread.thread_id] = runtime }, {
    collapsed_groups = { [thread.cwd] = true },
  })
  assert(next(folded_map) == nil and table.concat(folded, "\n"):find("attention:1 · collapsed", 1, true),
    "collapsed workspace retains its attention count")
  local overview = table.concat(Details.render(thread, runtime, "overview"), "\n")
  assert(overview:find("Support OAuth", 1, true) and overview:find("Implement callback", 1, true), "overview uses provider goal and plan")
  assert(table.concat(Details.render(thread, runtime, "queue"), "\n"):find("Add a regression test", 1, true), "queue detail")
  thread.metadata.test_result = { status = "passed", fingerprint = "before", output = "all tests passed" }
  local tests = table.concat(Details.render(thread, runtime, "tests", { fingerprints = { [thread.cwd] = "after" } }), "\n")
  assert(tests:find("Tests · stale", 1, true) and tests:find("all tests passed", 1, true), "stale test retains historical output")
  local Review = require("lazyagent.acp.cockpit_review")
  local unmanaged = vim.deepcopy(other)
  unmanaged.thread_id = "unmanaged-review"
  unmanaged.metadata = { cockpit_review = { state = "reviewing", thread_id = unmanaged.thread_id } }
  assert(not Cockpit.needs_attention(unmanaged), "legacy automatic reviewing does not require attention")
  unmanaged.metadata.cockpit_review.state = "done"
  assert(not Cockpit.needs_attention(unmanaged), "legacy done does not produce freshness warnings")
  unmanaged.metadata.cockpit_review.enabled = true
  unmanaged.metadata.cockpit_review.state = "reviewing"
  assert(not Cockpit.needs_attention(unmanaged), "explicit reviewing alone is not an actionable alert")
  local unmanaged_lines = table.concat(Cockpit.render({ other, unmanaged }), "\n")
  assert(unmanaged_lines:find("review:reviewing", 1, true), "enabled review progress remains visible on the card")
  thread.metadata = { cockpit_observation = Review.snapshot(thread) }
  thread.change_journal = { turns = { { turn_id = "new-work", state = "completed", changes = {
    { path = "source.lua", after_blob = { hash = "one" } },
  } } } }
  assert(Cockpit.needs_attention(thread), "updates after an explicit checkpoint need attention")
  assert(#Cockpit.filter({ thread }, "updates") == 1, "updates can be filtered")
  thread.metadata.cockpit_review = { enabled = true, thread_id = thread.thread_id, state = "done", revision = "old", fingerprint = "before" }
  assert(Cockpit.review(thread).state == "needs_review", "new recorded code invalidates review done")
  assert(#Cockpit.filter({ thread }, "review:needs_review") == 1, "derived review state can be filtered")
  local changed = table.concat(Details.render(thread, nil, "changes"), "\n")
  assert(changed:find("Review: needs_review", 1, true) and changed:find("1 pending", 1, true),
    "changes view separates workflow state from file decisions")
  thread.status = "archived"
  assert(not Cockpit.needs_attention(thread), "archived history does not populate attention view")
end

return M
