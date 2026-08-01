require("lazy").load({ plugins = { "diffview.nvim" } })

local temp = vim.fn.tempname()
local BlobStore = require("lazyagent.acp.blob_store")
local blobs = BlobStore.new({ dir = temp, max_blob_bytes = false })
local before = assert(blobs:put("before\n", { max_bytes = false }))
local after = assert(blobs:put("after\n", { max_bytes = false }))
local root = vim.trim(vim.system({ "git", "rev-parse", "--show-toplevel" }, { text = true }):wait().stdout)
local review = {
  review_id = "smoke-review",
  changeset_id = "smoke-changeset",
  lineage_id = "smoke-lineage",
  root = root,
  range = "smoke",
  source = { kind = "diffview", frontend = "diffview", mutable = false },
  changes = { {
    operation = "modified", path = "smoke.txt", before_blob = before, after_blob = after,
  } },
  annotations = {},
}

local controller = require("lazyagent.acp.git_review_controller")
local original_read_blob = controller.read_blob
controller.read_blob = function(ref) return blobs:get(ref, { max_bytes = false }) end
assert(require("diffview_extension.review_view").open(review))
vim.wait(1000, function()
  local view = require("diffview.lib").get_current_view()
  return view and view.files and view.files:len() == 1
end, 10)
local view = assert(require("diffview.lib").get_current_view(), "custom Diffview did not open")
assert(view.files:len() == 1, "custom Diffview did not restore the saved file")
view:close()
controller.read_blob = original_read_blob
vim.fn.delete(temp, "rf")
print("ok - diffview-extension cdiff smoke")
