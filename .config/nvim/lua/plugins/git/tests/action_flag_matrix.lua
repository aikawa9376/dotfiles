-- Run from plugin root: nvim --headless --clean -u NONE -l tests/action_flag_matrix.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path

local root = vim.fn.tempname() .. ' flag matrix'
vim.fn.mkdir(root, 'p')
local function real_git(args)
  local argv = { 'git', '-C', root }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
real_git({ 'init', '-qb', 'main' })
real_git({ 'config', 'user.name', 'Test' })
real_git({ 'config', 'user.email', 'test@example.invalid' })
vim.fn.writefile({ 'base' }, root .. '/file.txt')
real_git({ 'add', '.' })
real_git({ 'commit', '-qm', 'base' })
local hash = real_git({ 'rev-parse', 'HEAD' })

local commands = require('git.commands')
local original_git = commands.git
local sent
commands.git = function(opts) sent = commands.argv(opts.args) end
local original_input = vim.ui.input
local answers = {}
vim.ui.input = function(_, callback)
  local answer = table.remove(answers, 1)
  assert(answer ~= nil, 'unexpected transient prompt')
  callback(answer)
end
local function input(value) answers[#answers + 1] = value end
local function press(key)
  local map = vim.fn.maparg(key, 'n', false, true)
  assert(type(map.callback) == 'function', 'missing key ' .. key)
  map.callback()
end
local function menu(key)
  press('<Space><Space>')
  press(key)
end
local function expect(...)
  local required = { ... }
  for _, arg in ipairs(required) do
    assert(vim.tbl_contains(sent or {}, arg),
      'missing ' .. arg .. ' in ' .. table.concat(sent or {}, ' '))
  end
  sent = nil
end

local utils = require('git.utils')
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'Status' })
utils.set_buf_work_tree(buf, root)
vim.bo[buf].filetype = 'fugitivestatus'
vim.api.nvim_set_current_buf(buf)
require('git.features.magit_actions').attach(buf)

menu('c')
input('Named Author <author@example.invalid>'); press('-A')
input('2024-01-01'); press('-D')
input('KEY-ID'); press('-S')
input(hash); press('-C')
press('c')
expect('commit', '--author=Named Author <author@example.invalid>', '--date=2024-01-01',
  '--gpg-sign=KEY-ID', '--reuse-message=' .. hash)

for _, suffix in ipairs({ { 'f', '--fixup=' }, { 's', '--squash=' } }) do
  menu('c')
  press('-s'); press('-n')
  input(hash); press(suffix[1])
  expect('commit', '--signoff', '--no-verify', suffix[2] .. hash)
end

local reworded = false
vim.keymap.set('n', 'cw', function() reworded = true end, { buffer = buf })
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { hash .. ' selected commit' })
menu('c'); press('w')
assert(reworded and not sent, 'reword ignored the selected commit and amended HEAD')
menu('b')
input(root .. '/selected worktree'); press('w')
expect('worktree', 'add', root .. '/selected worktree', hash)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'Status' })

menu('b')
input(root .. '/prompted worktree'); input('main'); press('w')
expect('worktree', 'add', root .. '/prompted worktree', 'main')

menu('d')
input('3'); press('-U')
input('patience'); press('-A')
press('-M'); press('-s'); press('s')
expect('diff', '--cached', '-U3', '--diff-algorithm=patience', '-M', '--stat')

menu('A')
input('ours'); press('=s')
input('KEY-ID'); press('-S')
input(hash); press('A')
expect('cherry-pick', '--ff', '--strategy=ours', '--gpg-sign=KEY-ID', hash)

menu('V')
press('-E')
input('recursive'); press('=s')
input('KEY-ID'); press('-S')
input(hash); press('V')
expect('revert', '--no-edit', '--strategy=recursive', '--gpg-sign=KEY-ID', hash)

menu('m')
input('ort'); press('-s')
input('theirs'); press('-X')
press('-b')
input('KEY-ID'); press('-S')
press('=s')
input(hash); press('m')
expect('merge', '--strategy=ort', '--strategy-option=theirs', '-Xignore-space-change',
  '--gpg-sign=KEY-ID', '--signoff', hash)

menu('r')
press('-d'); press('-t'); press('-f')
input('rebase-cousins'); press('=r')
input('echo tested'); press('-x')
input('KEY-ID'); press('-S')
press('=s')
input(hash); press('r')
expect('rebase', '--committer-date-is-author-date', '--ignore-date', '--force-rebase',
  '--rebase-merges=rebase-cousins', '--exec=echo tested', '--gpg-sign=KEY-ID', '--signoff', hash)

menu('P')
press('-F'); press('-n')
input('skip-ci,ci.skip'); press('-o')
press('p')
expect('push', '--force', '--dry-run', '--push-option=skip-ci', '--push-option=ci.skip')

menu('F')
input('merges'); press('=r')
press('-A'); press('-F'); press('p')
expect('pull', '--rebase=merges', '--autostash', '--force')

menu('f')
press('-u'); press('-F'); press('f')
expect('fetch', '--unshallow', '--force')

menu('b')
press('-m'); press('-r')
input('main'); press('b')
expect('checkout', '--merge', '--recurse-submodules', 'main')

menu('t')
input('KEY-ID'); press('-u')
input('signed-tag'); input('Tag message'); press('t')
expect('tag', '-s', '--local-user=KEY-ID', '-m', 'Tag message', 'signed-tag')

menu('C')
press('-B')
input('upstream'); press('-o')
input('blob:none'); press('-f')
input('https://example.invalid/repo.git'); input(root .. '/clone'); press('C')
expect('clone', '--single-branch', '--origin=upstream', '--filter=blob:none')

menu('z')
press('-k')
input('file.txt'); press('--')
press('P')
expect('stash', 'push', '--keep-index', '--', 'file.txt')

menu('M')
press('-f')
input('upstream'); input('https://example.invalid/repo.git'); press('a')
expect('remote', 'add', '-f', 'upstream')

menu('o')
press('-f'); press('-N'); press('-U'); press('-R'); press('u')
expect('submodule', 'update', '--force', '--no-fetch', '--remote', '--rebase')

assert(#answers == 0, 'unused transient input')
vim.ui.input = original_input
commands.git = original_git
vim.api.nvim_buf_delete(buf, { force = true })
vim.fn.delete(root, 'rf')
print('PASS: Magit-style flags reach their Git actions')
