local M = {}
function M.run()
  local Review = require("lazyagent.acp.cockpit_review")
  local Compare = require("lazyagent.acp.cockpit_diff")
  local root = vim.fn.tempname() .. "-cockpit-diff"
  local blobs = require("lazyagent.acp.blob_store").new({ dir = root .. "/blobs", max_blob_bytes = false })
  local function put(text) return assert(blobs:put(text)) end
  local base, checked, revised = put("old\n"), put("checked\n"), put("revised\n")
  local thread = { thread_id = "123e4567-e89b-42d3-a456-426614174081", provider_id = "fixture", title = "Comparison", cwd = root,
    status = "closed", metadata = {}, change_journal = { turns = { { turn_id = "t1", state = "completed", changes = {
      { path = "source.lua", operation = "modified", before_blob = base, after_blob = checked },
    } } } } }
  assert(not Compare.plan(thread), "comparison requires an explicit checkpoint")
  local checkpoint = Review.snapshot(thread, { include_code = true })
  checkpoint.observed_at = "2026-10-24T00:00:00Z"
  thread.metadata.cockpit_observation = checkpoint
  assert(checkpoint.code.refs["source.lua"].hash == checked.hash, "checkpoint retains typed references for blob GC")
  assert(#Compare.plan(thread).changes == 0, "unchanged journal has no code diff")
  local active = vim.deepcopy(thread)
  active.change_journal.turns[1].state = "active"
  active.change_journal.turns[1].file_revisions = { ["source.lua"] = { after_blob = revised, after_seen = true } }
  assert(Compare.plan(active).changes[1].before_blob.hash == checked.hash, "active revision compares against checked content")
  active.change_journal.turns[1].file_revisions["ambiguous.lua"] = { after_blob = revised, after_seen = true }
  for _, change in ipairs(Compare.plan(active).changes) do
    if change.path == "ambiguous.lua" then assert(change.unavailable, "unknown baseline in a previously observed turn stays unavailable") end
  end
  local other_before, other_after = put("other before\n"), put("other after\n")
  thread.change_journal.turns[2] = { turn_id = "t2", state = "completed", changes = {
    { path = "source.lua", operation = "modified", before_blob = checked, after_blob = revised },
    { path = "other.lua", operation = "modified", before_blob = other_before, after_blob = other_after },
    { path = "new.lua", operation = "added", after_blob = revised },
    { path = "removed.lua", operation = "deleted", before_blob = base },
    { path = "moved.lua", previous_path = "previous.lua", operation = "moved", before_blob = base, after_blob = revised },
  } }
  local plan = assert(Compare.plan(thread))
  assert(#plan.changes == 6, "post-check modification/addition/deletion and rename paths are compared")
  local by_path = {}
  for _, change in ipairs(plan.changes) do by_path[change.path] = change end
  assert(by_path["source.lua"].before_blob.hash == checked.hash and by_path["source.lua"].after_blob.hash == revised.hash,
    "comparison starts at checked content rather than original turn baseline")
  assert(by_path["other.lua"].before_blob.hash == other_before.hash, "first later touch provides the baseline for an existing file")
  assert(by_path["new.lua"].operation == "added" and by_path["removed.lua"].operation == "deleted", "absence is explicit")
  local pair = assert(Compare.read_pair(by_path["source.lua"], blobs))
  assert(pair.before == "checked\n" and pair.after == "revised\n", "reads immutable saved sides")
  thread.change_journal.turns[2].changes[2].decision = "rejected"
  local rejected = Compare.plan(thread)
  for _, change in ipairs(rejected.changes) do assert(change.path ~= "other.lua", "rejected file is not a new effective code change") end
  thread.change_journal.turns[2].changes[1].review_blob = put("partly revised\n")
  for _, change in ipairs(Compare.plan(thread).changes) do
    if change.path == "source.lua" then
      assert(change.after_blob.hash == thread.change_journal.turns[2].changes[1].review_blob.hash, "partial review content is used")
    end
  end

  local saved_cwd = thread.cwd
  thread.cwd = root .. "/different"
  assert(not Compare.plan(thread), "workspace changes cannot reuse an unrelated comparison basis")
  thread.cwd = saved_cwd
  local legacy = vim.deepcopy(thread)
  legacy.metadata.cockpit_observation.code = nil
  assert(Compare.plan(legacy).legacy, "legacy token checkpoints are explicit and can reuse available blobs")
  local branch = vim.deepcopy(thread); branch.thread_id = "different-thread"
  assert(not Compare.plan(branch), "branches cannot inherit a parent's checkpoint")
  local gap = vim.deepcopy(thread)
  table.remove(gap.change_journal.turns, 1)
  local gap_plan = Compare.plan(gap)
  assert(gap_plan.history_gap, "missing baseline journal marks history gap")
  for _, change in ipairs(gap_plan.changes) do
    if change.path == "other.lua" then assert(change.unavailable, "new-path baselines are not inferred across a history gap") end
  end
  local missing = { operation = "modified", before_blob = { hash = string.rep("f", 64) }, after_blob = revised }
  local _, missing_err = Compare.read_pair(missing, blobs)
  assert(missing_err:find("missing", 1, true), "missing blobs are not empty files")
  local huge = put(string.rep("x", 2 * 1024 * 1024 + 1))
  assert(not Compare.read_pair({ operation = "added", after_blob = huge }, blobs), "large pairs are bounded before reading")
  local binary = assert(Compare.read_pair({ operation = "added", after_blob = put("binary\0data") }, blobs))
  assert(binary.binary, "binary data is identified without passing it to a text diff")
  local _, checksum = Compare.read_pair({ operation = "added", after_blob = revised }, {
    size = function() return 5 end, get = function() return "bad" end,
  })
  assert(checksum:find("checksum", 1, true), "corrupt immutable content cannot masquerade as the checkpoint")

  local original_tab = vim.api.nvim_get_current_tabpage()
  local original_windows = vim.api.nvim_tabpage_list_wins(original_tab)
  local version = Review.version(thread)
  local opened, buf = Compare.open(thread, blobs)
  assert(opened and not vim.bo[buf].modifiable, "comparison list is read-only")
  assert(vim.fn.maparg("a", "n", false, true).buffer ~= 1 and vim.fn.maparg("u", "n", false, true).buffer ~= 1,
    "comparison does not expose journal decision or checkpoint restore actions")
  for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line == "modified source.lua" then vim.api.nvim_win_set_cursor(0, { row, 0 }); break end
  end
  vim.fn.maparg("o", "n", false, true).callback()
  local contents = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  assert(contents:find("-checked", 1, true) and contents:find("+partly revised", 1, true), "inline diff uses checked and current recorded sides")
  vim.fn.maparg("d", "n", false, true).callback()
  assert(vim.api.nvim_get_current_tabpage() ~= original_tab and not vim.bo.modifiable, "existing immutable diff tabs are reused")
  vim.cmd("tabclose")
  vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
  vim.fn.maparg("q", "n", false, true).callback()
  assert(Review.version(thread) == version, "opening comparisons never changes review state or journal decisions")
  assert(#vim.api.nvim_tabpage_list_wins(original_tab) == #original_windows, "comparison windows are disposed")

  local stored = vim.deepcopy(thread)
  stored.change_journal = { turns = {} }
  local threads = require("lazyagent.acp.thread_store").new({ dir = root .. "/threads" })
  assert(threads:create(stored))
  local gc = require("lazyagent.acp.blob_gc").new({ thread_store = threads, blob_dir = root .. "/blobs", min_age_seconds = 0 })
  local report = assert(gc:scan())
  for _, candidate in ipairs(report.candidates) do assert(candidate.hash ~= checked.hash, "checkpoint reference survives journal pruning during blob GC") end
  vim.fn.delete(root, "rf")
end
return M
