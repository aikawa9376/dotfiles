-- Real renderer/parser contract for edited trees and normal list appearance.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
vim.opt.rtp:prepend(root)
vim.opt.rtp:append(assert(vim.env.LAZYAGENT_MARKDOWN_RTP))
vim.opt.rtp:append(assert(vim.env.LAZYAGENT_PARSER_RTP))
vim.opt.swapfile = false
require("render-markdown").setup({
  file_types = { "lazyagent_acp" }, anti_conceal = { enabled = false },
  custom_handlers = { markdown = { parse = require("lazyagent.render_markdown").parse } },
})
local Node = require("render-markdown.lib.node")
local Bounded = require("lazyagent.render_markdown_node")
local native_count = Node.sibling_count
local Context = require("render-markdown.request.context")
local Marks = require("render-markdown.lib.marks")
local List = require("render-markdown.render.markdown.list")
local state = require("render-markdown.state")
local adapter = require("lazyagent.render_markdown")
local buf = vim.api.nvim_get_current_buf()
vim.bo[buf].filetype = "lazyagent_acp"
vim.treesitter.language.register("markdown", "lazyagent_acp")
local lines = { "# Heading", "", "* first", "* second", "  * nested", "", "1. ordered", "2. next" }
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
local parser = assert(vim.treesitter.get_parser(buf, "markdown"))
require("lazyagent.acp.injections").guard(parser)
local tree = parser:parse(true)[1]
local query = vim.treesitter.query.parse("markdown", "(list_item) @list")
local first, checked = nil, 0
for _, ts_node in query:iter_captures(tree:root(), buf) do
  first = first or ts_node
  local function render(bounded)
    local context = Context.new(buf, vim.api.nvim_get_current_win(), state.get(buf))
    local marks = Marks.new(context, false)
    local node = Node.new(buf, ts_node)
    if bounded then node = Bounded.wrap(node) end
    List:execute(context, marks, node)
    return marks:get()
  end
  assert(vim.deep_equal(render(false), render(true)), "valid nested and ordered list marks match upstream")
  checked = checked + 1
end
assert(checked == 5, "all normal list items were compared")

-- A live root can still yield an empty stale capture. Check this independently
-- of the collapsed-root fast path, and require the following real item to draw.
local context = Context.new(buf, vim.api.nvim_get_current_win(), state.get(buf))
local valid_node = Node.new(buf, first)
local empty = setmetatable({ start_row = 0, start_col = 0, end_row = 0, end_col = 0 }, {
  __index = function() error("an empty capture must be rejected before structural rendering") end,
})
context.view.nodes = function(_, _, _, callback)
  callback("list", empty)
  callback("list", Node.new(buf, first))
end
local marks = adapter.parse({ buf = buf, root = tree:root() })
assert(#marks > 0, "valid content after an empty capture still renders")
local expected_context = Context.new(buf, vim.api.nvim_get_current_win(), state.get(buf))
local expected_marks = Marks.new(expected_context, false)
List:execute(expected_context, expected_marks, Bounded.wrap(valid_node))
assert(vim.deep_equal(marks, expected_marks:get()), "empty captures add no marks or duplicate healthy ones")

-- Native edits retain collapsed injection trees until the relevant region is
-- reparsed. Exercise the actual stale TSTree, not a fabricated root range.
local nested = { "```markdown", "- old one", "- old two", "```", "", "tail" }
vim.api.nvim_buf_set_lines(buf, 0, -1, false, nested)
parser:parse(true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "new reply", "" })
local collapsed = 0
parser:for_each_tree(function(stale, langtree)
  if langtree:lang() ~= "markdown" or not langtree:parent() then return end
  local sr, sc, er, ec = stale:root():range()
  if sr == er and sc == ec then
    collapsed = collapsed + 1
    assert(#adapter.parse({ buf = buf, root = stale:root() }) == 0, "edited empty roots never reach the renderer")
  end
end)
assert(collapsed > 0, "the real parser retained a collapsed injected Markdown tree")
assert(Node.sibling_count == native_count, "ordinary Markdown keeps the original node method")

-- Exercise actual gC projection toggles with the native highlighter and
-- installed external renderer, without starting a provider or reading history.
local path = vim.fn.tempname() .. "-markdown-toggle.log"
local transcript = { "─ User ─", "question", "─ Tool ─", "```markdown", "- old one", "- old two", "```", "─ Assistant ─", "- answer", "- next" }
vim.fn.writefile(transcript, path)
local logic = require("lazyagent.logic.state")
logic.opts = { acp = { footer_animation = false } }
local view = require("lazyagent.acp.view_buffer")
local pane, info
view.create_pane({ transcript_path = path, size = 12,
  acp = { agent_name = "markdown-toggle-test", source_winid = vim.api.nvim_get_current_win() },
}, function(id, result) pane, info = id, result end)
assert(vim.wait(2000, function() return pane ~= nil end, 10))
vim.api.nvim_set_current_win(info.winid)
local ui = require("render-markdown.core.ui")
for iteration = 1, 30 do
  vim.fn.maparg("gC", "n", false, true).callback()
  local current = assert(vim.treesitter.get_parser(info.bufnr, "markdown"))
  local done = false
  current:parse(true, function(err, trees) assert(not err and trees); done = true end)
  assert(vim.wait(2000, function() return done end, 10), "toggle parse finishes")
  ui.updater.new(info.bufnr, info.winid, true):run()
  vim.wait(10)
  local text = table.concat(vim.api.nvim_buf_get_lines(info.bufnr, 0, -1, false), "\n")
  assert(text:find("answer", 1, true), "repeated toggles preserve replies")
  assert((text:find("old one", 1, true) ~= nil) == (iteration % 2 == 0), "gC actually changes the projection")
end
view.kill_pane(pane)
vim.fn.delete(path)
print("stale Markdown captures, native list appearance, and 30 gC toggles passed")
