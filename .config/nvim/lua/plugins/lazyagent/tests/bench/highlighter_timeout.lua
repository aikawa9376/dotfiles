-- Exercise native _on_start and real injected syntax after an async timeout.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
vim.opt.rtp:prepend(root)
vim.opt.rtp:append(assert(vim.env.LAZYAGENT_PARSER_RTP, "set LAZYAGENT_PARSER_RTP"))
vim.opt.rtp:append(assert(vim.env.LAZYAGENT_MARKDOWN_RTP, "set LAZYAGENT_MARKDOWN_RTP"))
vim.opt.swapfile = false
vim.treesitter.language.register("markdown", "lazyagent_acp")
local buf = vim.api.nvim_get_current_buf()
local lines = {}
for i = 1, 1200 do
  vim.list_extend(lines, { "## Message " .. i, "[Steering] **request**", "```lua",
    'local name = "hello"', "```", "More text with `inline code`." })
end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
local parser = assert(vim.treesitter.get_parser(buf, "markdown"))
local parse, calls = parser.parse, 0
parser.parse = function(self, ranges, callback)
  calls = calls + 1
  if calls == 1 and callback then
    -- Deterministic timeout, independent of CPU speed and user redrawtime.
    callback("TIMEOUT", nil)
    return nil
  end
  return parse(self, ranges, callback)
end
require("lazyagent.acp.highlighter").start(buf)
local native = vim.treesitter.highlighter
local highlighter = native.active[buf]
native._on_start()
assert(highlighter.parsing, "native highlighting awaits the deferred retry")
assert(vim.wait(5000, function() return not highlighter.parsing end, 10),
  "native _on_start must recover from a timed-out parse")
assert(calls >= 2, "the timeout was retried")

local completed = false
parser:parse({ { 0, 6 } }, function(err, trees) completed = not err and trees ~= nil end)
assert(vim.wait(5000, function() return completed end, 10), "visible injections finish asynchronously")
local lua = assert(parser:children().lua, "fenced Lua remains an injected language")
local query = assert(highlighter:get_query("lua"):query())
local keyword = false
for _, tree in pairs(lua:trees()) do
  for id in query:iter_captures(tree:root(), buf, 3, 4) do
    if query.captures[id]:match("^keyword") then keyword = true end
  end
end
assert(keyword, "the real Lua highlight query captures the visible local keyword")
assert(not highlighter._conceal_line, "timeout recovery preserves asynchronous line layout")
print("native timeout recovery and injected Lua highlights passed")

-- Exercise the installed renderer's request, custom handler, and actual marks.
require("render-markdown.core.log").init()
require("render-markdown.core.colors").init()
require("render-markdown").setup({
  file_types = { "lazyagent_acp" },
  debounce = 10000,
  anti_conceal = { enabled = false },
  code = { language = false, sign = false, width = "block", left_pad = 1, right_pad = 1 },
  custom_handlers = { markdown = { parse = require("lazyagent.render_markdown").parse } },
})
local rendered_buf = vim.api.nvim_create_buf(false, true)
local code = { "```lua" }
for _ = 1, 7000 do code[#code + 1] = 'local value = "hello"' end
code[#code + 1] = "```"
vim.api.nvim_buf_set_lines(rendered_buf, 0, -1, false, code)
vim.api.nvim_win_set_buf(0, rendered_buf)
vim.bo[rendered_buf].filetype = "lazyagent_acp"
local rendered_parser = assert(vim.treesitter.get_parser(rendered_buf, "markdown"))
local rendered_parse, rendered_calls = rendered_parser.parse, 0
rendered_parser.parse = function(self, ranges, callback)
  rendered_calls = rendered_calls + 1
  if rendered_calls == 1 and callback then callback("TIMEOUT", nil); return nil end
  return rendered_parse(self, ranges, callback)
end
require("lazyagent.acp.highlighter").start(rendered_buf)
local ui = require("render-markdown.core.ui")
local function marks()
  return vim.api.nvim_buf_get_extmarks(rendered_buf, ui.ns, 0, -1, {})
end
ui.updater.new(rendered_buf, vim.api.nvim_get_current_win(), true):run()
assert(#marks() == 0, "external rendering waits for the deferred timeout retry")
assert(vim.wait(5000, function() return #marks() > 0 end, 10),
  "render-markdown displays code decorations after timeout recovery")
assert(rendered_calls >= 2, "the external parse timeout was retried")
local visible_rows = 0
for _, range in ipairs(require("render-markdown.request.context").get(rendered_buf).view.ranges) do
  visible_rows = visible_rows + range[2] - range[1] + 1
end
assert(#marks() <= visible_rows * 3 + 10,
  "timeout recovery keeps giant-block marks bounded to the viewport")
print("render-markdown timeout recovery and visible code decorations passed")
