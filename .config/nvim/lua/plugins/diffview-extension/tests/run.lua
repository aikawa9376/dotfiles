local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(source))
local lazyagent = vim.fs.normalize(root .. "/../lazyagent")

vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(lazyagent)
package.path = table.concat({
  root .. "/lua/?.lua", root .. "/lua/?/init.lua",
  lazyagent .. "/lua/?.lua", lazyagent .. "/lua/?/init.lua",
  package.path,
}, ";")

local function eq(actual, expected, message)
  assert(vim.deep_equal(actual, expected), string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
end

local function git(repo, args)
  local argv = { "git", "-C", repo }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout or "")
end

local temp = vim.fn.tempname()
local repo = temp .. "/repo"
vim.fn.mkdir(repo, "p")
git(repo, { "init", "-q" })
git(repo, { "config", "user.email", "review@example.invalid" })
git(repo, { "config", "user.name", "Review Test" })
vim.fn.writefile({ "base" }, repo .. "/tracked.txt")
vim.fn.writefile({ "ignored.txt" }, repo .. "/.gitignore")
git(repo, { "add", "." })
git(repo, { "commit", "-qm", "base" })
vim.fn.writefile({ "staged" }, repo .. "/tracked.txt")
git(repo, { "add", "tracked.txt" })
vim.fn.writefile({ "final", "working" }, repo .. "/tracked.txt")
vim.fn.writefile({ "new" }, repo .. "/untracked.txt")
vim.fn.writefile({ "ignored" }, repo .. "/ignored.txt")

local BlobStore = require("lazyagent.acp.blob_store")
local blobs = BlobStore.new({ dir = temp .. "/blobs", max_blob_bytes = false })
local services = { put_blob = function(data) return blobs:put(data, { max_bytes = false }) end }
local snapshot = assert(require("diffview_extension.snapshot")._worktree_snapshot(repo, "HEAD", nil, services, {
  kind = "diffview", frontend = "diffview", mutable = true,
}))
eq(#snapshot.changes, 2, "tracked and untracked files captured once")
local by_path = {}
for _, change in ipairs(snapshot.changes) do by_path[change.path] = change end
eq(blobs:get(by_path["tracked.txt"].after_blob, { max_bytes = false }), "final\nworking\n", "final worktree content wins over index")
eq(by_path["untracked.txt"].operation, "added", "untracked file included")
eq(by_path["ignored.txt"], nil, "ignored file excluded")

local GitReview = require("lazyagent.acp.git_review")
local first = assert(GitReview.from_snapshot(snapshot, { clock = function() return "2026-08-01T00:00:00Z" end, nonce = 1 }))
local second = assert(GitReview.from_snapshot(snapshot, { clock = function() return "2026-08-01T00:00:00Z" end, nonce = 2 }))
eq(first.changeset_id, second.changeset_id, "same snapshot shares changeset")
assert(first.review_id ~= second.review_id, "rerun creates a distinct review")
eq(first.source.frontend, "diffview", "source frontend retained")
assert(GitReview.prompt(first):find("Prefer a before or after line target", 1, true), "review prompt prefers line targets")

local response = table.concat({
  "```lazyagent-review",
  vim.json.encode({ review_id = first.review_id, findings = {
    { label = "must", path = "tracked.txt", side = "before", line = 1, summary = "Before finding" },
    { label = "should", path = "untracked.txt", side = "file", summary = "File finding" },
    { label = "imo", side = "overall", summary = "Overall finding" },
  } }),
  "```",
}, "\n")
local findings = assert(GitReview.parse(response, first))
eq(#findings, 3, "line, file, and overall findings parsed")
eq(findings[1].target.side, "before", "before-side finding retained")
eq(findings[2].target.side, "file", "file finding retained")
eq(findings[3].path, nil, "overall finding has no path")

local old_controller = package.loaded["lazyagent.acp.git_review_controller"]
package.loaded["lazyagent.acp.git_review_controller"] = {
  list = function()
    return {
      {
        review_id = "old", lineage_id = "lineage", reviewer = "Codex", created_at = "1",
        changes = { { path = "tracked.txt", after_blob = { hash = "old-hash" } } },
        annotations = {
          { id = "open", path = "tracked.txt", summary = "Still open", target = { side = "after", start_line = 1, blob_hash = "old-hash" } },
          { id = "resolved", path = "tracked.txt", summary = "Done", resolved = true, target = { side = "after", start_line = 1, blob_hash = "old-hash" } },
          { id = "file", path = "tracked.txt", summary = "Whole file", target = { side = "file", blob_hash = "old-hash" } },
        },
      },
      {
        review_id = "new", lineage_id = "lineage", reviewer = "Codex", created_at = "2",
        changes = { { path = "tracked.txt", after_blob = { hash = "new-hash" } } }, annotations = {},
      },
    }
  end,
}
package.loaded["diffview_extension.review_view"] = nil
local review_view = require("diffview_extension.review_view")
local fake_view = { tabpage = 12345 }
review_view._states[fake_view.tabpage] = { visibility = 1, changeset_id = "new", lineage_id = "lineage" }
local visible = review_view._annotations_for(fake_view, "tracked.txt", "after")
eq(#visible, 1, "diff buffer keeps line findings and excludes resolved and file findings")
eq(visible[1].outdated, true, "unresolved old snapshot finding is marked outdated")
review_view._states[fake_view.tabpage].visibility = 2
eq(#review_view._annotations_for(fake_view, "tracked.txt", "after"), 2, "all view includes resolved findings")
local review_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(review_buf, 0, -1, false, { "first", "second" })
fake_view.cur_entry = { path = "tracked.txt" }
fake_view.cur_layout = { windows = { { file = { bufnr = review_buf, symbol = "b", path = "tracked.txt" } } } }
review_view._render_buffer(fake_view, review_buf)
local review_marks = vim.api.nvim_buf_get_extmarks(review_buf, -1, 0, -1, {})
eq(#review_marks, 1, "render creates an extmark only for line findings")
eq(review_marks[1][2], 0, "line finding is rendered at its target line")
vim.api.nvim_buf_delete(review_buf, { force = true })
package.loaded["lazyagent.acp.git_review_controller"] = old_controller

vim.fn.delete(temp, "rf")
print("ok - diffview-extension")
