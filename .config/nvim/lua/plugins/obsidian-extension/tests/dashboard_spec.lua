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
vim.fn.mkdir(fixture .. "/notes/nested", "p")
vim.fn.writefile({ "---", "aliases:", "- Older alias", "---", "# Older" }, fixture .. "/notes/older.md")
vim.fn.writefile({ "---", "aliases: [Newest alias]", "---", "# Newest" }, fixture .. "/notes/nested/newest.md")
vim.fn.writefile({ "not markdown" }, fixture .. "/notes/ignored.txt")
vim.uv.fs_utime(fixture .. "/notes/older.md", 100, 100)
vim.uv.fs_utime(fixture .. "/notes/nested/newest.md", 200, 200)

local recursive, total = dashboard._collect_section(fixture, {
  dir = "notes",
  limit = 1,
}, false)
assert(total == 2, "recursive section counts all markdown notes")
assert(#recursive == 1 and recursive[1].relative_path == "notes/nested/newest.md", "newest note is first")

local shallow, shallow_total = dashboard._collect_section(fixture, {
  dir = "notes",
  recursive = false,
}, false)
assert(shallow_total == 1 and shallow[1].relative_path == "notes/older.md", "recursive scanning can be disabled")

local missing, missing_total = dashboard._collect_section(fixture, { dir = "missing" }, false)
assert(#missing == 0 and missing_total == 0, "missing directories are empty")

local escaped = dashboard._collect_section(fixture, { dir = "../outside" }, false)
assert(#escaped == 0, "sections cannot escape the vault")

dashboard.setup({
  show_aliases = false,
  sections = { { title = "Notes", dir = "notes", limit = 2 } },
})
assert(vim.fn.exists(":ObsidianDashboard") == 2, "dashboard command is registered")
local model = dashboard._build_model(fixture)
assert(vim.tbl_contains(model.lines, "NOTES              notes/  (2)"), "configured section is rendered")
assert(model.lines[#model.lines]:find("<CR> open", 1, true), "dashboard help is rendered")

vim.fn.delete(fixture, "rf")
print("ok - dashboard_spec")
