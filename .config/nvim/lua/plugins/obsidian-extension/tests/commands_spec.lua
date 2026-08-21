local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(source))

vim.opt.runtimepath:prepend(root)
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local commands = require("obsidian_extension.features.commands")

local candidates = commands._related_branch_names("feature/hoge", {
  "main",
  "feature/hoge-test",
  "feature/hoge-re",
  "feature/other",
})
assert(vim.deep_equal(candidates, {
  "feature/hoge",
  "feature/hoge-re",
  "feature/hoge-test",
}), "exact branch is first and derived branches follow")

local from_derived = commands._related_branch_names("feature/hoge-re", {
  "feature/hoge",
  "feature/hoge-test",
})
assert(vim.deep_equal(from_derived, {
  "feature/hoge-re",
  "feature/hoge",
  "feature/hoge-test",
}), "derived branch finds its base and sibling notes")

assert(vim.deep_equal(commands._related_branch_names("feature/solo", { "main" }), {
  "feature/solo",
}), "unrelated branches do not trigger a picker")

print("ok - commands_spec")
