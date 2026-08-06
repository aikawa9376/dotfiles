local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(source))

vim.opt.runtimepath:prepend(root)
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local related = require("obsidian_extension.features.related")
local context = require("obsidian_extension.context")
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

local unscoped = related._rank_entries(entries, nil, "")
assert(#unscoped == 4, "empty query without Git context keeps every note searchable")

assert(related._branch_note_relative(git_context) == "notes/projects/dotfiles/master.md",
  "branch note path matches project layout")

local note_context = context._git_context_from_frontmatter({
  "---",
  "project: afiliate",
  "branch: feature/campaign",
  "---",
})
assert(note_context.repo_slug == "afiliate" and note_context.branch_name == "feature/campaign",
  "current note frontmatter supplies the related-note context")
assert(note_context.branch_note_segments[1] == "feature" and note_context.branch_note_segments[2] == "campaign",
  "frontmatter branch is converted to branch-note segments")

local captured_lines, captured_opts
package.loaded["fzf-lua"] = {
  actions = {
    file_edit_or_qf = function() end,
    file_split = function() end,
    file_vsplit = function() end,
    file_sel_to_qf = function() end,
  },
  fzf_exec = function(lines, opts)
    captured_lines, captured_opts = lines, opts
  end,
}
related._open_picker(vault, { { entry = linked, score = 280, reasons = { "project", "branch" } } }, git_context)
assert(captured_lines[1]:match("^notes/lazyagent%-usage%.md:1:1:"),
  "related picker uses the builtin file location format")
assert(captured_opts.previewer == "builtin", "related picker enables builtin preview")
assert(captured_opts.winopts == nil, "related picker inherits the global bottom split")
assert(captured_opts.prompt == "Related [dotfiles/master] > ", "related picker shows the active ranking context")
print("ok - related_spec")
