local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(source))

vim.opt.runtimepath:prepend(root)
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local dashboard = require("obsidian_extension.features.dashboard")
local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture, "p")
local frontmatter_path = fixture .. "/frontmatter.md"
local plain_path = fixture .. "/plain.md"
vim.fn.writefile({ "---", "status: seed", "---", "# Frontmatter" }, frontmatter_path)
vim.fn.writefile({ "# Plain" }, plain_path)

local state = {}
local frontmatter_bufnr = dashboard._preview_buffer(state, frontmatter_path)
assert(vim.bo[frontmatter_bufnr].filetype == "markdown",
  "preview detects markdown filetype for notes with frontmatter")
local plain_bufnr = dashboard._preview_buffer(state, plain_path)
assert(vim.bo[plain_bufnr].filetype == "markdown",
  "preview detects markdown filetype for notes without frontmatter")
dashboard._release_preview_buffer(state)
dashboard._cleanup_opened_buffers(state.opened_buffers)

vim.cmd("vsplit")
local preview_winid = vim.api.nvim_get_current_win()
dashboard._configure_preview_window(preview_winid)
assert(vim.wo[preview_winid].previewwindow, "dashboard marks the note split as a preview window")
assert(vim.wo[preview_winid].winhighlight == "Normal:Normal,NormalNC:Normal",
  "preview uses the normal editor background while inactive")
vim.api.nvim_win_close(preview_winid, true)

vim.fn.delete(fixture, "rf")
print("ok - dashboard_preview_spec")
