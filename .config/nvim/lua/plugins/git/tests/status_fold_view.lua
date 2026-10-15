local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local modules = require('git.features.status_modules')
local folds = require('git.features.status_folds')
local buf = vim.api.nvim_get_current_buf()
local base = { 'Head: main' }
for i = 1, 65 do base[#base + 1] = 'header detail ' .. i end
vim.list_extend(base, { '', 'Unstaged changes (3)', 'M a.txt', 'M b.txt', 'M c.txt', '' })
for i = 1, 100 do base[#base + 1] = 'footer ' .. i end
vim.list_extend(base, { '', 'Worktrees (3)', '/repo main abcdef0', '/other branch abcdef1', '/third branch abcdef2' })
local items = {}
for i = 1, 25 do items[i] = { id = tostring(i), text = 'Note ' .. i } end
modules.setup({ { id = 'notes', title = 'Related notes', after = 'unstaged', load = function(_, done) done(items) end } })
modules.attach(buf, function() end)
modules.refresh(buf, { root = '/test', branch = 'main' })
local projected, rows
assert(vim.wait(1000, function()
  local mapping
  projected, mapping, rows = modules.compose(buf, base)
  return #projected > #base + #items
end, 5))
vim.api.nvim_buf_set_lines(buf, 0, -1, false, projected)
modules.commit(buf, rows)
folds.rebuild(buf)
local function heading(text)
  for row, line in ipairs(projected) do if line == text then return row end end
end
vim.o.lines, vim.o.columns, vim.o.scrolloff = 24, 100, 10
vim.cmd('vsplit')
local windows = vim.api.nvim_list_wins()
local function position(win, row, offset)
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ lnum = row, col = 0, topline = row - offset, leftcol = 0 })
  end)
end
local function view(win) return vim.api.nvim_win_call(win, vim.fn.winsaveview) end
local function toggle(row, shelf)
  position(windows[1], row, 5)
  position(windows[2], row, 3)
  vim.cmd('redraw')
  local first, second = view(windows[1]), view(windows[2])
  vim.api.nvim_set_current_win(windows[1])
  if shelf then modules.toggle(buf, row) else folds.toggle(buf, row) end
  vim.cmd('redraw')
  for i, expected in ipairs({ first, second }) do
    local actual = view(windows[i])
    assert(actual.topline == expected.topline and actual.lnum == expected.lnum,
      ('Folding scrolled window %d: %s -> %s'):format(i, vim.inspect(expected), vim.inspect(actual)))
  end
end
local native, shelf = assert(heading('Unstaged changes (3)')), assert(heading('Related notes (25)'))
toggle(native); toggle(native)
toggle(shelf, true); toggle(shelf, true)
-- From an item, only the ordinary cursor move to the heading may scroll.
position(windows[1], shelf + 2, 7)
local before = view(windows[1])
vim.api.nvim_win_set_cursor(windows[1], { shelf, 0 })
vim.cmd('redraw')
local expected = view(windows[1])
vim.fn.winrestview(before)
modules.toggle(buf, shelf + 2)
vim.cmd('redraw')
assert(view(windows[1]).lnum == shelf and view(windows[1]).topline == expected.topline,
  'Folding from an item scrolled beyond the ordinary move to its heading')
modules.cleanup(buf); folds.cleanup(buf)
print('PASS: Status and shelf fold rebuilds preserve each window view; item folding keeps the heading below the top')
