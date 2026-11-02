-- nvim --headless --clean -u NONE -l .config/nvim/tests/markdown_focus.lua
local source = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local root = vim.fs.dirname(vim.fs.dirname(source))
vim.opt.rtp:prepend(root)
local integration = require('config.markdown_renderer')
local glows = 0
package.loaded['undo-glow'] = {
  setup = function() end,
  highlight_region = function() glows = glows + 1 end,
}
package.loaded['undo-glow.utils'] = { merge_command_opts = function(_, opts) return opts end }
vim.api.nvim_set_hl(0, 'EWhitespace', {})
dofile(root .. '/lua/config/colorScheme.lua')
dofile(root .. '/lua/plugins/undo-glow.lua').config()
local function focus()
  vim.api.nvim_exec_autocmds('FocusLost', {})
  vim.api.nvim_exec_autocmds('FocusGained', {})
end
local function normal() return vim.api.nvim_get_hl(0, { name = 'Normal' }) end
assert(not integration.typography_active())
focus()
assert(package.loaded['inkstone'] == nil and package.loaded['inkstone.core.typography'] == nil)
assert(normal().bg == 0x002b36 and glows == 1)
local tab, win, buf = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
local state = { win = win, entries = { {} } }
package.loaded['inkstone.core.typography'] = { active = { [buf] = state } }
local before = normal()
for _ = 1, 3 do
  assert(integration.typography_active())
  vim.api.nvim_exec_autocmds('FocusLost', {})
  assert(vim.deep_equal(normal(), before))
  vim.api.nvim_exec_autocmds('FocusGained', {})
  assert(vim.deep_equal(normal(), before) and glows == 1)
end
-- A rendered sibling still needs protection when a plain window has focus.
vim.cmd('vnew')
assert(integration.typography_active())
focus()
assert(vim.deep_equal(normal(), before) and glows == 1)
-- A hidden tab must not suppress ordinary focus styling/animation.
vim.cmd('tabnew')
assert(not integration.typography_active())
focus()
assert(normal().bg == 0x002b36 and glows == 2)
vim.api.nvim_set_current_tabpage(tab)
state.entries = {}
assert(not integration.typography_active())
state.entries = { {} }
vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(false, true))
assert(not integration.typography_active(), 'stale buffer owner must not suppress focus')
vim.api.nvim_win_close(win, true)
assert(not integration.typography_active(), 'closed window must not suppress focus')
focus()
assert(glows == 3)
print('PASS: focus styling/animation preserve sized text, including siblings, hidden tabs and stale owners')
