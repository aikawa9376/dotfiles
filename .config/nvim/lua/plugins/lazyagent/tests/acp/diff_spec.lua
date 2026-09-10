local M = {}

function M.run()
  local diff = require("lazyagent.acp.diff")
  local lines = diff.format_diff_item({
    path = "README.md",
    oldText = "",
    newText = "```sh\necho hello\n```\n`````",
  })
  assert(lines[2] == "``````markdown" and lines[#lines] == "``````",
    "generated Markdown diffs use a wrapper longer than embedded fences")
  local parsed = diff.parse_rendered_diff_block(vim.list_slice(lines, 3, #lines - 1))
  assert(vim.deep_equal(parsed.new_lines, { "```sh", "echo hello", "```", "`````" }),
    "diff content remains available for navigation and review")
  local ordinary = diff.format_diff_item({ path = "test.lua", oldText = "", newText = "return true" })
  assert(ordinary[2] == "```lua" and ordinary[#ordinary] == "```",
    "ordinary diffs keep their existing fence")
end

return M
