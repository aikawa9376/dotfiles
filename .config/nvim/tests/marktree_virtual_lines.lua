-- Native regression: no LazyAgent, Inkstone, parsers, or user configuration.
-- Run in an isolated process (the unpatched editor crashes):
--   nvim --headless --clean -u NONE -l .config/nvim/tests/marktree_virtual_lines.lua
local api = vim.api
vim.o.columns = 160
vim.o.swapfile = false
local buf = api.nvim_create_buf(false, true)
api.nvim_win_set_buf(0, buf)
vim.wo.wrap = true
vim.wo.conceallevel = 2
vim.wo.concealcursor = 'nvic'
local lines = {}
for i = 1, 600 do lines[i] = string.rep('a', 40) end
api.nvim_buf_set_lines(buf, 0, -1, false, lines)
local borders = api.nvim_create_namespace('marktree-test-borders')
local conceals = api.nvim_create_namespace('marktree-test-conceals')
for row = 0, #lines - 1 do
  api.nvim_buf_set_extmark(buf, borders, row, 0, {
    virt_lines = { { { 'border', 'Normal' } } },
  })
  for col = 0, 9 do
    api.nvim_buf_set_extmark(buf, conceals, row, col, { end_col = col + 1, conceal = '' })
  end
end
local checked = {}
api.nvim_set_decoration_provider(conceals, {
  -- Tree-sitter's native conceal callback also clears and repopulates a row's
  -- persistent conceal marks. Node merges can invalidate decor_virt_lines' iterator.
  _on_conceal_line = function(_, _, b, row)
    if b ~= buf or checked[row] then return end
    checked[row] = true
    api.nvim_buf_clear_namespace(buf, conceals, row, row + 1)
    for col = 0, 9 do
      api.nvim_buf_set_extmark(buf, conceals, row, col, { end_col = col + 1, conceal = '' })
    end
  end,
})
for row = #lines - 2, 2, -2 do
  local height = api.nvim_win_text_height(0, { start_row = row, end_row = row })
  assert(height.fill == 1 and height.all == 2, vim.inspect(height))
end
assert(vim.tbl_count(checked) >= 500, 'conceal callbacks must actually run')
assert(#api.nvim_buf_get_extmarks(buf, borders, 0, -1, {}) == #lines, 'borders remain intact')
assert(vim.deep_equal(api.nvim_buf_get_lines(buf, 0, -1, false), lines), 'source remains intact')
api.nvim_set_decoration_provider(conceals, {})
print('PASS: virtual line geometry survives persistent conceal replacement')

-- A provider may also delete or replace the virtual mark itself. Reading the
-- old DecorVirtText after the callback is unsafe even if traversal is fixed.
api.nvim_buf_clear_namespace(buf, borders, 0, -1)
api.nvim_buf_clear_namespace(buf, conceals, 0, -1)
for _, replace in ipairs({ false, true }) do
  local id = api.nvim_buf_set_extmark(buf, borders, 10, 0, {
    virt_lines = { { { 'old border', 'Normal' } } },
  })
  local called = false
  api.nvim_set_decoration_provider(conceals, {
    _on_conceal_line = function(_, _, b, row)
      if b ~= buf or row ~= 10 or called then return end
      called = true
      api.nvim_buf_del_extmark(buf, borders, id)
      if replace then
        api.nvim_buf_set_extmark(buf, borders, 10, 0, {
          id = id, virt_lines = { { { 'new border', 'Normal' } }, { { 'second row', 'Normal' } } },
        })
      end
    end,
  })
  local height = api.nvim_win_text_height(0, { start_row = 11, end_row = 11 })
  assert(called, 'provider must run while counting the preceding virtual line')
  assert(height.fill == (replace and 2 or 0), vim.inspect(height))
  api.nvim_set_decoration_provider(conceals, {})
  api.nvim_buf_clear_namespace(buf, borders, 0, -1)
end
print('PASS: deleted/replaced virtual decorations are rechecked after callbacks')
