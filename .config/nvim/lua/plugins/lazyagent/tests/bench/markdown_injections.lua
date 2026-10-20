-- Real parser/renderer regression: edited, off-screen nested Markdown trees
-- must never turn empty clipped captures into whole-buffer injections.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
vim.opt.rtp:prepend(root)
vim.opt.rtp:append(assert(vim.env.LAZYAGENT_MARKDOWN_RTP))
vim.opt.rtp:append(assert(vim.env.LAZYAGENT_PARSER_RTP))
vim.opt.swapfile = false
require("render-markdown").setup({ file_types = { "lazyagent_acp" }, anti_conceal = { enabled = false } })
local Context = require("render-markdown.request.context")
local handlers = require("render-markdown.core.handlers")
local state = require("render-markdown.state")
local guard = require("lazyagent.acp.injections").guard
local native_add = require("vim.treesitter.languagetree")._add_injections
local results = {}
for _, guarded in ipairs({ false, true }) do
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  vim.bo[buf].filetype = "lazyagent_acp"
  local lines = { "```markdown", "first **text**", "```", "",
    "```markdown", "second **text**", "```", "", "[README](/tmp/README.md)" }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local parser = assert(vim.treesitter.get_parser(buf, "markdown"))
  if guarded then guard(parser) end
  parser:parse(true)
  local peak_full, peak_icons = 0, 0
  for iteration = 1, 30 do
    -- This is a replacement, not a pure append. ACP updates tool/reply blocks
    -- in place; a viewport request leaves the first code block unparsed.
    lines[6] = "second **text** " .. iteration
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    parser:parse({ 4, #lines })
    local full = 0
    parser:for_each_tree(function(tree, langtree)
      if langtree:parent() then
        for _, range in ipairs(tree:included_ranges(true)) do
          if range[4] == 4294967295 then full = full + 1 end
        end
      end
    end)
    local context = Context.new(buf, vim.api.nvim_get_current_win(), state.get(buf))
    context.view.ranges = { { 4, #lines } }
    local icons = 0
    for _, mark in ipairs(handlers.run(context, parser)) do
      if mark.start_row == 8 and mark.opts.virt_text then icons = icons + 1 end
    end
    peak_full, peak_icons = math.max(peak_full, full), math.max(peak_icons, icons)
    if guarded then
      assert(full == 0, "injected trees stay bounded after text replacement and partial parsing")
      assert(icons == 1, "one source link renders exactly one inline icon")
    end
  end
  if guarded then
    lines[9] = "[README](/tmp/README.md) [OTHER](/tmp/OTHER.md)"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    parser:parse({ 4, #lines })
    local context = Context.new(buf, vim.api.nvim_get_current_win(), state.get(buf))
    context.view.ranges = { { 4, #lines } }
    local icons = 0
    for _, mark in ipairs(handlers.run(context, parser)) do
      if mark.start_row == 8 and mark.opts.virt_text then icons = icons + 1 end
    end
    assert(icons == 2, "distinct adjacent links retain their individual icons")
  end
  -- A jump back into the previously skipped fence still parses its text.
  parser:parse({ 0, 4 })
  local found = false
  parser:for_each_tree(function(tree, langtree)
    if langtree:lang() == "markdown_inline" and tree:root():start() == 1 then found = true end
  end)
  assert(found, "bounded parsing preserves off-screen Markdown injections on revisit")
  results[#results + 1] = { guarded = guarded, peak_full = peak_full, peak_icons = peak_icons }
  vim.api.nvim_buf_delete(buf, { force = true })
end
assert(require("vim.treesitter.languagetree")._add_injections == native_add,
  "the workaround never modifies the native LanguageTree class")
vim.fn.writefile(vim.split(vim.inspect(results), "\n", { plain = true }), assert(vim.env.LAZYAGENT_BENCH_OUT))
