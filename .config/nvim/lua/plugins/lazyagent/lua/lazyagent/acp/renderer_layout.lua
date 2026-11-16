local M = {}

local function geometry(buf)
  local result = { windows = {},
    cpoptions = vim.o.cpoptions, ambiwidth = vim.o.ambiwidth, display = vim.o.display,
    tabstop = vim.bo[buf].tabstop, vartabstop = vim.bo[buf].vartabstop, formatlistpat = vim.bo[buf].formatlistpat }
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local entry = { win, vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win) }
    for _, name in ipairs({ "wrap", "linebreak", "breakindent", "breakindentopt", "showbreak", "number",
      "relativenumber", "numberwidth", "signcolumn", "foldcolumn", "list", "listchars" }) do
      entry[#entry + 1] = vim.wo[win][name]
    end
    result.windows[#result.windows + 1] = entry
  end
  return result
end

-- Inkstone broadcasts ParagraphGeometry for every float's lifetime/local
-- options. ACP layout depends on its own windows, not a Noice progress popup.
-- Keep real text/options/shared-window changes and all other updates intact.
function M.install(ui, callbacks)
  if ui._lazyagent_layout_guard then return end
  local previous, cache, pending = ui.update, {}, {}
  ui._lazyagent_layout_guard = cache
  ui.update = function(buf, win, event, force)
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "lazyagent_acp"
      and (force or event == "ParagraphGeometry") then
      local current = geometry(buf)
      if event == "ParagraphGeometry" and vim.deep_equal(cache[buf], current) then return end
      cache[buf] = current
      pending[buf] = true
    end
    return previous(buf, win, event, force)
  end
  local render = callbacks.render
  callbacks.render = function(event)
    if render then render(event) end
    if pending[event.buf] and vim.api.nvim_buf_is_valid(event.buf) then
      -- Inkstone owns temporary options such as disabling native linebreak.
      -- Remember the settled options only after an accepted forced update.
      cache[event.buf], pending[event.buf] = geometry(event.buf), nil
    end
  end
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = vim.api.nvim_create_augroup("LazyAgentRendererLayout", { clear = true }),
    callback = function(args) cache[args.buf], pending[args.buf] = nil, nil end,
  })
end

return M
