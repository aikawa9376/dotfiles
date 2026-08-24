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
vim.fn.mkdir(fixture .. "/notes/agent-memory/dotfiles", "p")
vim.fn.writefile({ "# Agent memory" }, fixture .. "/notes/agent-memory/dotfiles/dashboard.md")
local recent, recent_total = dashboard._collect_section(fixture, {
  dir = "notes",
  exclude = { "projects", "agent-memory" },
}, false)
assert(#recent == 2 and recent_total == 2, "project and agent memory notes can be excluded from recent notes")
local branches, branch_total = dashboard._collect_section(fixture, {
  dir = "notes/projects",
  exclude = { "index.md" },
}, false)
assert(branch_total == 1 and branches[1].relative_path == "notes/projects/dotfiles/master.md",
  "branch section excludes repository index notes")
local note_directories = dashboard._section_directories(fixture, {
  dir = "notes",
  exclude = { "projects", "agent-memory" },
})
assert(#note_directories == 2, "note creation lists the section root and allowed subdirectories")
assert(note_directories[1].relative_path == "" and note_directories[2].relative_path == "nested",
  "note creation directories are sorted and respect exclusions")
assert(dashboard._valid_note_name("Casual note.md") == "Casual note", "optional markdown suffix is removed")
assert(dashboard._valid_note_name("nested/note") == nil, "note names cannot escape the selected directory")
assert(dashboard._valid_note_name("  ") == nil, "empty note names are rejected")
local searchable_note = {
  path = fixture .. "/notes/nested/newest.md",
  relative_path = "notes/nested/newest.md",
  aliases = { "Newest alias" },
}
local searchable_section = { title = "Recent notes", dir = "notes" }
assert(dashboard._matches_query(searchable_note, searchable_section, "NEWEST"), "filter ignores case")
assert(dashboard._matches_query(searchable_note, searchable_section, "newest alias"), "filter matches aliases")
assert(dashboard._matches_query(searchable_note, searchable_section, "recent"), "filter matches section names")
assert(not dashboard._matches_query(searchable_note, searchable_section, "missing"), "filter rejects unrelated text")

dashboard.setup({
  show_aliases = false,
  sections = { { title = "Notes", dir = "notes", limit = 2, exclude = { "projects", "agent-memory" } } },
})
assert(vim.fn.exists(":ObsidianDashboard") == 2, "dashboard command is registered")
vim.wo.number = true
vim.wo.signcolumn = "yes"
vim.wo.wrap = true
local original_tabpage = vim.api.nvim_get_current_tabpage()
local original_bufnr = vim.api.nvim_get_current_buf()
local dashboard_bufnr = vim.api.nvim_create_buf(false, true)
local dashboard_winid = dashboard._show_in_tab(dashboard_bufnr)
assert(vim.api.nvim_get_current_tabpage() ~= original_tabpage, "dashboard opens in a dedicated tab")
assert(vim.api.nvim_win_get_buf(dashboard_winid) == dashboard_bufnr, "dashboard buffer is shown in the new tab")
dashboard._configure_window(dashboard_winid)
assert(vim.wo[dashboard_winid].number, "dashboard preserves the configured line numbers")
assert(vim.wo[dashboard_winid].signcolumn == "yes", "dashboard preserves the configured sign column")
assert(vim.wo[dashboard_winid].wrap, "dashboard preserves the configured line wrapping")
assert(vim.wo[dashboard_winid].foldmethod == "expr", "dashboard uses its dedicated fold expression")
assert(vim.wo[dashboard_winid].foldexpr:find("foldexpr", 1, true), "dashboard window calls the dashboard fold expression")
assert(vim.wo[dashboard_winid].foldcolumn == "0", "dashboard hides fold markers from the gutter")
assert(vim.wo[dashboard_winid].foldlevel == 99, "dashboard sections start open")
dashboard.refresh(dashboard_bufnr, fixture)
local rendered_lines = vim.api.nvim_buf_get_lines(dashboard_bufnr, 0, -1, false)
local rendered_heading_line
local rendered_note_line
local rendered_separator_line
for line_number, line in ipairs(rendered_lines) do
  if line == "NOTES              notes/  (2)" then
    rendered_heading_line = line_number
  elseif line:find("notes/nested/newest.md", 1, true) then
    rendered_note_line = line_number
  elseif rendered_heading_line and line == "" and not rendered_separator_line then
    rendered_separator_line = line_number
  end
end
vim.api.nvim_win_call(dashboard_winid, function()
  assert(vim.fn.foldlevel(rendered_heading_line) == 1, "configured section headings start level-one folds")
  assert(vim.fn.foldlevel(rendered_note_line) == 1, "note rows belong to their configured section fold")
  assert(vim.fn.foldlevel(rendered_separator_line) == 0, "blank separators remain outside section folds")
  assert(vim.fn.foldlevel(#rendered_lines) == 0, "dashboard help remains outside section folds")
  vim.api.nvim_win_set_cursor(dashboard_winid, { rendered_heading_line, 0 })
  vim.cmd("normal! zc")
  assert(vim.fn.foldclosed(rendered_heading_line) == rendered_heading_line, "dashboard section folds can be closed")
  assert(vim.fn.foldclosedend(rendered_heading_line) == rendered_separator_line - 1,
    "closed dashboard sections leave their trailing separator visible")
end)
dashboard.refresh(dashboard_bufnr, fixture)
vim.api.nvim_win_call(dashboard_winid, function()
  assert(vim.fn.foldclosed(rendered_heading_line) == rendered_heading_line, "refresh preserves closed dashboard sections")
end)
assert(vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_get_win(original_tabpage)) == original_bufnr,
  "opening the dashboard preserves the original tab")
local dashboard_tabpage = vim.api.nvim_get_current_tabpage()
dashboard._show_in_tab(dashboard_bufnr)
assert(vim.api.nvim_get_current_tabpage() == dashboard_tabpage, "an open dashboard tab is reused")
dashboard._register_session(dashboard_bufnr)
assert(dashboard.is_open(), "dashboard remains open when its tab shows another buffer")
dashboard.close()
vim.wait(100, function()
  return not vim.api.nvim_buf_is_valid(dashboard_bufnr)
end)
assert(not dashboard.is_open(), "closing the dashboard ends its session")
assert(vim.api.nvim_get_current_tabpage() == original_tabpage, "closing the dashboard returns to the original tab")
assert(not vim.api.nvim_buf_is_valid(dashboard_bufnr), "closing the dashboard cleans up its hidden buffer")
local disposable_bufnr = vim.api.nvim_create_buf(true, false)
local modified_bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(modified_bufnr, 0, -1, false, { "modified" })
local kept = dashboard._cleanup_opened_buffers({
  [disposable_bufnr] = true,
  [modified_bufnr] = true,
})
assert(not vim.api.nvim_buf_is_valid(disposable_bufnr), "closing the dashboard tab deletes its unmodified buffers")
assert(vim.api.nvim_buf_is_valid(modified_bufnr) and kept[modified_bufnr],
  "closing the dashboard tab preserves modified buffers")
vim.api.nvim_buf_delete(modified_bufnr, { force = true })
local preview_bufnr = vim.api.nvim_create_buf(true, false)
local preview_state = {
  preview_bufnr = preview_bufnr,
  preview_created = true,
  preview_was_listed = false,
}
dashboard._release_preview_buffer(preview_state)
assert(preview_state.opened_buffers[preview_bufnr],
  "preview buffers created by the dashboard remain tracked after switching previews")
dashboard._cleanup_opened_buffers(preview_state.opened_buffers)
assert(not vim.api.nvim_buf_is_valid(preview_bufnr),
  "tracked preview buffers are deleted when the dashboard session ends")
local pin_ok, pin_err = dashboard._write_pin(fixture .. "/notes/older.md", true)
assert(pin_ok, "dashboard pins are persisted in note frontmatter: " .. tostring(pin_err))
local pinned, pinned_total, pinned_paths = dashboard._collect_pinned(fixture, false)
assert(pinned_total == 1 and pinned[1].relative_path == "notes/older.md", "pinned notes are collected vault-wide")
assert(pinned_paths[vim.fs.normalize(fixture .. "/notes/older.md")], "pinned paths are indexed for deduplication")
local model = dashboard._build_model(fixture)
assert(vim.tbl_contains(model.lines, "PINNED NOTES       (1)"), "pinned notes are rendered above configured sections")
assert(vim.tbl_contains(model.lines, "NOTES              notes/  (1)"),
  "pinned notes are excluded from section counts:\n" .. table.concat(model.lines, "\n"))
local pinned_heading_line
local heading_line
local nested_note_line
for line_number, line in ipairs(model.lines) do
  if line == "PINNED NOTES       (1)" then
    pinned_heading_line = line_number
  elseif line == "NOTES              notes/  (1)" then
    heading_line = line_number
  elseif line:find("notes/nested/newest.md", 1, true) then
    nested_note_line = line_number
  end
end
assert(model.navigation_headers[pinned_heading_line], "pinned heading participates in section navigation")
assert(model.fold_levels[pinned_heading_line] == ">1", "pinned notes have an independent fold")
assert(dashboard._section_target(model.navigation_headers, pinned_heading_line, 1, 1) == heading_line,
  "]] moves from pinned notes to the first configured section")
assert(model.section_headers[heading_line].dir == "notes", "only the section heading selects folder choice")
assert(model.section_headers[pinned_heading_line] == nil, "pinned heading is not a note creation target")
assert(model.section_headers[nested_note_line] == nil, "note rows do not trigger section folder choice")
assert(vim.fs.dirname(model.entries[nested_note_line].path) == fixture .. "/notes/nested",
  "note rows resolve their own directory")
assert(model.lines[#model.lines]:find("<CR> open", 1, true), "dashboard help is rendered")
assert(model.lines[#model.lines]:find("P preview", 1, true), "dashboard advertises right-side preview")
assert(model.lines[#model.lines]:find("a add", 1, true), "dashboard advertises section note creation")
assert(model.lines[#model.lines]:find("p pin", 1, true), "dashboard advertises pin toggling")
assert(model.lines[#model.lines]:find("i ignore", 1, true), "dashboard advertises ignore toggling")
assert(model.lines[#model.lines]:find("r rename", 1, true), "dashboard advertises note renaming")
assert(model.lines[#model.lines]:find("x delete", 1, true), "dashboard advertises note deletion")
assert(model.lines[#model.lines]:find("[[/]] sections", 1, true), "dashboard advertises section navigation")
assert(model.lines[#model.lines]:find("/ filter", 1, true), "dashboard advertises in-place filtering")
assert(model.lines[#model.lines]:find("gb knowledge", 1, true), "Knowledge Base does not shadow k movement")
local filename_highlight
for _, highlight in ipairs(model.highlights) do
  local line = model.lines[highlight.row + 1]
  if highlight.group == "Directory" and line and line:find("notes/nested/newest.md", 1, true) then
    filename_highlight = line:sub(highlight.start_col + 1, highlight.end_col)
  end
end
assert(filename_highlight == "newest.md", "dashboard colors only the filename")

local filtered_model = dashboard._build_model(fixture, "newest")
local filtered = table.concat(filtered_model.lines, "\n")
assert(filtered:find("Filter newest", 1, true), "dashboard displays the active filter")
assert(filtered:find("NOTES              notes/  (1/1)", 1, true), "filtered section shows matches and unpinned total")
assert(filtered:find("notes/nested/newest.md", 1, true), "matching notes remain visible")
assert(not filtered:find("notes/older.md", 1, true), "non-matching notes are hidden")
assert(dashboard._write_pin(fixture .. "/notes/older.md", false), "dashboard pins can be removed")
local unpinned, unpinned_total = dashboard._collect_pinned(fixture, false)
assert(#unpinned == 0 and unpinned_total == 0, "unpinning removes the note from the pinned collection")
local unpinned_model = table.concat(dashboard._build_model(fixture).lines, "\n")
assert(not unpinned_model:find("PINNED NOTES", 1, true), "the pinned section is hidden when it is empty")

assert(dashboard._write_ignore(fixture .. "/notes/older.md", true), "dashboard ignores are persisted in note frontmatter")
local ignored, ignored_total, ignored_paths = dashboard._collect_ignored(fixture, false)
assert(ignored_total == 1 and ignored[1].relative_path == "notes/older.md", "ignored notes are collected vault-wide")
assert(ignored_paths[vim.fs.normalize(fixture .. "/notes/older.md")], "ignored paths are indexed for exclusion")
local ignored_model = dashboard._build_model(fixture)
local ignored_heading_line
local ignored_note_line
local ignored_notes_heading_line
for line_number, line in ipairs(ignored_model.lines) do
  if line == "IGNORED NOTES      (1)" then
    ignored_heading_line = line_number
  elseif line == "NOTES              notes/  (1)" then
    ignored_notes_heading_line = line_number
  elseif line:find("notes/older.md", 1, true) then
    ignored_note_line = line_number
  end
end
assert(ignored_heading_line and ignored_note_line > ignored_heading_line, "ignored notes are rendered in a bottom section")
assert(ignored_heading_line > ignored_notes_heading_line, "ignored section follows all configured sections")
assert(ignored_model.navigation_headers[ignored_heading_line], "ignored heading participates in section navigation")
assert(ignored_model.fold_levels[ignored_heading_line] == ">1", "ignored notes have an independent fold")
assert(ignored_model.fold_levels[ignored_note_line] == "1", "ignored note rows belong to the ignored fold")
assert(dashboard._section_target(ignored_model.navigation_headers, ignored_heading_line, -1, 1) == ignored_notes_heading_line,
  "[[ moves from ignored notes to the last configured section")
assert(ignored_model.section_headers[ignored_heading_line] == nil, "ignored heading is not a note creation target")
local ignored_line_is_dimmed = false
for _, highlight in ipairs(ignored_model.highlights) do
  if highlight.row + 1 == ignored_note_line and highlight.group == "Comment" and highlight.start_col == 0 then
    ignored_line_is_dimmed = true
  end
end
assert(ignored_line_is_dimmed, "ignored note rows use the subdued Comment highlight")
assert(vim.tbl_contains(ignored_model.lines, "NOTES              notes/  (1)"),
  "ignored notes are excluded from normal section counts")

assert(dashboard._write_pin(fixture .. "/notes/older.md", true), "pinning an ignored note succeeds")
local no_longer_ignored, no_longer_ignored_total = dashboard._collect_ignored(fixture, false)
assert(#no_longer_ignored == 0 and no_longer_ignored_total == 0, "pinning clears the mutually exclusive ignore flag")
assert(dashboard._write_ignore(fixture .. "/notes/older.md", true), "ignoring a pinned note succeeds")
local no_longer_pinned, no_longer_pinned_total = dashboard._collect_pinned(fixture, false)
assert(#no_longer_pinned == 0 and no_longer_pinned_total == 0, "ignoring clears the mutually exclusive pin flag")
assert(dashboard._write_ignore(fixture .. "/notes/older.md", false), "ignored notes can be restored")

local section_headers = { [4] = true, [10] = true, [18] = true, [25] = true }
assert(dashboard._section_target(section_headers, 4, 1, 1) == 10, "]] moves to the next section")
assert(dashboard._section_target(section_headers, 15, -1, 1) == 10, "[[ moves to the section above")
assert(dashboard._section_target(section_headers, 4, 1, 2) == 18, "section navigation honors a count")
assert(dashboard._section_target(section_headers, 25, 1, 1) == nil, "]] does not wrap at the last section")
assert(dashboard._section_target(section_headers, 4, -1, 1) == nil, "[[ does not wrap at the first section")

vim.fn.delete(fixture, "rf")
print("ok - dashboard_spec")
