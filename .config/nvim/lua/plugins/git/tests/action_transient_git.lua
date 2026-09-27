-- Run from plugin root: nvim --headless --clean -u NONE -l tests/action_transient_git.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path

local root = vim.fn.tempname() .. ' actions'
vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
local function press(key)
  local map = vim.fn.maparg(key, 'n', false, true)
  assert(type(map.callback) == 'function', 'Missing menu key ' .. key)
  map.callback()
end

git({ 'init', '-qb', 'main' })
git({ 'config', 'user.name', 'Test' })
git({ 'config', 'user.email', 'test@example.invalid' })
vim.fn.writefile({ 'base' }, root .. '/file.txt')
git({ 'add', 'file.txt' })
git({ 'commit', '-qm', 'base' })
local hash = git({ 'rev-parse', 'HEAD' })

local actions = require('git.features.magit_actions')
local utils = require('git.utils')
local log = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(log, 0, -1, false, { hash .. '\tbase' })
utils.set_buf_work_tree(log, root)
vim.bo[log].filetype = 'fugitivelog'
vim.api.nvim_set_current_buf(log)
actions.attach(log)

local original_input = vim.ui.input
vim.ui.input = function(_, callback) callback('release-test') end
press('<Space><Space>')
press('t')
press('t')
assert(git({ 'tag', '--list', 'release-test' }) == 'release-test',
  'tag transient did not create the selected commit tag')
vim.ui.input = original_input
-- Input UIs can change the current buffer before returning the entered value.
local other_root = vim.fn.tempname()
vim.fn.mkdir(other_root, 'p')
assert(vim.system({ 'git', '-C', other_root, 'init', '-qb', 'other' }):wait().code == 0)
local other_buf = vim.api.nvim_create_buf(true, false)
utils.set_buf_work_tree(other_buf, other_root)
vim.ui.input = function(_, callback)
  vim.api.nvim_set_current_buf(other_buf)
  callback('source-context-test')
end
press('<Space><Space>'); press('t'); press('t')
assert(git({ 'tag', '--list', 'source-context-test' }) == 'source-context-test',
  'delayed action ran in the current buffer repository instead of its source')
vim.ui.input = original_input
vim.api.nvim_set_current_buf(log)
vim.api.nvim_buf_delete(other_buf, { force = true })
vim.fn.delete(other_root, 'rf')
press('<Space><Space>')
press('d')
press('d')
local diff_lines = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
assert(diff_lines:find('+base', 1, true),
  'diff transient could not display the selected root commit')
vim.api.nvim_win_close(0, true)

vim.fn.writefile({ 'base', 'edited' }, root .. '/file.txt')
local status = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(status, 0, -1, false, { ' M file.txt' })
utils.set_buf_work_tree(status, root)
vim.bo[status].filetype = 'fugitivestatus'
vim.api.nvim_set_current_buf(status)
actions.attach(status)
press('<Space><Space>')
press('z')
press('z')
assert(git({ 'stash', 'list' }):find('stash@{0}', 1, true)
  and vim.fn.readfile(root .. '/file.txt')[1] == 'base',
  'stash transient did not save the worktree change')

vim.ui.input = function(_, callback) callback('stash@{0}') end
press('<Space><Space>')
press('z')
press('p')
assert(vim.fn.readfile(root .. '/file.txt')[2] == 'edited'
  and git({ 'stash', 'list' }) == '', 'stash pop did not restore the worktree')
vim.ui.input = original_input

git({ 'config', 'branch.main.remote', 'origin' })
git({ 'config', 'branch.main.merge', 'refs/heads/main' })
git({ 'config', 'branch.main.pushRemote', 'backup' })
local commands = require('git.commands')
local original_command = commands.git
local sent
commands.git = function(opts) sent = commands.argv(opts.args) end
press('<Space><Space>')
press('P')
press('p')
assert(vim.deep_equal(sent, { 'push', 'backup', 'HEAD:refs/heads/main' }),
  'push-remote action ignored branch configuration')
press('<Space><Space>')
press('P')
press('u')
assert(vim.deep_equal(sent, { 'push', 'origin', 'HEAD:refs/heads/main' }),
  'upstream action reused the push remote')
press('<Space><Space>')
press('F')
press('u')
assert(vim.deep_equal(sent, { 'pull', 'origin', 'refs/heads/main' }),
  'pull upstream used the wrong remote')
press('<Space><Space>')
press('r')
press('p')
assert(vim.deep_equal(sent, { 'rebase', 'backup/main' }),
  'rebase onto push remote used the wrong target')
press('<Space><Space>')
press('r')
press('u')
assert(vim.deep_equal(sent, { 'rebase', 'origin/main' }),
  'rebase onto upstream used the wrong target')
commands.git = original_command

local group = vim.api.nvim_create_augroup('ActionTransientPanelsTest', { clear = true })
require('git.features.commands').setup()
require('git.features.reflog').setup(group)
require('git.features.worktree').setup(group)
vim.api.nvim_set_current_buf(status)
vim.cmd('Greflog')
local reflog = vim.api.nvim_get_current_buf()
press('<Space><Space>')
assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
  :find('Reflog: HEAD@{0}', 1, true),
  'real reflog panel did not attach a contextual action menu')
press('q')
vim.api.nvim_buf_delete(reflog, { force = true })

vim.api.nvim_set_current_buf(status)
vim.cmd('Gworktree')
local worktree = vim.api.nvim_get_current_buf()
press('<Space><Space>')
assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
  :find('Worktree: ' .. root, 1, true),
  'real worktree panel did not attach a contextual action menu')
press('q')
vim.api.nvim_buf_delete(worktree, { force = true })

vim.api.nvim_set_current_buf(status)
require('git.features.log').open({ args = '--max-count=1 --graph --color' })
local graph_line = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
assert(graph_line and graph_line:match('^%x+\t') and graph_line:find('*', 1, true),
  'graph/color flags prevented the custom log from parsing commit rows')
local graph_marks = vim.api.nvim_buf_get_extmarks(0,
  vim.api.nvim_get_namespaces().fugitivelog_graph, 0, -1, { details = true })
assert(#graph_marks > 0 and graph_marks[1][4].hl_group == 'DiagnosticInfo',
  'color flag did not color the graph in the custom log')
vim.api.nvim_win_close(0, true)
vim.api.nvim_set_current_buf(status)
require('git.features.log').open({ args = '--max-count=1', menu_flags = true })
local undecorated = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
assert(not undecorated:find('release-test', 1, true),
  'menu log showed refnames without the decorate flag')
vim.api.nvim_win_close(0, true)
vim.api.nvim_set_current_buf(status)
require('git.features.log').open({ args = '--max-count=1 --decorate', menu_flags = true })
local decorated = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
assert(decorated:find('release-test', 1, true),
  'decorate flag did not show refnames in the custom log')
vim.api.nvim_win_close(0, true)
vim.api.nvim_set_current_buf(status)
require('git.features.log').open({ args = '--max-count=1 --show-signature', menu_flags = true })
local signed = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
assert(signed:find('Signature: none', 1, true),
  'signature flag did not report verification status in the custom log')
vim.api.nvim_win_close(0, true)
vim.api.nvim_set_current_buf(status)
local original_system, log_argv = vim.system
vim.system = function(argv, opts, callback)
  if argv[1] == 'git' and argv[2] == 'log' then log_argv = vim.deepcopy(argv) end
  return original_system(argv, opts, callback)
end
require('git.features.log').open({
  args = '--grep=--decorate --grep=--show-signature --invert-grep', menu_flags = true })
vim.system = original_system
local filtered = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
assert(filtered and not filtered:find('release-test', 1, true)
  and not filtered:find('Signature:', 1, true),
  'search text was interpreted as a display option')
assert(log_argv and not vim.tbl_contains(log_argv, '1000'),
  'clearing the menu commit limit silently restored the ordinary log limit')
vim.api.nvim_win_close(0, true)
vim.api.nvim_set_current_buf(status)
require('git.features.log').open({ args = '--max-count=1 --graph --color=never' })
assert(#vim.api.nvim_buf_get_extmarks(0,
  vim.api.nvim_get_namespaces().fugitivelog_graph, 0, -1, {}) == 0,
  'color=never still highlighted the graph')
vim.api.nvim_win_close(0, true)
vim.api.nvim_set_current_buf(status)
require('git.features.log').open({ args = "--max-count=1 -L '1,1:file.txt' HEAD" })
local traced = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
assert(traced and traced:match('^%x+\t'),
  'line evolution flag did not retain commit rows in the custom log')
vim.api.nvim_win_close(0, true)

vim.api.nvim_buf_delete(log, { force = true })
vim.api.nvim_buf_delete(status, { force = true })
vim.fn.delete(root, 'rf')
print('PASS: action menu creates tags and saves/restores a real Git stash')
