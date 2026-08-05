local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(source))

vim.opt.runtimepath:prepend(root)
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local related = require("obsidian_extension.features.related")
local vault = "/vault"
related._cache.root = vault

local function note(path, lines)
  return related._parse_note(vault .. "/" .. path, path, lines)
end

local branch = note("notes/projects/dotfiles/master.md", {
  "---",
  "project: dotfiles",
  "branch: master",
  "tags: [project-note, branch-note]",
  "---",
  "# dotfiles / master",
  "- [[lazyagent-usage|lazyagent の使い方]]",
})
local linked = note("notes/lazyagent-usage.md", {
  "---",
  "aliases:",
  "- LazyAgent guide",
  "project: dotfiles",
  "branch: master",
  "status: evergreen",
  "---",
  "# lazyagent の使い方",
  "Neovimからagentを起動する。",
})
local same_project = note("notes/fugitive.md", {
  "---",
  "project: dotfiles",
  "branch: master",
  "---",
  "# Fugitive",
})
local unrelated = note("notes/marketing.md", {
  "---",
  "project: affiliate",
  "branch: master",
  "---",
  "# LazyAgent marketing",
})

assert(linked.aliases[1] == "LazyAgent guide", "frontmatter list parsed")
assert(linked.project == "dotfiles" and linked.branch == "master", "Git metadata parsed")
assert(branch.links["lazyagent-usage"], "wiki link target parsed")

local entries = {
  [branch.path] = branch,
  [linked.path] = linked,
  [same_project.path] = same_project,
  [unrelated.path] = unrelated,
}
local git_context = {
  repo_slug = "dotfiles",
  branch_name = "master",
  branch_note_segments = { "master" },
}
local ranked = related._rank_entries(entries, git_context, "Neovimから")
assert(ranked[1].entry == linked, "linked branch note with matching content ranks first")
assert(ranked[1].score > ranked[2].score, "link and query boosts affect ordering")
assert(vim.tbl_contains(ranked[1].reasons, "linked"), "ranking explains link relevance")
assert(vim.tbl_contains(ranked[1].reasons, "content"), "ranking explains content relevance")

assert(related._branch_note_relative(git_context) == "notes/projects/dotfiles/master.md",
  "branch note path matches project layout")

package.loaded["fzf-lua.previewer.builtin"] = {
  buffer_or_file = {
    extend = function() return {} end,
    parse_entry = function(_, entry) return entry end,
  },
}
local previewer = related._related_previewer()
assert(previewer.parse_entry({}, "/vault/notes/topic.md\t 280 Topic") == "/vault/notes/topic.md",
  "related preview strips ranking display from the path")
print("ok - related_spec")
