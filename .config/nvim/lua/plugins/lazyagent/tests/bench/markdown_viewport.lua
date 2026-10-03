-- Integration contract against the installed external renderer and parsers.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
local output = assert(vim.env.LAZYAGENT_BENCH_OUT, "set LAZYAGENT_BENCH_OUT")
vim.opt.rtp:prepend(root)
vim.opt.rtp:append(assert(vim.env.LAZYAGENT_MARKDOWN_RTP, "set LAZYAGENT_MARKDOWN_RTP"))
vim.opt.rtp:append(assert(vim.env.LAZYAGENT_PARSER_RTP, "set LAZYAGENT_PARSER_RTP"))
vim.opt.swapfile = false
vim.treesitter.language.register("markdown", "lazyagent_acp")
require("render-markdown").setup({
  file_types = { "lazyagent_acp" },
  anti_conceal = { enabled = false },
  code = { language = false, sign = false, width = "block", left_pad = 1, right_pad = 1 },
})
local Context = require("render-markdown.request.context")
local Marks = require("render-markdown.lib.marks")
local Node = require("render-markdown.lib.node")
local Code = require("render-markdown.render.markdown.code")
local Bounded = require("lazyagent.render_markdown_code")
local state = require("render-markdown.state")
local query = vim.treesitter.query.parse("markdown", "(fenced_code_block) @code")
local highlighter = require("lazyagent.acp.highlighter")
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, buf)
highlighter.start(buf)
vim.bo[buf].filetype = "lazyagent_acp"
local config = state.get(buf)
local results = {}
local configurations = {
  { width = "block", left_pad = 1, left_margin = 0, disable_background = false },
  { width = "full", left_pad = 2, left_margin = 2, disable_background = false },
  { width = "block", left_pad = 0, left_margin = 0, disable_background = true },
}
for _, rows in ipairs({ 30, 7000 }) do
  for _, indent in ipairs({ "", "  " }) do
    local lines = { indent .. "```lua" }
    for i = 1, rows do lines[#lines + 1] = i % 5 == 0 and "" or indent .. 'local value = "hello"' end
    lines[#lines + 1] = indent .. "```"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local parser = assert(vim.treesitter.get_parser(buf, "markdown"))
    local trees = parser:parse(true)
    local fence
    for _, ts_node in query:iter_captures(trees[1]:root(), buf) do fence = Node.new(buf, ts_node); break end
    assert(fence, "the real parser supplies a fenced-code node")
    for _, options in ipairs(configurations) do
      for key, value in pairs(options) do config.code[key] = value end
      local context = Context.new(buf, vim.api.nvim_get_current_win(), config)
      -- Disjoint windows on one large block, then a direct jump into its middle.
      for _, ranges in ipairs({ { { 0, 10 }, { rows - 10, rows + 1 } }, { { math.floor(rows / 2), math.floor(rows / 2) + 10 } } }) do
        context.view.ranges = ranges
        local function visible(mark)
          for _, range in ipairs(ranges) do
            if mark.start_row >= range[1] and mark.start_row <= range[2] then return true end
          end
          return false
        end
        local marks = Marks.new(context, false)
        local started = vim.uv.hrtime()
        Code:execute(context, marks, fence)
        local original_ms = (vim.uv.hrtime() - started) / 1e6
        local original = marks:get()
        marks = Marks.new(context, false)
        started = vim.uv.hrtime()
        Bounded:execute(context, marks, fence)
        local bounded_ms = (vim.uv.hrtime() - started) / 1e6
        local bounded = marks:get()
        assert(vim.deep_equal(vim.tbl_filter(visible, original), vim.tbl_filter(visible, bounded)),
          "visible marks match upstream across indent, padding, backgrounds, widths and split/jump ranges")
        assert(#bounded < 100, "a giant block cannot materialize every body row")
        results[#results + 1] = { rows = rows, indent = #indent, options = vim.deepcopy(options),
          ranges = ranges, original_marks = #original, bounded_marks = #bounded,
          original_ms = original_ms, bounded_ms = bounded_ms }
      end
    end
  end
end
assert(not vim.treesitter.highlighter.active[buf]._conceal_line,
  "ACP does not use native synchronous line-conceal queries")
assert(vim.treesitter.query.get("markdown", "highlights").has_conceal_line,
  "ordinary Markdown's global highlight query is preserved")
local lua_tree = vim.treesitter.get_parser(buf):children().lua
assert(lua_tree and next(lua_tree:trees()), "injected Lua syntax is still parsed")
vim.fn.writefile({ vim.json.encode({ samples = results, visible_marks_match = true,
  native_line_conceal = false, injected_lua = true }) }, output)
vim.api.nvim_buf_delete(buf, { force = true })
print("external Markdown viewport contract passed")
