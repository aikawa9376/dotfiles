require("lazy").load({ plugins = { "diffview.nvim" } })

local temp = vim.fn.tempname()
local BlobStore = require("lazyagent.acp.blob_store")
local blobs = BlobStore.new({ dir = temp, max_blob_bytes = false })
local before = assert(blobs:put("before\n", { max_bytes = false }))
local after = assert(blobs:put("after\n", { max_bytes = false }))
local root = vim.trim(vim.system({ "git", "rev-parse", "--show-toplevel" }, { text = true }):wait().stdout)
local base = vim.trim(vim.system({ "git", "rev-parse", "HEAD^" }, { text = true }):wait().stdout)
local head = vim.trim(vim.system({ "git", "rev-parse", "HEAD" }, { text = true }):wait().stdout)
local path = ".config/nvim/init.lua"
local review = {
  review_id = "smoke-review",
  changeset_id = "smoke-changeset",
  lineage_id = "smoke-lineage",
  root = root,
  range = "smoke",
  base = base,
  head = head,
  source = { kind = "diffview", frontend = "diffview", mutable = false },
  changes = { {
    operation = "modified", path = path, before_blob = before, after_blob = after,
  } },
  annotations = { {
    path = path, summary = "After finding",
    target = { side = "after", start_line = 1, end_line = 1, blob_hash = after.hash },
  } },
}

local controller = require("lazyagent.acp.git_review_controller")
local original_read_blob = controller.read_blob
local original_list = controller.list
controller.read_blob = function(ref) return blobs:get(ref, { max_bytes = false }) end
controller.list = function() return { review } end
assert(require("diffview_extension.review_view").open(review))
vim.wait(1000, function()
  local view = require("diffview.lib").get_current_view()
  if not (view and view.files and view.files:len() == 1 and view.cur_entry and view.cur_layout) then return false end
  local windows = view.cur_layout.windows
  if not (windows[1] and windows[2] and windows[1].file.bufnr ~= windows[2].file.bufnr) then return false end
  local mapping
  vim.api.nvim_buf_call(windows[2].file.bufnr, function() mapping = vim.fn.maparg("c", "n", false, true) end)
  return mapping and mapping.buffer == 1
end, 10)
local view = assert(require("diffview.lib").get_current_view(), "custom Diffview did not open")
assert(view.files:len() == 1, "custom Diffview did not restore the saved file")
assert(view.cur_entry and view.cur_entry.path == path, "custom Diffview did not select its first file")
local windows = view.cur_layout.windows
assert(windows[1].file.bufnr ~= windows[2].file.bufnr, "custom Diffview reused one buffer for both sides")
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(windows[1].file.bufnr, 0, -1, false), { "before" }), "left snapshot was not rendered")
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(windows[2].file.bufnr, 0, -1, false), { "after" }), "right snapshot was not rendered")
for _, win in ipairs(windows) do
  assert(vim.wo[win.id].diff, "snapshot window is not in diff mode")
  local mapping
  vim.api.nvim_buf_call(win.file.bufnr, function() mapping = vim.fn.maparg("c", "n", false, true) end)
  assert(mapping and mapping.buffer == 1, "review comment mapping is not buffer-local")
end
local namespace = vim.api.nvim_get_namespaces().diffview_extension_review
local review_marks = vim.api.nvim_buf_get_extmarks(windows[2].file.bufnr, namespace, 0, -1, { details = true })
assert(#review_marks == 1, "after-side review mark was not rendered")
assert(review_marks[1][4].virt_text[1][1]:find("💬", 1, true), "review mark does not use the inline-review icon")
local panel_namespace = vim.api.nvim_get_namespaces().diffview_extension_review_panel
assert(#vim.api.nvim_buf_get_extmarks(view.panel.bufid, panel_namespace, 0, -1, {}) == 1, "file panel review mark was not rendered")
view.panel:render()
view.panel:redraw()
vim.wait(1000, function()
  return #vim.api.nvim_buf_get_extmarks(view.panel.bufid, panel_namespace, 0, -1, {}) == 1
end, 10)
assert(#vim.api.nvim_buf_get_extmarks(view.panel.bufid, panel_namespace, 0, -1, {}) == 1, "file panel redraw removed the review mark")
view:close()
controller.read_blob = original_read_blob
controller.list = original_list
vim.fn.delete(temp, "rf")
print("ok - diffview-extension cdiff smoke")
