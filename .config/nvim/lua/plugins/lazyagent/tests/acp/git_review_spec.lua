local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function run(argv, cwd)
  local result = vim.system(argv, { cwd = cwd, text = true }):wait()
  if result.code ~= 0 then error(table.concat(argv, " ") .. ": " .. tostring(result.stderr)) end
  return vim.trim(result.stdout or "")
end

function M.run()
  local GitReview = require("lazyagent.acp.git_review")
  local BlobStore = require("lazyagent.acp.blob_store")
  local ReviewStore = require("lazyagent.acp.review_store")
  local ChangeReview = require("lazyagent.acp.change_review")
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  run({ "git", "init", "-q" }, root)
  run({ "git", "config", "user.email", "lazyagent@example.invalid" }, root)
  run({ "git", "config", "user.name", "LazyAgent Test" }, root)
  vim.fn.writefile({ "local value = 1", "return value" }, root .. "/review.lua")
  run({ "git", "add", "review.lua" }, root)
  run({ "git", "commit", "-qm", "base" }, root)
  local base = run({ "git", "rev-parse", "HEAD" }, root)
  vim.fn.writefile({ "local value = 2", "return value + 1" }, root .. "/review.lua")
  vim.fn.writefile({ "new" }, root .. "/added.txt")
  run({ "git", "add", "." }, root)
  run({ "git", "commit", "-qm", "change" }, root)
  local head = run({ "git", "rev-parse", "HEAD" }, root)

  local blob_dir = root .. "-blobs"
  local review_dir = root .. "-reviews"
  local blobs = BlobStore.new({ dir = blob_dir, max_blob_bytes = false })
  local review = assert(GitReview.create("HEAD~1..HEAD", { cwd = root, blob_store = blobs }))
  assert_equal(review.base, base, "review freezes base revision")
  assert_equal(review.head, head, "review freezes head revision")
  assert_equal(review.mode, "direct", "two-dot range mode")
  assert_equal(review.schema_version, 2, "review schema version")
  assert_equal(review.lineage_id, review.changeset_id, "initial review starts a lineage")
  assert_equal(#review.changes, 2, "modified and added files are captured")
  local by_path = {}
  for _, change in ipairs(review.changes) do by_path[change.path] = change end
  assert_equal(by_path["review.lua"].operation, "modified", "modified operation")
  assert_equal(blobs:get(by_path["review.lua"].before_blob, { max_bytes = false }),
    "local value = 1\nreturn value\n", "base blob remains readable")
  assert_equal(blobs:get(by_path["review.lua"].after_blob, { max_bytes = false }),
    "local value = 2\nreturn value + 1\n", "head blob remains readable")
  assert_equal(review.diff, nil, "review does not duplicate the Git diff")
  review.instructions = "Focus on Oracle compatibility.\nIgnore formatting-only concerns."
  local prompt = GitReview.prompt(review)
  assert(prompt:match("^Additional review instructions from the user:\nFocus on Oracle compatibility%."),
    "scratch instructions are prepended to the review prompt")
  assert(prompt:find("read-only code review", 1, true), "prompt is explicitly read-only")
  assert(prompt:find("Repository root: " .. root, 1, true), "prompt identifies the repository")
  assert(prompt:find("unchanged after-side line in a changed file", 1, true),
    "prompt permits directly relevant findings outside diff hunks")
  assert(prompt:find("git diff --find-renames --no-ext-diff " .. base .. " " .. head, 1, true),
    "prompt tells the reviewer how to inspect the frozen comparison")
  assert(not prompt:find("diff --git", 1, true), "prompt does not embed the diff")

  local response = table.concat({
    "Review complete.",
    "```lazyagent-review",
    vim.json.encode({ review_id = review.review_id, findings = { {
      label = "must", path = "review.lua", line = 2,
      summary = "Return changed", rationale = "Callers may rely on the old value.",
    }, {
      label = "unknown", path = "review.lua", line = 1, summary = "Ignored",
    } } }),
    "```",
  }, "\n")
  local annotations = assert(GitReview.parse(response, review))
  assert_equal(#annotations, 1, "invalid findings are discarded")
  assert_equal(annotations[1].label, "must", "finding label")
  assert_equal(annotations[1].target.start_line, 2, "finding after line")
  local sides = assert(GitReview.parse(table.concat({
    "```lazyagent-review",
    vim.json.encode({ review_id = review.review_id, findings = {
      { label = "should", path = "review.lua", side = "before", line = 1, summary = "Before" },
      { label = "imo", path = "added.txt", side = "file", summary = "Whole file" },
      { label = "question", side = "overall", summary = "Overall" },
    } }),
    "```",
  }, "\n"), review))
  assert_equal(#sides, 3, "before, file, and overall findings")
  assert_equal(sides[1].target.blob_hash, by_path["review.lua"].before_blob.hash, "before finding anchors before blob")
  review.annotations = annotations
  review.status = "completed"

  local review_store = ReviewStore.new({ dir = review_dir })
  assert(review_store:save(review), "review is persisted")
  assert_equal(assert(review_store:get(review.review_id)).annotations[1].summary,
    "Return changed", "saved finding is restored")
  assert_equal(assert(review_store:get(review.review_id)).instructions,
    "Focus on Oracle compatibility.\nIgnore formatting-only concerns.", "review instructions are persisted")
  assert_equal(#assert(review_store:for_lineage(review.lineage_id)), 1, "reviews can be listed by lineage")

  local feedback_review = vim.deepcopy(review)
  feedback_review.reviewer = "ReviewFixture"
  feedback_review.annotations = { {
    id = "comment-1", kind = "comment", path = "review.lua", rationale = "Please fix this",
    target = { side = "after", start_line = 1 }, author = { type = "user" }, pending = true,
  } }
  local controller = require("lazyagent.acp.git_review_controller")
  local feedback_prompt = controller._feedback_prompt(feedback_review)
  assert(feedback_prompt:find("comment%-1"), "feedback prompt includes annotation ID")
  local updated = controller._apply_feedback_response(feedback_review, table.concat({
    "Done.", "```lazyagent-review-replies",
    vim.json.encode({ review_id = review.review_id, replies = { { annotation_id = "comment-1", body = "Fixed and tested." } } }),
    "```",
  }, "\n"), "OtherReviewer")
  assert_equal(updated.annotations[1].pending, false, "sent comment is no longer pending")
  assert_equal(updated.annotations[1].replies[1].body, "Fixed and tested.", "AI reply is attached to comment")
  assert_equal(updated.annotations[1].replies[1].author.name, "OtherReviewer",
    "reply records the selected feedback agent")

  local logic_state = require("lazyagent.logic.state")
  local saved_sessions, saved_opts = logic_state.sessions, logic_state.opts
  local saved_buffer_backend = logic_state.backends.buffer_acp
  local snapshots = {
    original = { acp_ready = true, acp_thread_id = "thread-original", root_dir = root },
    other = { acp_ready = true, acp_thread_id = "thread-other", cwd = root },
    busy = { acp_ready = true, acp_thread_id = "thread-busy", root_dir = root, acp_busy = true },
    foreign = { acp_ready = true, acp_thread_id = "thread-foreign", root_dir = root .. "-foreign" },
  }
  logic_state.sessions = {
    ReviewFixture = { pane_id = "original", backend = "buffer_acp" },
    OtherReviewer = { pane_id = "other", backend = "buffer_acp" },
    BusyReviewer = { pane_id = "busy", backend = "buffer_acp" },
    ForeignReviewer = { pane_id = "foreign", backend = "buffer_acp" },
  }
  logic_state.opts = { interactive_agents = {} }
  logic_state.backends.buffer_acp = {
    get_runtime_snapshot = function(pane_id) return snapshots[pane_id] end,
    set_read_only_guard = function() return true end,
  }
  feedback_review.reviewer = "ReviewFixture"
  feedback_review.reviewer_thread_id = "thread-original"
  local feedback_targets = controller._feedback_candidates_for(feedback_review)
  assert_equal(vim.tbl_map(function(item) return item.name end, feedback_targets),
    { "OtherReviewer", "ReviewFixture" }, "feedback targets include every idle ACP thread in the review repository")
  assert_equal(feedback_targets[2].original, true, "original reviewer is identified without excluding alternatives")
  logic_state.sessions, logic_state.opts = saved_sessions, saved_opts
  logic_state.backends.buffer_acp = saved_buffer_backend

  local thread = {
    thread_id = "git-review-" .. review.review_id,
    title = review.range,
    cwd = root,
    review_mode = true,
    change_journal = { turns = { {
      turn_id = review.review_id, state = "completed",
      changes = review.changes, annotations = review.annotations,
    } } },
  }
  local lines = ChangeReview.drawer_lines(thread, thread.change_journal.turns[1])
  assert_equal(lines[1], "LazyAgent AI Review — HEAD~1..HEAD", "AI review drawer title")
  assert(lines[3]:find("`K` finding", 1, true), "review-specific actions")
  assert(table.concat(lines, "\n"):find("💬[must]", 1, true), "file row includes finding label")

  local window = require("lazyagent.window")
  local scratch_buf = window.ensure_scratch_buffer(nil, { filetype = "lazyagent", agent_name = "ReviewFixture" })
  vim.api.nvim_buf_set_lines(scratch_buf, 0, -1, false, { "Prioritize regressions.", "Check error paths." })
  window.open(scratch_buf, { window_type = "float", agent_name = "ReviewFixture" })
  local captured = assert(controller._capture_scratch())
  assert_equal(captured.text, "Prioritize regressions.\nCheck error paths.", "visible scratch instructions are captured")
  controller._consume_scratch(captured)
  assert_equal(window.is_open(), nil, "consumed scratch window is closed")
  assert_equal(table.concat(vim.api.nvim_buf_get_lines(scratch_buf, 0, -1, false), "\n"), "",
    "consumed scratch buffer is cleared")
  vim.api.nvim_buf_delete(scratch_buf, { force = true })

  vim.fn.writefile({ "local value = 3", "return value + 2" }, root .. "/review.lua")
  run({ "git", "add", "review.lua" }, root)
  vim.fn.writefile({ "local value = 4", "return value + 3" }, root .. "/review.lua")
  vim.fn.writefile({ "untracked" }, root .. "/untracked.txt")

  local index_review = assert(GitReview.create("staged", { cwd = root, blob_store = blobs }))
  assert_equal(index_review.mode, "index", "staged alias creates an index review")
  assert_equal(index_review.range, "HEAD..INDEX", "index review label")
  assert_equal(index_review.source.kind, "index", "index ReviewSource kind")
  assert_equal(#index_review.changes, 1, "index review excludes unstaged and untracked content")
  assert_equal(blobs:get(index_review.changes[1].after_blob, { max_bytes = false }),
    "local value = 3\nreturn value + 2\n", "index review freezes staged blob content")

  local worktree_review = assert(GitReview.create("working", { cwd = root, blob_store = blobs }))
  assert_equal(worktree_review.mode, "working_tree", "working alias creates a worktree review")
  assert_equal(worktree_review.range, "HEAD..WORKTREE", "worktree review label")
  assert_equal(worktree_review.source.kind, "working_tree", "worktree ReviewSource kind")
  local worktree_by_path = {}
  for _, change in ipairs(worktree_review.changes) do worktree_by_path[change.path] = change end
  assert_equal(blobs:get(worktree_by_path["review.lua"].after_blob, { max_bytes = false }),
    "local value = 4\nreturn value + 3\n", "worktree review freezes final filesystem content")
  assert_equal(worktree_by_path["untracked.txt"].operation, "added", "worktree review includes untracked files")

  vim.fn.delete(root, "rf")
  vim.fn.delete(blob_dir, "rf")
  vim.fn.delete(review_dir, "rf")
end

return M
