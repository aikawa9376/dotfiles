local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(source))

vim.opt.runtimepath:prepend(root)
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local knowledge = require("obsidian_extension.features.knowledge")
local base = table.concat(knowledge._knowledge_base_lines, "\n")

assert(base:find('name: "Agent Memory"', 1, true), "knowledge Base includes a dedicated agent memory view")
assert(base:find('filters: \'type == "agent-memory"\'', 1, true), "agent memory view filters by type")
assert(base:find('status == "seed" && type != "agent-memory"', 1, true),
  "agent memory does not clutter the Seeds view")
assert(base:find('status == "evergreen" && type != "agent-memory"', 1, true),
  "agent memory does not clutter the Evergreen view")

print("ok - knowledge_spec")
