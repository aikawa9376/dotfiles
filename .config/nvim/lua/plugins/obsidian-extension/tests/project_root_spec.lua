local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(source))

vim.opt.runtimepath:prepend(root)
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local fixture = vim.fn.tempname()
local vault = fixture .. "/vault"
local dotfiles = fixture .. "/repos/dotfiles"
local second_dotfiles = fixture .. "/archive/dotfiles"
vim.fn.mkdir(vault .. "/notes/projects/dotfiles", "p")
vim.fn.mkdir(dotfiles, "p")
vim.fn.mkdir(second_dotfiles, "p")
vim.fn.writefile({ "# dotfiles / master" }, vault .. "/notes/projects/dotfiles/master.md")

local project_root = require("obsidian_extension.features.project_root")
project_root.setup({ enabled = false })
assert(vim.tbl_isempty(vim.api.nvim_get_autocmds({ group = "ObsidianExtensionProjectRoot" })),
  "automatic project-root attachment is disabled by default")
assert(project_root._project_slug_from_path(
  vault .. "/notes/projects/dotfiles/master.md",
  vault
) == "dotfiles", "project slug is derived from the branch-note path")
assert(project_root._project_slug_from_path(vault .. "/notes/regular.md", vault) == nil,
  "regular notes do not change project root")

assert(project_root._resolve_project_root("dotfiles", {
  { name = "aikawa/dotfiles", path = dotfiles },
  { name = "workspace/other", path = fixture .. "/repos/other" },
}) == dotfiles, "project history resolves the unique matching directory basename")
assert(project_root._resolve_project_root("dotfiles", {
  { path = dotfiles },
  { path = second_dotfiles },
}) == nil, "ambiguous project directory names are not selected automatically")

vim.fn.delete(fixture, "rf")
print("ok - project_root_spec")
