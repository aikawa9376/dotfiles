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

vim.fn.mkdir(fixture .. "/notes/projects/dotfiles", "p")
vim.fn.writefile({ "# Branch" }, fixture .. "/notes/projects/dotfiles/master.md")
vim.fn.writefile({ "# Repository" }, fixture .. "/notes/projects/dotfiles/index.md")
local recent, recent_total = dashboard._collect_section(fixture, {
  dir = "notes",
  exclude = { "projects" },
}, false)
assert(#recent == 2 and recent_total == 2, "project notes can be excluded from recent notes")
local branches, branch_total = dashboard._collect_section(fixture, {
  dir = "notes/projects",
  exclude = { "index.md" },
}, false)
assert(branch_total == 1 and branches[1].relative_path == "notes/projects/dotfiles/master.md",
  "branch section excludes repository index notes")
local note_directories = dashboard._section_directories(fixture, {
  dir = "notes",
  exclude = { "projects" },
})
assert(#note_directories == 2, "note creation lists the section root and allowed subdirectories")
assert(note_directories[1].relative_path == "" and note_directories[2].relative_path == "nested",
  "note creation directories are sorted and respect exclusions")
assert(dashboard._valid_note_name("Casual note.md") == "Casual note", "optional markdown suffix is removed")
assert(dashboard._valid_note_name("nested/note") == nil, "note names cannot escape the selected directory")
assert(dashboard._valid_note_name("  ") == nil, "empty note names are rejected")

dashboard.setup({
  show_aliases = false,
  sections = { { title = "Notes", dir = "notes", limit = 2, exclude = { "projects" } } },
})
assert(vim.fn.exists(":ObsidianDashboard") == 2, "dashboard command is registered")
local model = dashboard._build_model(fixture)
assert(vim.tbl_contains(model.lines, "NOTES              notes/  (2)"), "configured section is rendered")
assert(model.lines[#model.lines]:find("<CR> open", 1, true), "dashboard help is rendered")
assert(model.lines[#model.lines]:find("P preview", 1, true), "dashboard advertises right-side preview")
assert(model.lines[#model.lines]:find("a add", 1, true), "dashboard advertises section note creation")
assert(model.lines[#model.lines]:find("gb knowledge", 1, true), "Knowledge Base does not shadow k movement")
local filename_highlight
for _, highlight in ipairs(model.highlights) do
  local line = model.lines[highlight.row + 1]
  if highlight.group == "Directory" and line and line:find("notes/nested/newest.md", 1, true) then
    filename_highlight = line:sub(highlight.start_col + 1, highlight.end_col)
  end
end
assert(filename_highlight == "newest.md", "dashboard colors only the filename")

vim.fn.delete(fixture, "rf")
print("ok - dashboard_spec")
