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

  local blobs = BlobStore.new({ dir = root .. "/blobs", max_blob_bytes = false })
  local review = assert(GitReview.create("HEAD~1..HEAD", { cwd = root, blob_store = blobs }))
  assert_equal(review.base, base, "review freezes base revision")
  assert_equal(review.head, head, "review freezes head revision")
  assert_equal(review.mode, "direct", "two-dot range mode")
  assert_equal(#review.changes, 2, "modified and added files are captured")
  local by_path = {}
  for _, change in ipairs(review.changes) do by_path[change.path] = change end
  assert_equal(by_path["review.lua"].operation, "modified", "modified operation")
  assert_equal(blobs:get(by_path["review.lua"].before_blob, { max_bytes = false }),
    "local value = 1\nreturn value\n", "base blob remains readable")
  assert_equal(blobs:get(by_path["review.lua"].after_blob, { max_bytes = false }),
    "local value = 2\nreturn value + 1\n", "head blob remains readable")
  assert_equal(review.diff, nil, "review does not duplicate the Git diff")
  local prompt = GitReview.prompt(review)
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
  review.annotations = annotations
  review.status = "completed"

  local review_store = ReviewStore.new({ dir = root .. "/reviews" })
  assert(review_store:save(review), "review is persisted")
  assert_equal(assert(review_store:get(review.review_id)).annotations[1].summary,
    "Return changed", "saved finding is restored")

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

  vim.fn.delete(root, "rf")
end

return M
