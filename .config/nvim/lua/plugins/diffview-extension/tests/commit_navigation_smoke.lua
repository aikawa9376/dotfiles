require("lazy").load({ plugins = { "diffview.nvim" } })

local function git(args)
  local command = { "git" }
  vim.list_extend(command, args)
  local result = vim.system(command, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout or "")
end

local head = git({ "rev-parse", "HEAD" })
local parent = git({ "rev-parse", "HEAD^" })
vim.cmd("DiffviewOpen HEAD^!")
assert(vim.wait(5000, function()
  local view = require("diffview.lib").get_current_view()
  return view and view.right and view.right.commit == head
end, 20), "initial commit Diffview did not load")
local mapping = vim.fn.maparg("]C", "n", false, true)
assert(mapping and mapping.buffer == 1 and mapping.desc == "Older commit", "]C is not mapped in the file panel")

local navigation = require("diffview_extension.commit_navigation")
navigation.older()
assert(vim.wait(5000, function()
  local view = require("diffview.lib").get_current_view()
  return view and view.right and view.right.commit == parent
end, 20), "]C did not open the parent commit")

navigation.newer()
assert(vim.wait(5000, function()
  local view = require("diffview.lib").get_current_view()
  return view and view.right and view.right.commit == head
end, 20), "[C did not return to the newer commit")

require("diffview.lib").get_current_view():close()
print("ok - diffview commit navigation")
