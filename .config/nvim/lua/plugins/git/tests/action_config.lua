-- Run through tests/run.py to isolate transient preset storage.
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path

local root = vim.fn.tempname() .. ' configuration'
vim.fn.mkdir(root, 'p')
local function git(args, failure)
  local argv = { 'git', '-C', root }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  if not failure then assert(result.code == 0, result.stderr) end
  return vim.trim(result.stdout or ''), result
end
git({ 'init', '-qb', 'main' })
git({ 'config', 'user.name', 'Test' })
git({ 'config', 'user.email', 'test@example.invalid' })
vim.fn.writefile({ 'base' }, root .. '/file.txt')
git({ 'add', '.' }); git({ 'commit', '-qm', 'base' })
git({ 'branch', 'feature' })
git({ 'remote', 'add', 'origin', root })
git({ 'remote', 'add', 'publish', root })
local tip = git({ 'rev-parse', 'HEAD' })
git({ 'update-ref', 'refs/remotes/origin/main', tip })
git({ 'branch', '--set-upstream-to=origin/main', 'main' })

local actions = require('git.features.magit_actions')
local utils = require('git.utils')
local status = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(status, 0, -1, false, { tip .. ' base' })
utils.set_buf_work_tree(status, root)
vim.bo[status].filetype = 'gitstatus'
vim.api.nvim_set_current_buf(status)
actions.attach(status)
local function press(key)
  local map = vim.fn.maparg(key, 'n', false, true)
  assert(type(map.callback) == 'function', 'Missing menu key ' .. key)
  map.callback()
end
local function text() return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n') end
local function menu(key) press('<Space><Space>'); press(key) end
local function config(key) return git({ 'config', '--local', '--get', key }, true) end
local selections, inputs = {}, {}
local original_input, original_select = vim.ui.input, vim.ui.select
vim.ui.select = function(items, opts, callback)
  local value = table.remove(selections, 1)
  assert(value ~= nil, 'Unexpected selection: ' .. opts.prompt)
  if value == false then callback(nil); return end
  if type(value) == 'number' then callback(assert(items[value])); return end
  assert(vim.tbl_contains(items, value), 'Selection absent: ' .. value)
  callback(value)
end
vim.ui.input = function(opts, callback)
  if opts.prompt:match('^Upstream for ') then
    assert(opts.completion == 'customlist,v:lua.git_config_upstream_completion')
    assert(not vim.tbl_contains(_G.git_config_upstream_completion(''), 'origin/HEAD'))
  end
  local value = table.remove(inputs, 1)
  assert(value ~= nil, 'Unexpected input: ' .. opts.prompt)
  if value == false then callback(nil) else callback(value) end
end
local events = 0
vim.api.nvim_create_autocmd('User', { pattern = 'GitChanged', callback = function(ev)
  assert(ev.data.work_tree == root, 'Configuration refreshed the wrong repository')
  events = events + 1
end })

-- Status targets the checked-out branch even on a commit row.
menu('b')
assert(text():find('Configure main', 1, true) and text():find('Unset upstream: origin/main', 1, true))
local branch_menu = vim.api.nvim_get_current_buf()
press('u')
assert(select(2, git({ 'rev-parse', 'main@{upstream}' }, true)).code ~= 0)
assert(vim.api.nvim_get_current_buf() == branch_menu and text():find('Set upstream: unset', 1, true),
  'Unset closed the transient or retained a stale label')
inputs[#inputs + 1] = 'origin/main'; press('u')
assert(git({ 'rev-parse', '--abbrev-ref', 'main@{upstream}' }) == 'origin/main')
inputs[#inputs + 1] = false; press('U')
assert(git({ 'rev-parse', '--abbrev-ref', 'main@{upstream}' }) == 'origin/main', 'Cancel changed upstream')
inputs[#inputs + 1] = 'missing-ref'; press('U')
assert(git({ 'rev-parse', '--abbrev-ref', 'main@{upstream}' }) == 'origin/main', 'Invalid ref changed upstream')
selections[#selections + 1] = 'publish'; press('p')
assert(config('branch.main.pushRemote') == 'publish')
selections[#selections + 1] = 'merges'; press('r')
assert(config('branch.main.rebase') == 'merges')
selections[#selections + 1] = '(unset)'; press('r')
assert(config('branch.main.rebase') == '')
inputs[#inputs + 1] = 'Main description'; press('d')
assert(config('branch.main.description') == 'Main description')
inputs[#inputs + 1] = ''; press('d')
assert(config('branch.main.description') == '')
selections[#selections + 1] = 'false'; press('R')
assert(config('pull.rebase') == 'false')
selections[#selections + 1] = 'publish'; press('P')
assert(config('remote.pushDefault') == 'publish')
selections[#selections + 1] = 'inherit'; press('a m')
selections[#selections + 1] = 'remote'; press('a r')
assert(config('branch.autoSetupMerge') == 'inherit' and config('branch.autoSetupRebase') == 'remote')

-- C chooses a different local branch without checkout; stale remote refs can be unset.
selections[#selections + 1] = 'feature'; press('C')
assert(vim.b.git_action_menu_kind == 'branch-config' and text():find('Configure feature', 1, true))
inputs[#inputs + 1] = 'origin/main'; press('u')
assert(git({ 'rev-parse', '--abbrev-ref', 'feature@{upstream}' }) == 'origin/main')
git({ 'update-ref', '-d', 'refs/remotes/origin/main' })
press('u')
assert(config('branch.feature.merge') == '' and config('branch.feature.remote') == '')
assert(git({ 'branch', '--show-current' }) == 'main')
press('q')

for _, key in ipairs({ 'P', 'F', 'f' }) do
  menu(key); selections[#selections + 1] = 'feature'; press('C')
  assert(vim.b.git_action_menu_kind == 'branch-config', key .. ' omitted branch configuration')
  press('q')
end

-- Configuration is distinct from saved arguments and guarded while history is running.
menu('b')
local async = require('git.features.async')
local busy = async.busy
async.busy = function() return true end
press('u')
async.busy = busy
assert(config('branch.main.merge') == 'refs/heads/main', 'Busy repository was mutated')
press('q')

-- A remote/tag row never silently edits the current branch. Spin actions are reachable.
local branch = vim.api.nvim_create_buf(true, false)
utils.set_buf_work_tree(branch, root)
vim.api.nvim_buf_set_lines(branch, 0, -1, false, { 'feature', 'origin/feature', 'tag' })
vim.bo[branch].filetype = 'gitbranch'
vim.b[branch].branch_map = { 'feature', 'origin/feature', 'tag' }
vim.b[branch].branch_kinds = { 'local_', 'remote', 'tags' }
vim.api.nvim_set_current_buf(branch)
local spins = {}
vim.keymap.set('n', 'bs', function() spins[#spins + 1] = 'off' end, { buffer = branch })
vim.keymap.set('n', 'bS', function() spins[#spins + 1] = 'out' end, { buffer = branch })
actions.attach(branch)
menu('b'); press('s'); menu('b'); press('S')
assert(vim.deep_equal(spins, { 'off', 'out' }))
for _, row in ipairs({ 2, 3 }) do
  vim.api.nvim_win_set_cursor(0, { row, 0 }); menu('b')
  assert(not text():find('Configure main', 1, true) and not text():find('Unset upstream:', 1, true))
  assert(vim.fn.maparg('u', 'n', false, true).buffer ~= 1, 'Nonlocal row exposed upstream edit')
  press('q')
end
vim.api.nvim_win_set_cursor(0, { 1, 0 }); menu('b')
inputs[#inputs + 1] = 'main'; press('u')
assert(git({ 'rev-parse', '--abbrev-ref', 'feature@{upstream}' }) == 'main')
press('q')

-- Remote fields preserve sibling URLs/refspecs and support add/remove/cancel.
vim.api.nvim_set_current_buf(status)
git({ 'config', '--add', 'remote.origin.url', 'second-url' })
menu('M')
assert(text():find('Configure origin', 1, true))
selections[#selections + 1] = 1; inputs[#inputs + 1] = 'replacement-url'; press('u')
assert(git({ 'config', '--get-all', 'remote.origin.url' }) == 'replacement-url\nsecond-url')
selections[#selections + 1] = 2; inputs[#inputs + 1] = ''; press('u')
assert(git({ 'config', '--get-all', 'remote.origin.url' }) == 'replacement-url')
selections[#selections + 1] = 1; inputs[#inputs + 1] = 'push-url'; press('s')
assert(config('remote.origin.pushurl') == 'push-url')
selections[#selections + 1] = 2; inputs[#inputs + 1] = '+refs/tags/*:refs/tags/*'; press('U')
assert(git({ 'config', '--get-all', 'remote.origin.fetch' }):find('+refs/tags/*:refs/tags/*', 1, true))
selections[#selections + 1] = 1; inputs[#inputs + 1] = 'refs/heads/main:refs/heads/main'; press('S')
assert(config('remote.origin.push') == 'refs/heads/main:refs/heads/main')
selections[#selections + 1] = '--no-tags'; press('O')
assert(config('remote.origin.tagOpt') == '--no-tags')
selections[#selections + 1] = 'publish'; press('C')
assert(vim.b.git_action_menu_kind == 'remote-config' and text():find('Configure publish', 1, true))
selections[#selections + 1] = false; press('u')
assert(config('remote.publish.url') == root, 'Cancel changed the remote URL')
press('q')

-- Detached HEAD still offers explicit branch selection, but no implicit branch mutation.
git({ 'checkout', '-q', '--detach' }); menu('b')
assert(not text():find('Configure main', 1, true))
selections[#selections + 1] = 'feature'; press('C')
inputs[#inputs + 1] = 'Detached selection'; press('d')
assert(config('branch.feature.description') == 'Detached selection')
press('q')

-- The captured repository/branch survives an input UI changing the active buffer.
git({ 'checkout', '-q', 'main' })
menu('b')
local other = vim.api.nvim_create_buf(true, false)
utils.set_buf_work_tree(other, root .. '/unrelated-repository')
vim.ui.input = function(_, callback)
  vim.api.nvim_set_current_buf(other)
  callback('Captured repository')
end
press('d')
assert(config('branch.main.description') == 'Captured repository')
vim.ui.input = function(_, callback) callback('Must not recreate branch config') end
vim.api.nvim_set_current_buf(branch)
vim.api.nvim_win_set_cursor(0, { 1, 0 }); menu('b')
git({ 'branch', '-D', 'feature' })
press('d')
assert(config('branch.feature.description') == '', 'Deleted branch got a ghost configuration')
press('q')

-- A real Branch panel updates in place while the configuration transient stays open.
git({ 'branch', 'feature' }); git({ 'branch', '--set-upstream-to=main', 'feature' })
vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/file.txt'))
require('git.features.branch').setup(vim.api.nvim_create_augroup('ActionConfigBranch', { clear = true }))
vim.cmd('Gbranch')
local actual = vim.api.nvim_get_current_buf()
local function feature_row()
  for row, name in ipairs(vim.b[actual].branch_map) do if name == 'feature' then return row end end
end
vim.api.nvim_win_set_cursor(0, { assert(feature_row()), 0 })
menu('b'); press('u')
assert(vim.wait(1000, function()
  local row = feature_row()
  return row and not vim.api.nvim_buf_get_lines(actual, row - 1, row, false)[1]:find('[main]', 1, true)
end), 'Branch panel did not refresh after transient unset')
assert(vim.b.git_action_menu_kind == 'branch', 'Refresh closed or replaced the transient')
press('q')
vim.wait(1000, function() return events > 0 end)
assert(events > 0, 'Configuration did not emit GitChanged')
vim.ui.input, vim.ui.select = original_input, original_select
for _, buf in ipairs(vim.api.nvim_list_bufs()) do pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
vim.fn.delete(root, 'rf')
print('PASS: Magit branch/remote configuration, set/unset, guards, multi-values, spin and transfer entries')
