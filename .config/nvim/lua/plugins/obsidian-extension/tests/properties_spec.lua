local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(source))

vim.opt.runtimepath:prepend(root)
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local properties = require("obsidian_extension.features.properties")
local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, bufnr)
vim.bo[bufnr].filetype = "markdown"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "---",
  "id: test",
  "tags: []",
  "---",
  "",
  "# Test",
})

assert(properties.frontmatter_end(bufnr) == 4, "frontmatter range")
properties.configure_buffer(bufnr)
assert(vim.wo.foldenable == true, "folding enabled")
assert(vim.fn.foldclosed(1) == 1, "properties folded by default")
assert(vim.fn.foldclosedend(1) == 4, "properties fold range")
assert(vim.fn.foldtextresult(1) == "─ property ─", "properties fold heading")

local filtered = properties.filter_render_marks(bufnr, {
  { conceal = "dash", start_row = 0 },
  { conceal = "dash", start_row = 3 },
  { conceal = "dash", start_row = 10 },
  { conceal = "heading", start_row = 5 },
})
assert(#filtered == 2, "frontmatter thematic-break marks filtered")
assert(filtered[1].start_row == 10, "regular thematic break preserved")
assert(filtered[2].conceal == "heading", "unrelated render mark preserved")

vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("zo", true, false, true), "x", false)
assert(vim.fn.foldclosed(1) == -1, "zo opens properties")
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("zo", true, false, true), "x", false)
assert(vim.fn.foldclosed(1) == 1, "zo closes properties")

vim.cmd("silent! 5,6fold")
vim.cmd("silent! 5foldclose")
vim.api.nvim_win_set_cursor(0, { 5, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("zo", true, false, true), "x", false)
assert(vim.fn.foldclosed(5) == -1, "zo keeps its standard behavior outside properties")

print("ok - properties_spec")
