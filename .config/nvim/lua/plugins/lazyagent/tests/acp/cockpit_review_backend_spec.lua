local M = {}

function M.run()
  local state = require("lazyagent.logic.state")
  local previous = state.opts
  local root = vim.fn.tempname() .. "-cockpit-review"
  vim.fn.mkdir(root .. "/workspace", "p")
  state.opts = vim.tbl_deep_extend("force", vim.deepcopy(previous or {}), { cache = { dir = root } })
  local ok, err = xpcall(function()
    local backend = require("lazyagent.acp.backend").new({})
    local Review = require("lazyagent.acp.cockpit_review")
    local thread = assert(backend.create_thread({
      provider_id = "fixture", title = "Review state", cwd = root .. "/workspace", status = "closed", unread = true,
      updated_at = "2026-01-01T00:00:00Z", metadata = { keep = "unrelated" },
      change_journal = { turns = { { turn_id = "t1", state = "completed", changes = {
        { path = "source.lua", operation = "modified", after_blob = { hash = "one" } },
      } } } },
    }))
    local id = thread.thread_id
    local observed = assert(backend.mark_thread_observed(id))
    assert(observed.metadata.cockpit_observation.code.schema_version == 1, "checkpoint saves comparison retention metadata")
    local comparison = require("lazyagent.acp.cockpit_diff")
    local original_compare = comparison.open
    local compared_id
    comparison.open = function(record) compared_id = record.thread_id; return true end
    local comparison_opened = backend.show_thread_changes_since_check(id)
    comparison.open = original_compare
    assert(comparison_opened and compared_id == id and not Review.enabled(backend.get_thread(id)),
      "comparison API targets the exact thread without enabling review tracking")
    assert(not Review.since(observed).changed and observed.unread == true, "checkpoint does not mark transcript read")
    assert(observed.updated_at == thread.updated_at and observed.metadata.keep == "unrelated", "checkpoint preserves activity and unrelated metadata")
    assert(not backend.set_thread_review_state(id, "invalid"), "invalid workflow state rejected")
    local drawer = require("lazyagent.acp.change_review")
    local original_open = drawer.open
    drawer.open = function() return true end
    local opened = backend.show_thread_changes(id)
    drawer.open = original_open
    assert(opened and not Review.enabled(backend.get_thread(id)), "opening changes does not enable review tracking")
    assert(not backend.set_thread_review_state(id, "reviewing", { require_enabled = true }), "automatic updates cannot enable tracking")
    assert(backend.set_thread_review_state(id, "not_started"))
    drawer.open = function() return true end
    opened = backend.show_thread_changes(id)
    drawer.open = original_open
    assert(opened and backend.get_thread(id).metadata.cockpit_review.state == "reviewing", "tracked session enters reviewing on changes open")
    assert(backend.set_thread_review_state(id, "reviewing"))
    assert(not backend.set_thread_review_state(id, "done"), "review done requires workspace verification")
    local current = backend.get_thread(id)
    assert(backend.set_thread_review_state(id, "done", { fingerprint = "verified", expected_version = Review.version(current) }))
    current = backend.get_thread(id)
    assert(current.metadata.cockpit_review.state == "done" and current.change_journal.turns[1].changes[1].decision == nil,
      "workflow completion does not approve individual changes")
    local old_version = Review.version(current)
    current.change_journal.turns[1].changes[1].after_blob.hash = "two"
    assert(backend.update_thread(id, { change_journal = current.change_journal }))
    assert(not backend.set_thread_review_state(id, "done", { fingerprint = "old", expected_version = old_version }),
      "stale review dialog cannot confirm unseen code")
    assert(backend.set_thread_review_state(id, "changes_requested"))
    assert(backend.get_thread(id).metadata.cockpit_review.fingerprint == nil, "replacing workflow clears old verification data")
    assert(backend.set_thread_review_state(id, "done", { fingerprint = "verified" }))
    local before_disable = backend.get_thread(id)
    local disabled = assert(backend.set_thread_review_state(id, "off"))
    assert(not Review.enabled(disabled) and disabled.metadata.keep == "unrelated" and disabled.unread == true
      and disabled.updated_at == before_disable.updated_at, "disable preserves unrelated state and activity")
    assert(disabled.metadata.cockpit_review.fingerprint == nil, "disable clears obsolete verification")
    assert(not backend.set_thread_review_state(id, "changes_requested", { require_enabled = true }), "feedback cannot re-enable disabled tracking")
    assert(backend.set_thread_review_state(id, "reviewing"))

    current = backend.get_thread(id)
    current.change_journal.turns[1].changes[2] = { path = "extra.lua", operation = "added", after_blob = { hash = "extra" } }
    assert(backend.update_thread(id, { change_journal = current.change_journal }))
    assert(backend.mark_thread_observed(id))
    current.change_journal.turns[1].changes[2] = nil
    assert(backend.update_thread(id, { change_journal = current.change_journal }))
    observed = assert(backend.mark_thread_observed(id))
    assert(#observed.metadata.cockpit_observation.files == 1, "smaller checkpoint replaces arrays without stale entries")
    assert(observed.metadata.keep == "unrelated", "field replacement does not replace all metadata")
    assert(backend.update_thread(id, { status = "active", process_id = vim.fn.getpid() }))
    assert(not backend.set_thread_review_state(id, "done", { fingerprint = "verified" }), "unowned live process cannot be marked review done")
    assert(backend.update_thread(id, { status = "closed", process_id = vim.NIL }))

    local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:gsub("^@", ""))))
    local live = require("lazyagent.acp.backend").new({
      create_pane = function(_, done) done("review-feedback-pane", {}) end,
      pane_exists = function() return true end,
      kill_pane = function() return true end,
    })
    live.split(nil, 10, false, { acp = {
      agent_name = "ReviewFixture", cwd = root .. "/workspace", root_dir = root .. "/workspace",
      additional_directories = { plugin_root .. "/tests" },
      command = { vim.v.progpath, "--headless", "--clean", "-u", "NONE", "-l", plugin_root .. "/tests/acp/fake_agent.lua" },
      env = { LAZYAGENT_FAKE_SIMPLE_PROMPT = "1" },
    } })
    assert(vim.wait(5000, function() return live.get_runtime_snapshot("review-feedback-pane").acp_ready end, 10))
    local live_id = live.get_runtime_snapshot("review-feedback-pane").acp_thread_id
    assert(live.paste_and_submit("review-feedback-pane", "Initial work", {}, {}))
    assert(vim.wait(5000, function()
      return live.get_thread(live_id).metadata.cockpit_completion ~= nil
    end, 10))
    local completed = live.get_thread(live_id).change_journal.turns[1]
    assert(live.send_thread_review(live_id, completed.turn_id, "Revise this work", {}))
    assert(not Review.enabled(live.get_thread(live_id)), "feedback alone does not enable review tracking")
    assert(vim.wait(5000, function() return not live.get_runtime_snapshot("review-feedback-pane").acp_busy end, 10))
    assert(live.set_thread_review_state(live_id, "reviewing"))
    assert(live.send_thread_review(live_id, completed.turn_id, "Revise tracked work", {}))
    assert(live.get_thread(live_id).metadata.cockpit_review.state == "changes_requested",
      "accepted feedback updates the review workflow")
    local shared_checkpoint = assert(live.mark_thread_observed(live_id)).metadata.cockpit_observation
    shared_checkpoint.observed_at = "updated-in-another-editor"
    local external_store = require("lazyagent.acp.thread_store").new({ dir = root .. "/acp/threads" })
    assert(external_store:update(live_id, { metadata = { cockpit_observation = shared_checkpoint } }))
    local compared_checkpoint
    comparison.open = function(record) compared_checkpoint = record.metadata.cockpit_observation.observed_at; return true end
    local shared_opened = live.show_thread_changes_since_check(live_id)
    comparison.open = original_compare
    assert(shared_opened and compared_checkpoint == "updated-in-another-editor", "comparison uses the latest shared checkpoint with live journal data")
    live.kill_pane("review-feedback-pane")
  end, debug.traceback)
  state.opts = previous
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

return M
