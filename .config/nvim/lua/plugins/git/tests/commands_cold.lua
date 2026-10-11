local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local commands = require('git.features.commands')
for _, name in ipairs({ 'fixup_commit', 'mix_index', 'mix_index_with_input', 'reword_commit',
  'move_commit', 'drop_commits', 'revert_commits', 'git_push', 'git_cherry_pick',
  'reflog_undo', 'reflog_redo', 'is_preview_open', 'open_preview_window', 'reload_log' }) do
  assert(type(commands[name]) == 'function', name .. ' requires provider setup')
end
assert(vim.fn.exists(':GitFixupBase') == 0, 'requiring panel helpers must not register Ex commands')
package.loaded['git.features.status_watch'] = { subscribe = function() return function() end end }
package.loaded['git.features.worktree_watch'] = { subscribe = function() return function() end end }
local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false' }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr); return vim.trim(result.stdout or '')
end
git({ 'init', '-qb', 'main' })
git({ 'commit', '--allow-empty', '-qm', 'base' })
git({ 'commit', '--allow-empty', '-qm', 'selected commit' })
local head = git({ 'rev-parse', 'HEAD' })
local calls = {}
package.loaded['git.features.history_edits'] = {
  mix_index = function(work_tree, hash, message)
    calls[#calls + 1] = { action = 'mix', root = work_tree, hash = hash, message = message }; return head
  end,
  fixup = function(work_tree, hash)
    calls[#calls + 1] = { action = 'parent', root = work_tree, hash = hash }; return head
  end,
}
local executable = vim.fn.executable
vim.fn.executable = function(name) return name == 'gh' and 0 or executable(name) end
local status = require('git.features.status')
status.setup(vim.api.nvim_create_augroup('ColdCommandsStatusTest', { clear = true }))
local buf = assert(status.open({ work_tree = root, split = true, focus = false, auto_fetch = false }))
local row
assert(vim.wait(5000, function()
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:find('selected commit', 1, true) then row = i; return true end
  end
end, 10), 'selected commit appears in Status')
vim.api.nvim_win_set_cursor(0, { row, 0 })
local hash = vim.api.nvim_get_current_line():match('^(%x+)')
local prompt
vim.ui.input = function(_, callback) prompt = callback end
local function press(key)
  local mapping = vim.fn.maparg(key, 'n', false, true)
  assert(type(mapping.callback) == 'function', 'missing key: ' .. key)
  mapping.callback()
end
press('cf')
assert(prompt and #calls == 0, 'cf reaches its input without changing history')
prompt(nil)
assert(#calls == 0, 'cancelled cf must not rewrite')
press('cf'); prompt('edited message')
assert(calls[1].action == 'mix' and calls[1].root == root and calls[1].hash == hash and calls[1].message == 'edited message')
press('gH'); press('A')
assert(calls[2].action == 'mix' and calls[2].message == nil)
press('gH'); press('F')
assert(calls[3].action == 'parent' and calls[3].root == root and calls[3].hash == hash,
  'gHF delegates to the parent fixup helper before provider setup')
assert(git({ 'rev-parse', 'HEAD' }) == head, 'UI routing test changed actual history')
commands.setup()
assert(vim.fn.exists(':GitFixupBase') == 2 and vim.fn.exists(':GCherryPick') == 2)
local helper = commands.fixup_commit
commands.setup()
assert(commands.fixup_commit == helper, 'setup must preserve helper identity and state')
for _, b in ipairs(vim.api.nvim_list_bufs()) do pcall(vim.api.nvim_buf_delete, b, { force = true }) end
vim.fn.delete(root, 'rf')
print('PASS: cold Status cf/gHA/gHF helpers, cancellation, deferred registration and stable repeated setup')
