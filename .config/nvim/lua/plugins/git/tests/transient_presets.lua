local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local options = require('git.features.transient_options')
local menu = require('git.features.transient_menu')
local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
local source_buf = vim.api.nvim_get_current_buf()
require('git.utils').set_buf_work_tree(source_buf, root)
local function press(key) vim.fn.maparg(key, 'n', false, true).callback() end
local sent
local function show()
  local state = { signoff = false }
  menu.show({ kind = 'commit', groups = { { title = 'Arguments', actions = {
    options.flag('-s', 'Sign off', state, 'signoff', '--signoff'),
    options.value('-A', 'Author', state, 'author', '--author='),
  } }, { title = 'Actions', actions = { { key = 'c', label = 'Commit', run = function() sent = vim.deepcopy(state) end } } } } })
  return state
end
local state = show(); press('-s'); press('<C-w>'); press('q')
state = show(); assert(state.signoff == true, 'Session save was lost'); press('<C-d>'); press('q')
state = show(); assert(state.signoff == false); press('-s')
local original = vim.ui.input
vim.ui.input = function(_, cb) cb('A Person <person@example.invalid>') end
press('-A'); vim.ui.input = original
press('<C-r>'); press('c'); assert(sent.signoff and sent.author:find('A Person', 1, true))
-- Simulate restart of preset ownership, preserving the JSON file.
package.loaded['git.features.transient_presets'] = nil
state = show(); assert(state.signoff and state.author == sent.author, 'Persistent worktree preset was lost')
press('<C-d>'); press('q')
state = show(); local select = vim.ui.select
vim.ui.select = function(values, _, cb) assert(#values > 0); cb(values[1]) end
press('<C-h>'); vim.ui.select = select
assert(state.signoff and state.author == sent.author, 'Argument history was lost')
press('q')
-- A per-worktree preset must not escape into another repository.
local other = vim.fn.tempname(); vim.fn.mkdir(other, 'p'); require('git.utils').set_buf_work_tree(source_buf, other)
state = show(); assert(not state.signoff and not state.author); press('q')
vim.fn.delete(root, 'rf'); vim.fn.delete(other, 'rf')
print('PASS: session save, persistent worktree preset, history across reload, repository isolation')
