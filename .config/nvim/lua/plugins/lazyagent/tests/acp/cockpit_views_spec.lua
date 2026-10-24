local M = {}
function M.run()
  local root = vim.fn.tempname() .. "-cockpit-views"
  local Views = require("lazyagent.acp.cockpit_views")
  local one, two = Views.new({ dir = root }), Views.new({ dir = root })
  assert(#one:list() == 0, "missing store is empty")
  assert(one:save("My project", "workspace:current status:running,idle", true))
  assert(two:get("My project").attention_only, "views survive a new store instance")
  assert(two:save("../../日本語 view", 'provider:Codex "auth callback"', false))
  assert(#one:list() == 2, "separate writers preserve other saved views")
  assert(one:save("My project", "unread:true", false))
  assert(#two:list() == 2 and two:get("My project").query == "unread:true", "explicit overwrite replaces only its name")
  local uv = vim.uv or vim.loop
  local rename = uv.fs_rename
  uv.fs_rename = function() return nil, "fixture rename failure" end
  local replacement = one:save("My project", "pinned:true", false)
  uv.fs_rename = rename
  assert(not replacement and one:get("My project").query == "unread:true", "failed atomic replacement preserves the saved view")
  assert(not one:save("", "", false) and not one:save("bad\nname", "", false), "invalid view names rejected")
  assert(not one:save("Bad query", "unread:bad", false), "invalid queries cannot be persisted")
  local target = root .. "/" .. vim.fn.sha256("My project") .. ".json"
  vim.fn.writefile({ "broken JSON" }, target)
  assert(select(2, one:get("My project")), "corrupt named view reports error")
  local listed, warning = one:list()
  assert(#listed == 1 and warning, "one corrupt view does not hide other views")
  assert(one:delete("../../日本語 view") and #one:list() == 0, "hashed names cannot escape the store during delete")
  local blocked = root .. "/not-a-directory"
  vim.fn.writefile({ "keep" }, blocked)
  local failed = Views.new({ dir = blocked }):save("test", "", false)
  assert(not failed and vim.fn.readfile(blocked)[1] == "keep", "failed save preserves existing files")
  vim.fn.delete(root, "rf")
end
return M
