-- Run from plugin root: nvim --headless --clean -u NONE -l tests/action_transient.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path

local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local actions = require('git.features.magit_actions')
local utils = require('git.utils')
local commands = {}
require('git.commands').git = function(opts) commands[#commands + 1] = opts.args end
local patch_calls = {}
require('git.features.magit_apply').apply = function(ctx, three_way, reverse)
  patch_calls[#patch_calls + 1] = { commit = ctx.commit, three_way = three_way,
    reverse = reverse }
  return true
end

local function panel(filetype, lines)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  utils.set_buf_work_tree(buf, root)
  vim.bo[buf].filetype = filetype
  vim.api.nvim_set_current_buf(buf)
  actions.attach(buf)
  return buf
end
local function press(key)
  local mapping = vim.fn.maparg(key, 'n', false, true)
  assert(type(mapping.callback) == 'function', 'missing action-menu key ' .. key)
  mapping.callback()
end
local function text()
  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
end
local function kind()
  return vim.b[vim.api.nvim_get_current_buf()].git_action_menu_kind
end

local hash = string.rep('a', 40)
local status = panel('gitstatus', { hash .. ' selected commit' })
local help = function() end
vim.keymap.set('n', 'g?', help, { buffer = status })
actions.attach(status)
assert(vim.fn.maparg('g?', 'n', false, true).callback == help,
  'action menu replaced the existing help mapping')
press('<Space><Space>')
assert(kind() == 'root' and text():find('Cherry-pick', 1, true)
  and text():find('Revert', 1, true) and text():find('Apply variants', 1, true)
  and text():find('Commit: ' .. hash:sub(1, 12), 1, true)
  and text():find('Apply to worktree', 1, true),
  'status action menu omitted commit/patch actions')
assert(vim.api.nvim_win_get_config(0).relative == '', 'default menu was not a split')
press('a')
assert(vim.api.nvim_get_current_buf() == status and patch_calls[#patch_calls].commit == hash
  and not patch_calls[#patch_calls].reverse,
  'status contextual a did not directly apply the selected commit')
press('<Space><Space>')
press('A')
assert(kind() == 'cherry-pick' and text():find('Commit: ' .. hash:sub(1, 12), 1, true),
  'cherry-pick panel lost the selected commit')
assert(text():find('Harvest commit', 1, true)
  and text():find('Donate commit', 1, true)
  and text():find('Apply changes without committing', 1, true),
  'cherry-pick panel omitted Magit move/apply actions')
press('-x')
assert(text():find('✓ %-x', 1, false), 'cherry-pick switch did not update the panel')
press('A')
assert(commands[#commands] == 'cherry-pick -x ' .. hash,
  'cherry-pick did not pass the selected commit and switch')
assert(vim.api.nvim_get_current_buf() == status, 'action did not return to source panel')

local renderer = require('git.features.status_renderer')
local original_entry_at = renderer.entry_at
renderer.entry_at = function(_, row)
  return row == 3 and { path = 'file with spaces.txt', section = 'unstaged' } or nil
end
vim.api.nvim_buf_set_lines(status, 0, -1, false, { 'M file with spaces.txt', '@@ -1 +1 @@', '+change' })
vim.api.nvim_win_set_cursor(0, { 3, 0 })
local discarded = false
vim.keymap.set('n', 'X', function() discarded = true end, { buffer = status })
press('<Space><Space>')
assert(text():find('File: file with spaces.txt', 1, true),
  'action menu lost the file context on an expanded diff row')
assert(text():find('Apply variants', 1, true)
  and not text():find('Apply to worktree', 1, true),
  'unstaged change exposed direct apply or hid apply variants')
press('v')
assert(kind() == 'apply-variants' and text():find('Discard selected change', 1, true),
  'unstaged status did not offer discard in apply variants')
press('k')
assert(discarded, 'apply variants discard did not reuse the status action')
renderer.entry_at = original_entry_at

local log = panel('gitlog', { hash .. ' selected commit' })
local log_opens = {}
require('git.features.log').open = function(opts) log_opens[#log_opens + 1] = opts.args end
press('<Space><Space>')
assert(kind() == 'root' and text():find('Commit: ' .. hash:sub(1, 12), 1, true),
  'log menu did not use the commit under cursor')
assert(not text():find('Git actions', 1, true) and not text():find('log  ' .. hash:sub(1, 7), 1, true),
  'root menu repeated its selected commit in a redundant header')
assert(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == 'Commit: ' .. hash:sub(1, 12),
  'root menu did not start with the useful context')
assert(text():find('Cherry-pick…', 1, true) and text():find('Reset…', 1, true)
  and text():find('Apply variants', 1, true)
  and not text():find('Apply to worktree', 1, true)
  and vim.api.nvim_buf_line_count(0) < 20,
  'root menu did not pack the operation prefixes into two columns')
assert(not text():find('Stash…', 1, true) and not text():find('Remote…', 1, true),
  'log menu showed repository operations unrelated to the selected commit')
press('l')
assert(kind() == 'log' and text():find('Commit Limiting', 1, true)
  and text():find('History Simplification', 1, true)
  and text():find('Commit Ordering', 1, true)
  and text():find('Formatting', 1, true)
  and text():find('Limit number of commits (--max-count=256)', 1, true),
  'log transient omitted Magit flag groups or default commit limit')
local function log_row(needle)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if line:find(needle, 1, true) then return i, line end
  end
  error('missing log flag ' .. needle)
end
local count_row, count_line = log_row('--max-count=256')
local marks = vim.api.nvim_buf_get_extmarks(0, -1, { count_row - 1, 0 },
  { count_row - 1, -1 }, { details = true })
local highlighted = false
for _, mark in ipairs(marks) do
  if mark[4].hl_group == 'DiagnosticOk' then
    highlighted = count_line:sub(mark[3] + 1, mark[4].end_col) == '--max-count=256'
  end
end
assert(highlighted, 'active log flag did not highlight only the argument in parentheses')
assert(log_row('--author=') and not text():find('✓ %-A%s+Limit to author'),
  'unset log value flag was checked')
local log_input = vim.ui.input
local values = { ['Limit to author'] = 'Alice', ['Search messages'] = 'fix',
  ['Search changes'] = 'target', ['Search occurrences'] = 'needle',
  ['Trace line evolution'] = '1,2:file.txt', ['Limit to commits since'] = 'yesterday',
  ['Limit to commits until'] = 'today', ['Order commits by'] = 'topo' }
vim.ui.input = function(opts, callback)
  for label, value in pairs(values) do
    if opts.prompt:find(label, 1, true) then callback(value); return end
  end
  error('unexpected log input: ' .. opts.prompt)
end
for _, key in ipairs({ '-A', '-F', '-G', '-S', '-L', '-s', '-u', '-o' }) do press(key) end
vim.ui.input = log_input
for _, key in ipairs({ '=m', '=p', '-i', '-D', '-r', '=R', '-g', '-c', '-d', '=S' }) do
  press(key)
end
assert(log_row('--author=Alice') and log_row('--no-merges') and log_row('--topo-order')
  and select(2, log_row('--author=Alice')):sub(1, 3) == '✓'
  and select(2, log_row('--no-merges')):sub(1, 3) == '✓'
  and select(2, log_row('--topo-order')):sub(1, 3) == '✓',
  'active log flags did not show their values and checkmarks')
press('h')
assert(vim.deep_equal(require('git.commands').argv(log_opens[#log_opens]), {
  '--max-count=256', '--author=Alice', '--grep=fix', '-G', 'target', '-S', 'needle',
  '-L', '1,2:file.txt', '--since=yesterday', '--until=today', '--first-parent',
  '--no-merges', '--invert-grep', '--simplify-by-decoration', '--reverse',
  '--topo-order', '--reflog', '--graph', '--color', '--decorate',
  '--show-signature', 'HEAD',
}), 'log transient did not pass its flags to the log panel')
press('<Space><Space>')
press('l')
vim.ui.input = function(opts, callback)
  if opts.prompt:find('Limit to files', 1, true) then callback('file with spaces.txt')
  else callback('') end
end
press('--')
press('-n')
vim.ui.input = log_input
press('-f')
assert(select(2, log_row('--max-count=')):sub(1, 1) == ' '
  and select(2, log_row('-- file with spaces.txt')):sub(1, 3) == '✓',
  'cleared limit remained checked or file limit was not checked')
press('l')
assert(vim.deep_equal(require('git.commands').argv(log_opens[#log_opens]),
  { '--follow', '--', 'file with spaces.txt' }),
  'file limit and follow were not passed as separate Git arguments')
press('<Space><Space>')
press('v')
assert(kind() == 'apply-variants' and text():find('Cherry-pick and commit', 1, true)
  and text():find('Revert and commit', 1, true)
  and text():find('Three-way fallback', 1, true),
  'v did not open apply variants for the selected commit')
press('-3')
press('a')
assert(vim.api.nvim_get_current_buf() == log and patch_calls[#patch_calls].commit == hash
  and patch_calls[#patch_calls].three_way and not patch_calls[#patch_calls].reverse,
  'apply variants did not pass the selected commit and three-way flag')
press('<Space><Space>')
press('v')
press('v')
assert(patch_calls[#patch_calls].commit == hash and patch_calls[#patch_calls].reverse,
  'apply variants did not reverse the selected patch')
press('<Space><Space>')
press('v')
press('C')
assert(commands[#commands] == 'cherry-pick ' .. hash,
  'apply variants cherry-pick used the wrong commit')
press('<Space><Space>')
press('v')
press('V')
assert(commands[#commands] == 'revert ' .. hash,
  'apply variants revert used the wrong commit')
press('<Space><Space>')
press('r')
assert(kind() == 'rebase' and text():find('Reword commit and descendants', 1, true),
  'log rebase transient omitted selected-commit operations')
assert(text():find('Commit: ' .. hash:sub(1, 12), 1, true),
  'rebase transient lost the selected commit')
press('r')
assert(commands[#commands] == 'rebase ' .. hash,
  'rebase did not use the selected commit shown in its panel')
press('<Space><Space>')
press('V')
assert(kind() == 'revert', 'V did not open the revert flags panel')
press('-n')
press('V')
assert(commands[#commands] == 'revert --no-commit ' .. hash,
  'revert did not pass the selected commit and no-commit switch')
assert(vim.api.nvim_get_current_buf() == log)
press('<Space><Space>')
press('d')
assert(kind() == 'diff', 'd did not open the diff transient')
assert(text():find('Commit: ' .. hash:sub(1, 12), 1, true),
  'diff transient lost the selected commit')
press('d')
assert(vim.deep_equal(require('git.commands').argv(commands[#commands]),
  { 'diff', hash .. '^', hash }),
  'selected commit diff used the wrong revisions')
press('<Space><Space>')
press('X')
assert(kind() == 'reset', 'X did not open the reset transient')
assert(text():find('Commit: ' .. hash:sub(1, 12), 1, true),
  'reset transient lost the selected commit')
press('m')
assert(commands[#commands] == 'reset --mixed ' .. hash,
  'reset did not use the commit under cursor')
vim.api.nvim_set_current_buf(status)
press('<Space><Space>')
press('z')
assert(kind() == 'stash', 'z did not open the stash transient')
press('-u')
press('z')
assert(commands[#commands] == 'stash push --include-untracked',
  'stash did not pass the selected argument')
vim.api.nvim_set_current_buf(log)
local old_input = vim.ui.input
vim.ui.input = function(_, callback) callback('release-test') end
press('<Space><Space>')
press('t')
assert(kind() == 'tag', 't did not open the tag transient')
assert(text():find('Commit: ' .. hash:sub(1, 12), 1, true),
  'tag transient lost the selected commit')
press('t')
assert(commands[#commands] == 'tag release-test ' .. hash,
  'tag did not target the selected commit')
vim.ui.input = old_input

local branch = panel('gitbranch', { 'feature' })
vim.b[branch].branch_map = { 'feature' }
vim.b[branch].branch_kinds = { 'local_' }
press('<Space><Space>')
assert(kind() == 'root' and text():find('Ref: feature', 1, true),
  'branch menu did not identify the selected branch')
assert(text():find('Log feature', 1, true),
  'branch action did not name its target')
local target_ns = vim.api.nvim_get_namespaces().git_transient_menu
local branch_marks = vim.api.nvim_buf_get_extmarks(0, target_ns, 0, -1, { details = true })
assert(vim.iter(branch_marks):any(function(mark)
  return mark[2] == 0 and mark[3] == 0 and mark[4].hl_group == 'GitActionMenuTarget'
    and mark[4].end_col == #'Ref: feature'
end), 'branch menu did not highlight the selected ref')
assert(text():find('Remote…', 1, true) and not text():find('Stash…', 1, true),
  'branch menu did not filter operations for the selected ref')
assert(text():find('Apply variants', 1, true)
  and not text():find('Apply to worktree', 1, true),
  'branch panel exposed direct apply instead of apply variants')
press('v')
assert(kind() == 'apply-variants' and text():find('Ref: feature', 1, true),
  'apply variants lost the selected branch')
local ref_marks = vim.api.nvim_buf_get_extmarks(0, target_ns, 0, -1, { details = true })
assert(vim.iter(ref_marks):any(function(mark)
  return mark[2] == 1 and mark[3] == 0 and mark[4].hl_group == 'GitActionMenuTarget'
    and mark[4].end_col == #'Ref: feature'
end), 'branch operation did not highlight its target')
press('a')
assert(patch_calls[#patch_calls].commit == 'feature',
  'branch apply variants did not target the selected ref')
press('<Space><Space>')
press('b')
assert(kind() == 'branch' and text():find('Rename feature', 1, true),
  'branch menu omitted its selected-ref actions')
local rename_input = vim.ui.input
vim.ui.input = function(_, callback) callback('renamed-feature') end
press('m')
assert(commands[#commands] == 'branch -m feature renamed-feature',
  'branch rename chose the wrong ref')
vim.ui.input = rename_input
press('<Space><Space>')
press('m')
assert(kind() == 'merge')
press('-f')
press('m')
assert(commands[#commands] == 'merge --ff-only feature', 'merge flags were not passed')
local operation = require('git.features.operation')
local original_inspect = operation.inspect
operation.inspect = function() return { kind = 'merge' } end
press('<Space><Space>')
press('m')
assert(kind() == 'merge' and text():find('Continue merge', 1, true)
  and not text():find('Fast-forward only', 1, true),
  'active merge did not replace setup flags with sequence actions')
press('a')
assert(commands[#commands] == 'merge --abort', 'merge abort used the wrong command')
operation.inspect = function() return { kind = 'revert' } end
local active_log = panel('gitlog', { hash .. ' selected commit' })
press('<Space><Space>')
press('A')
assert(kind() == 'revert' and text():find('Revert', 1, true),
  'an active revert was shown as a cherry-pick')
press('a')
assert(commands[#commands] == 'revert --abort', 'revert abort used the wrong command')
operation.inspect = original_inspect
vim.api.nvim_buf_delete(active_log, { force = true })
vim.api.nvim_set_current_buf(branch)
press('<Space><Space>')
press('r')
assert(kind() == 'rebase')
press('-A')
press('-r')
press('r')
assert(commands[#commands] == 'rebase --autostash --rebase-merges feature',
  'rebase flags were not passed')
press('<Space><Space>')
press('P')
assert(kind() == 'push')
press('-f')
press('p')
assert(commands[#commands] == 'push --force-with-lease', 'push flags were not passed')
press('<Space><Space>')
press('p')
assert(kind() == 'pull')
press('-r')
press('p')
assert(commands[#commands] == 'pull --rebase', 'pull flags were not passed')
press('<Space><Space>')
press('f')
assert(kind() == 'fetch')
press('-p')
press('f')
assert(commands[#commands] == 'fetch --prune', 'fetch flags were not passed')

vim.g.git_action_menu_layout = 'float'
press('<Space><Space>')
assert(vim.api.nvim_win_get_config(0).relative == 'editor',
  'float layout setting did not affect the action menu')
press('q')
assert(vim.api.nvim_get_current_buf() == branch)
vim.g.git_action_menu_layout = nil
vim.api.nvim_set_current_buf(status)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
for key, expected in pairs({ A = 'cherry-pick', V = 'revert', v = 'apply-variants', c = 'commit',
  b = 'branch', m = 'merge', r = 'rebase', P = 'push', F = 'pull', f = 'fetch',
  C = 'clone', d = 'diff', l = 'log', X = 'reset', z = 'stash', t = 'tag',
  B = 'bisect', Z = 'worktree', M = 'remote', i = 'ignore', o = 'submodule',
  y = 'refs' }) do
  press('<Space><Space>')
  press(key)
  assert(kind() == expected, key .. ' opened the wrong operation panel')
  press('q')
end

local reflog_module = require('git.features.reflog')
local original_reflog_entry = reflog_module.entry_at
reflog_module.entry_at = function(_, row)
  return row == 1 and { hash = hash, selector = 'HEAD@{0}' } or nil
end
local reflog_panel = panel('gitreflog', { 'HEAD@{0}  ' .. hash:sub(1, 7) })
local copied_selector
vim.keymap.set('n', 'y', function() copied_selector = 'HEAD@{0}' end,
  { buffer = reflog_panel })
press('<Space><Space>')
assert(text():find('Reflog: HEAD@{0}', 1, true)
  and text():find('Cherry-pick', 1, true),
  'reflog action menu lost the selected destination')
press('v')
assert(kind() == 'apply-variants' and text():find('Commit: ' .. hash:sub(1, 12), 1, true),
  'reflog apply variants lost the selected destination')
press('q')
press('<Space><Space>')
press('Y')
assert(copied_selector == 'HEAD@{0}', 'reflog selector action did not reuse panel mapping')
reflog_module.entry_at = original_reflog_entry

local worktree_panel = panel('gitworktree', { '* /tmp/other  feature  ' .. hash:sub(1, 7) })
vim.b[worktree_panel].worktree_entries = {
  { path = root .. '/other', branch = 'feature', head = hash },
}
press('<Space><Space>')
assert(text():find('Worktree: ' .. root .. '/other', 1, true)
  and text():find('Worktree…', 1, true)
  and not text():find('Stash…', 1, true),
  'worktree action menu lost the selected worktree or showed unrelated actions')
press('v')
assert(kind() == 'apply-variants' and text():find('Ref: feature', 1, true),
  'worktree apply variants lost the selected branch')
press('a')
assert(patch_calls[#patch_calls].commit == hash,
  'worktree apply variants did not use its selected HEAD')
press('<Space><Space>')
press('Z')
assert(kind() == 'worktree' and text():find(root .. '/other', 1, true),
  'worktree transient did not inherit the selected path')
press('q')
press('<Space><Space>')
press('Z')
local move_input = vim.ui.input
vim.ui.input = function(opts, callback)
  assert(vim.trim(opts.prompt) == 'New worktree path:',
    'selected worktree was not used as move source')
  callback(root .. '/moved')
end
press('m')
assert(vim.deep_equal(require('git.commands').argv(commands[#commands]),
  { 'worktree', 'move', root .. '/other', root .. '/moved' }),
  'worktree move did not target the selected path')
vim.ui.input = move_input

for _, buf in ipairs({ status, log, branch, reflog_panel, worktree_panel }) do
  if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
end
vim.fn.delete(root, 'rf')
print('PASS: contextual action menu, split/float layouts, flags, and Git arguments')
