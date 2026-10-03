local M = {}

local function markdown_query()
  local parts = {}
  for _, path in ipairs(vim.treesitter.query.get_files("markdown", "highlights")) do
    parts[#parts + 1] = table.concat(vim.fn.readfile(path), "\n")
  end
  -- render-markdown supplies its own borders and line concealment. Native
  -- conceal_lines queries make window layout synchronously parse injections
  -- while checking individual rows, bypassing the async highlight parser.
  -- Keep character conceal and every highlight; scope the copy to this buffer.
  return table.concat(parts, "\n"):gsub("%(%#set!%s+[^%)]-conceal_lines[^%)]*%)", "")
end

function M.start(bufnr)
  pcall(require("lazyagent.render_markdown").enable_async_view_parse)
  local highlighter = vim.treesitter.highlighter
  if highlighter.active[bufnr] then
    return
  end
  local parser = assert(vim.treesitter.get_parser(bufnr, "markdown"))
  highlighter.new(parser, { queries = { markdown = markdown_query() } })
end

return M
