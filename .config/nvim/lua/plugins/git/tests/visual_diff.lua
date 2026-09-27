-- Run from plugin root: nvim --headless --clean -u NONE -l tests/visual_diff.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
package.loaded['git.features.status_watch'] = { subscribe = function() return function() end end }
package.loaded['git.features.worktree_watch'] = { subscribe = function() return function() end end }

local root = vim.fn.tempname() .. ' visual diff'
vim.fn.mkdir(root, 'p')
local function git(args)
  local command = { 'git', '-C', root }
  vim.list_extend(command, args)
  local result = vim.system(command, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout or '')
end
local function commit(subject, content)
  vim.fn.writefile({ content }, root .. '/tracked.txt')
  git({ 'add', '.' })
  git({ 'commit', '-qm', subject })
  return git({ 'rev-parse', 'HEAD' })
end
git({ 'init', '-qb', 'main' })
git({ 'config', 'user.name', 'Test' })
git({ 'config', 'user.email', 'test@example.invalid' })
local first = commit('first', 'one')
local second = commit('second', 'two')
local third = commit('third', 'three')
vim.fn.writefile({ 'alpha' }, root .. '/a file.txt')
vim.fn.writefile({ 'beta' }, root .. '/b.txt')

local opened = {}
vim.api.nvim_create_user_command('DiffviewOpen', function(opts)
  opened[#opened + 1] = opts.fargs
end, { nargs = '*' })
local executable = vim.fn.executable
vim.fn.executable = function(name) return name == 'gh' and 0 or executable(name) end
local status = require('git.features.status')
status.setup(vim.api.nvim_create_augroup('StatusVisualDiffTest', { clear = true }))
local b = assert(status.open({ work_tree = root, split = true }))
local function rows(buf) return vim.api.nvim_buf_get_lines(buf or b, 0, -1, false) end
local function row(pattern, buf)
  for index, line in ipairs(rows(buf)) do if line:match(pattern) then return index end end
end
local function press(key, mode)
  local mapping = vim.fn.maparg(key, mode or 'n', false, true)
  assert(type(mapping.callback) == 'function', 'missing ' .. (mode or 'n') .. ' mapping ' .. key)
  mapping.callback()
end
local function select(first_row, last_row)
  vim.api.nvim_win_set_cursor(0, { first_row, 0 })
  vim.cmd('normal! V' .. (last_row > first_row and tostring(last_row - first_row) .. 'j' or ''))
  assert(vim.fn.mode() == 'V')
end
local function opened_range(base, tip)
  local expected = base .. '..' .. tip
  assert(vim.wait(2000, function()
    for _, args in ipairs(opened) do
      if vim.tbl_contains(args, expected) then return true end
    end
    return false
  end, 10), 'Diffview did not open ' .. expected .. ': ' .. vim.inspect(opened))
  for index, args in ipairs(opened) do
    if vim.tbl_contains(args, expected) then table.remove(opened, index); return end
  end
end
local diff = require('git.features.commit_diff')
local root_ok, root_err = diff.open_selected(root, { first:sub(1, 7) })
assert(root_ok, root_err)
opened_range(git({ 'hash-object', '-t', 'tree', '--stdin' }), first)
local divergent = git({ 'commit-tree', git({ 'rev-parse', first .. '^{tree}' }),
  '-p', first, '-m', 'divergent' })
local unrelated, unrelated_err = diff.open_selected(root, { third, divergent })
assert(not unrelated and unrelated_err:find('ancestry chain', 1, true),
  'Visual commit diff compared unrelated histories')
assert(vim.wait(3000, function() return row('^%? a file%.txt$') and row('third$') end, 10))
local recent = assert(row('third$'))
vim.wo.foldenable = false
vim.api.nvim_win_set_cursor(0, { recent, 0 })
press('d')
opened_range(second, third)
select(recent, recent + 1)
press('d', 'x')
opened_range(first, third)

select(recent, recent + 1)
press('<Space><Space>', 'x')
assert(vim.b.git_action_menu_kind == 'root' and
  table.concat(rows(vim.api.nvim_get_current_buf()), '\n'):find('2 selected commits', 1, true))
local commands = {}
require('git.commands').git = function(opts) commands[#commands + 1] = opts.args end
press('A')
assert(vim.b.git_action_menu_kind == 'cherry-pick')
press('A')
assert(commands[#commands] == 'cherry-pick --ff ' .. second:sub(1, 7) .. ' ' .. third:sub(1, 7)
  or commands[#commands] == 'cherry-pick --ff ' .. second .. ' ' .. third,
  'Visual menu cherry-pick did not use both commits in oldest-first order: ' .. tostring(commands[#commands]))

local a, other = assert(row('^%? a file%.txt$')), assert(row('^%? b%.txt$'))
assert(other == a + 1)
select(a, other)
press('d', 'x')
assert(vim.wait(2000, function() return #opened > 0 end, 10))
local args = table.remove(opened)
assert(vim.tbl_contains(args, '--') and vim.tbl_contains(args, 'a file.txt')
  and vim.tbl_contains(args, 'b.txt'), vim.inspect(args))

select(a, other)
press('<Space><Space>', 'x')
assert(table.concat(rows(vim.api.nvim_get_current_buf()), '\n'):find('2 selected untracked files', 1, true))
press('s')
assert(vim.wait(3000, function() return row('^A a file%.txt$') and row('^A b%.txt$') end, 10),
  'Visual menu did not stage selected files')
local staged_a, staged_b = assert(row('^A a file%.txt$')), assert(row('^A b%.txt$'))
select(staged_a, staged_b)
press('d', 'x')
assert(vim.wait(2000, function() return #opened > 0 end, 10))
args = table.remove(opened)
assert(vim.tbl_contains(args, '--cached') and vim.tbl_contains(args, 'a file.txt')
  and vim.tbl_contains(args, 'b.txt'), 'staged Visual d did not compare HEAD with index')
vim.wait(500, function() return false end)

git({ 'stash', 'push', '-q', '-m', 'older' })
vim.fn.writefile({ 'newer change' }, root .. '/tracked.txt')
git({ 'stash', 'push', '-q', '-m', 'newer' })
status.refresh_buffer(b)
assert(vim.wait(3000, function()
  return row('stash@{0}') and row('stash@{1}') and not row('^A a file%.txt$')
end, 10))
vim.wo.foldenable = false
local newest_stash, older_stash = assert(row('stash@{0}')), assert(row('stash@{1}'))
assert(older_stash == newest_stash + 1)
vim.api.nvim_win_set_cursor(0, { newest_stash, 0 })
press('d')
opened_range(git({ 'rev-parse', 'stash@{0}^1' }), git({ 'rev-parse', 'stash@{0}' }))
select(newest_stash, older_stash)
press('d', 'x')
opened_range(git({ 'rev-parse', 'stash@{1}' }), git({ 'rev-parse', 'stash@{0}' }))
select(newest_stash, older_stash)
press('<Space><Space>', 'x')
assert(table.concat(rows(vim.api.nvim_get_current_buf()), '\n'):find('2 selected stashes', 1, true))
press('d')
opened_range(git({ 'rev-parse', 'stash@{1}' }), git({ 'rev-parse', 'stash@{0}' }))

vim.fn.executable = executable
vim.fn.delete(root, 'rf')
print('PASS: status Visual commit/file diff and multi-selection action menu')
