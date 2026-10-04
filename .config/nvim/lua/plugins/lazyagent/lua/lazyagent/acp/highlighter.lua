local M = {}

local function recover_async_parse(parser, bufnr)
  if parser._lazyagent_parse_recovery then return end
  parser._lazyagent_parse_recovery = true
  local parse = parser.parse
  parser.parse = function(self, ranges, callback)
    if not callback then return parse(self, ranges) end
    local tick = vim.api.nvim_buf_get_changedtick(bufnr)
    local retries = 0
    local function complete(err, trees)
      -- Timed-out parses retain completed trees. A bounded retry can finish the
      -- remaining injections without forcing synchronous parsing or increasing
      -- redrawtime for every buffer. This also serves render-markdown callers.
      if err == "TIMEOUT" and retries < 2 and vim.api.nvim_buf_is_valid(bufnr)
        and vim.api.nvim_buf_get_changedtick(bufnr) == tick and #vim.fn.win_findbuf(bufnr) > 0 then
        retries = retries + 1
        vim.defer_fn(function()
          if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_changedtick(bufnr) == tick
            and #vim.fn.win_findbuf(bufnr) > 0 then
            parse(self, ranges, complete)
          else
            complete("CANCELLED", nil)
          end
        end, 25 * retries)
        return
      end
      callback(err, trees)
      if err then
        -- Native _on_start clears `parsing` only when it receives trees. Defer
        -- cleanup: a synchronous timeout precedes its assignment of that flag.
        vim.schedule(function()
          local active = vim.treesitter.highlighter.active[bufnr]
          if active and active.tree == self then active.parsing = false end
        end)
      end
    end
    return parse(self, ranges, complete)
  end
end

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
    recover_async_parse(highlighter.active[bufnr].tree, bufnr)
    return
  end
  local parser = assert(vim.treesitter.get_parser(bufnr, "markdown"))
  recover_async_parse(parser, bufnr)
  highlighter.new(parser, { queries = { markdown = markdown_query() } })
end

return M
