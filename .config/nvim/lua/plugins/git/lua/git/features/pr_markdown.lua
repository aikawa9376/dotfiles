-- Optional Markdown renderer integration with independently parsed PR bodies.
local M = {}
local prepared = {}
local function backend()
  local names = { 'inkstone', 'render-markdown' }
  local preferred = vim.g.markdown_renderer
  if preferred == 'inkstone' or preferred == 'render-markdown' then
    local ok, renderer = pcall(require, preferred)
    if ok and renderer.initialized and type(renderer.render) == 'function' then return preferred, renderer end
  end
  -- Reuse a configured renderer before asking lazy.nvim to load another one.
  for _, name in ipairs(names) do
    local renderer = package.loaded[name]
    if type(renderer) == 'table' and renderer.initialized then return name, renderer end
  end
  for _, name in ipairs(names) do
    local ok, renderer = pcall(require, name)
    if ok and renderer.initialized and type(renderer.render) == 'function' then return name, renderer end
  end
end
function M.prepare(buf)
  if prepared[buf] then return true end
  local name, renderer = backend()
  if not renderer then return false end
  if not pcall(vim.treesitter.language.add, 'markdown_inline') then return false end
  local parser_ok, parser = pcall(vim.treesitter.get_parser, buf, 'markdown')
  if not parser_ok or not parser then return false end
  -- {} means the entire source to LanguageTree; use an explicit empty region.
  parser:set_included_regions({ { { 0, 0, 0, 0 } } })
  vim.b[buf].git_pr_markdown_ranges = {}
  vim.treesitter.language.register('markdown', { 'gitpr', 'gitissue' })
  local syntax = vim.bo[buf].syntax
  if not vim.treesitter.highlighter.active[buf] then pcall(vim.treesitter.start, buf, 'markdown') end
  if vim.bo[buf].syntax ~= syntax then vim.bo[buf].syntax = syntax end
  prepared[buf] = { parser = parser, renderer = renderer, name = name,
    ns = vim.api.nvim_create_namespace(name .. '.nvim') }
  vim.api.nvim_create_autocmd('BufWipeout', { buffer = buf, once = true, callback = function() prepared[buf] = nil end })
  return true
end
function M.update(buf, ranges)
  if not vim.api.nvim_buf_is_valid(buf) or not M.prepare(buf) then return end
  local regions, bounds = {}, {}
  for _, range in ipairs(ranges or {}) do
    local first, last = range[1], range[2]
    if last > first then
      regions[#regions + 1] = { { first, 0, last, 0 } }
      bounds[#bounds + 1] = { first, last }
    end
  end
  vim.b[buf].git_pr_markdown_ranges = bounds
  if #regions == 0 then regions = { { { 0, 0, 0, 0 } } } end
  local state = prepared[buf]
  state.parser:set_included_regions(regions)
  if #bounds == 0 then vim.api.nvim_buf_clear_namespace(buf, state.ns, 0, -1) end
  pcall(state.renderer.render, { buf = buf })
end
function M.active(buf) return prepared[buf] ~= nil end
-- render-markdown's document/code padding may reach beyond its AST node.
-- Keep decorations within one body; title, author rows and other sections stay raw.
function M.filter(buf, marks)
  local ranges = vim.b[buf].git_pr_markdown_ranges or {}
  return vim.tbl_filter(function(mark)
    local first = mark.start_row
    local last = mark.opts.end_row or first
    if mark.opts.end_col == 0 and last > first then last = last - 1 end
    for _, range in ipairs(ranges) do
      if first >= range[1] and last < range[2] then return true end
    end
    return false
  end, marks)
end
function M.parse(ctx)
  if not prepared[ctx.buf] or #(vim.b[ctx.buf].git_pr_markdown_ranges or {}) == 0 then return {} end
  return M.filter(ctx.buf, require(prepared[ctx.buf].name .. '.handler.markdown').parse(ctx))
end
return M
