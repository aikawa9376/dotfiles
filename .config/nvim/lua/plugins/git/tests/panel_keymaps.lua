-- Run: nvim --headless --clean -u NONE -l tests/panel_keymaps.lua
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
vim.opt.rtp:prepend(plugin)
local clipboard_lines = {}
local copy = function(lines) clipboard_lines = vim.deepcopy(lines) end
local paste = function() return { clipboard_lines, 'v' } end
vim.g.clipboard = { name = 'test', copy = { ['+'] = copy, ['*'] = copy },
  paste = { ['+'] = paste, ['*'] = paste }, cache_enabled = 0 }
package.loaded['git.features.status_watch'] = { subscribe = function() return function() end end }
package.loaded['git.features.worktree_watch'] = { subscribe = function() return function() end end }
package.loaded.utilities = { smart_close = function() vim.cmd('close') end }
local executable = vim.fn.executable
vim.fn.executable = function(name) return name == 'gh' and 0 or executable(name) end
local root = vim.fn.tempname() .. ' keymaps'; vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root }; vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr); return vim.trim(result.stdout or '')
end
local function write(value) vim.fn.writefile({ value }, root .. '/file.txt') end
git({ 'init', '-qb', 'main' }); git({ 'config', 'user.name', 'Test' }); git({ 'config', 'user.email', 'test@example.invalid' })
git({ 'config', 'commit.gpgsign', 'false' })
local function commit(value) write(value); git({ 'add', '.' }); git({ 'commit', '-qm', value }); return git({ 'rev-parse', 'HEAD' }) end
local base, middle, tip = commit('base'), commit('middle'), commit('tip')
require('git').setup()
vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/file.txt'))
local source = vim.api.nvim_get_current_buf()
local function press(key, mode)
  local map = vim.fn.maparg(key, mode or 'n', false, true)
  assert(map.callback, 'missing callback: ' .. key); map.callback()
end
local function row_matching(buf, pattern)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do if line:match(pattern) then return row end end
end
local function select_reflog(buf, hash)
  for row = 1, vim.api.nvim_buf_line_count(buf) do
    local entry = require('git.features.reflog').entry_at(buf, row)
    if entry and entry.hash == hash then vim.api.nvim_win_set_cursor(0, { row, 0 }); return entry end
  end
  error('missing reflog hash ' .. hash)
end
local confirm = vim.fn.confirm
vim.cmd('Greflog')
local reflog = vim.api.nvim_get_current_buf()
assert(vim.fn.maparg('<Leader>R', 'n') == '')
local target = select_reflog(reflog, base)
press('gy'); assert(vim.fn.getreg('+') == target.selector)
write('staged'); git({ 'add', 'file.txt' }); write('dirty')
local message, buttons
vim.fn.confirm = function(msg, choices, default) message, buttons = msg, choices; assert(default == 3); return 3 end
press('X')
assert(git({ 'rev-parse', 'HEAD' }) == tip and git({ 'show', ':file.txt' }) == 'staged')
assert(buttons == '&Mixed\n&Hard\n&Cancel' and message:find(target.selector, 1, true) and message:find('keep worktree', 1, true))
vim.fn.confirm = function() return 1 end
press('X')
assert(git({ 'rev-parse', 'HEAD' }) == base and git({ 'show', ':file.txt' }) == 'base')
assert(vim.fn.readfile(root .. '/file.txt')[1] == 'dirty', 'Mixed reset overwrote dirty worktree')
git({ 'reset', '--hard', tip }); press('R'); select_reflog(reflog, middle)
write('dirty hard'); vim.fn.confirm = function() return 2 end; press('X')
assert(git({ 'rev-parse', 'HEAD' }) == middle and vim.fn.readfile(root .. '/file.txt')[1] == 'middle')
git({ 'reset', '--hard', tip }); press('R'); select_reflog(reflog, base)
vim.fn.confirm = function() git({ 'reset', '--soft', middle }); return 1 end
press('X'); assert(git({ 'rev-parse', 'HEAD' }) == middle, 'stale confirmation executed after HEAD changed')
vim.fn.confirm = confirm; git({ 'reset', '--hard', tip })
-- Stash resolves the source repository even when cwd is elsewhere.
vim.api.nvim_set_current_buf(source)
write('older stash'); git({ 'stash', 'push', '-qm', 'older' })
write('newer stash'); git({ 'stash', 'push', '-qm', 'newer' })
vim.cmd('Gstash')
local stash = vim.api.nvim_get_current_buf()
assert(vim.bo.filetype == 'fugitivestash' and vim.api.nvim_buf_line_count(stash) == 2)
assert(vim.fn.maparg('A', 'n') == '' and vim.fn.maparg('P', 'n') == '')
vim.api.nvim_win_set_cursor(0, { 2, 0 }); press('a')
assert(vim.fn.readfile(root .. '/file.txt')[1] == 'older stash', 'apply ignored selected stash')
git({ 'reset', '--hard', tip })
local input = vim.ui.input
vim.ui.input = function(_, callback) callback('renamed older') end
vim.api.nvim_win_set_cursor(0, { 2, 0 }); press('cw'); vim.ui.input = input
assert(git({ 'stash', 'list' }):find('renamed older', 1, true))
press('R'); vim.api.nvim_win_set_cursor(0, { 1, 0 }); press('gy'); assert(vim.fn.getreg('+') == 'stash@{0}')
vim.api.nvim_set_current_buf(source)
local status = assert(require('git.features.status').open({ work_tree = root, split = true, focus = false }))
assert(vim.wait(5000, function() return row_matching(status, '^stash@{1}') ~= nil end, 20))
vim.api.nvim_win_set_cursor(0, { assert(row_matching(status, '^stash@{1}')), 0 })
press('?')
local stash_help = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
assert(stash_help:find('Rename selected stash', 1, true) and not stash_help:find('Reword commit', 1, true),
  'status help must follow its stash target')
press('gy')
assert(vim.api.nvim_get_current_buf() == status and vim.fn.getreg('+') == 'stash@{1}',
  'status menu action lost its source stash')
vim.api.nvim_win_set_cursor(0, { assert(row_matching(status, '^stash@{1}')), 0 }); press('cza')
assert(vim.fn.readfile(root .. '/file.txt')[1] == 'newer stash', 'status cza ignored selected stash')
git({ 'reset', '--hard', tip })
local ui_select, prompted = vim.ui.select, false
vim.ui.select = function(items, opts) prompted = opts.prompt == 'Select stash:' and #items == 2 end
vim.api.nvim_win_set_cursor(0, { 1, 0 }); press('cza'); vim.ui.select = ui_select
assert(prompted and vim.fn.readfile(root .. '/file.txt')[1] == 'tip', 'unselected stash operation silently chose latest')
-- A selector must still identify the captured stash when an asynchronous picker returns.
local pick, items
vim.ui.select = function(choices, _, callback) items, pick = choices, callback end
press('cza'); vim.ui.select = ui_select
write('stash created during picker'); git({ 'stash', 'push', '-qm', 'during picker' })
pick(items[1])
assert(vim.fn.readfile(root .. '/file.txt')[1] == 'tip', 'stale picker applied a different stash')
for _, key in ipairs({ 'mo', 'mt', 'mr', 'cos', 'coS', 'cZs', 'gy', 'a', 'gH', 'gD', 'gO' }) do assert(vim.fn.maparg(key, 'n', false, true).callback, key) end
for _, key in ipairs({ 'co', 'ct', 'cr', 'A', 'P', '<Leader>cf', '<Leader>wd', 'gws' }) do assert(vim.fn.maparg(key, 'n') == '', 'retired key remains: ' .. key) end
-- Exercise actual input and check the waiting policy independently of callback order.
local diff_kind
vim.keymap.set('n', 'dh', function() diff_kind = 'horizontal' end, { buffer = status, nowait = true })
vim.o.timeoutlen = 250
assert(vim.fn.maparg('d', 'n', false, true).nowait == 0, 'd must wait for its suffix')
vim.api.nvim_feedkeys('dh', 'xt', false)
assert(diff_kind == 'horizontal', 'd swallowed the dh sequence')
-- Background refresh cannot retarget an action chooser.
press('gH')
vim.bo[status].modifiable = true; vim.bo[status].readonly = false
vim.api.nvim_buf_set_lines(status, 0, 1, false, { 'changed source row' })
vim.bo[status].modifiable = false; vim.bo[status].readonly = true
press('1')
assert(vim.api.nvim_get_current_buf() == status and git({ 'rev-parse', 'HEAD' }) == tip)
press('mo'); assert(git({ 'rev-parse', 'HEAD' }) == tip, 'conflict key mutated a non-conflict row')
-- WIP refresh retains the selected snapshot rather than its moving entry number.
vim.api.nvim_set_current_buf(source)
local wip = require('git.features.wip')
write('first snapshot'); assert(wip.save(root)); git({ 'reset', '--hard', tip })
vim.cmd('GitWipLog')
local wip_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_win_set_cursor(0, { 2, 0 })
press('gy'); local snapshot = vim.fn.getreg('+')
write('second snapshot'); assert(wip.save(root)); git({ 'reset', '--hard', tip })
press('R'); press('gy')
assert(vim.fn.getreg('+') == snapshot and vim.api.nvim_win_get_cursor(0)[1] == 3, 'WIP R changed the selected snapshot')
assert(vim.fn.maparg('?', 'n', false, true).callback)
vim.fn.confirm = function()
  write('third snapshot'); assert(wip.save(root)); git({ 'reset', '--hard', tip }); return 1
end
press('a'); vim.fn.confirm = confirm
assert(vim.fn.readfile(root .. '/file.txt')[1] == 'tip', 'stale WIP confirmation restored a different snapshot')
for _, buf in ipairs(vim.api.nvim_list_bufs()) do pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
vim.fn.delete(root, 'rf')
print('PASS: reset modes/cancel/stale HEAD, selected-stash identity, copy/edit/apply, prefix input and stale action rejection')
