-- Run: nvim --headless --clean -u NONE -l tests/reflog_checkpoints.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
local function git(args, opts)
  local argv = { 'git', '-C', root }; vim.list_extend(argv, args)
  local result = vim.system(argv, vim.tbl_extend('force', { text = true }, opts or {})):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout or '')
end
local function commit(subject)
  vim.fn.writefile({ subject }, root .. '/file.txt')
  git({ 'add', '.' }); git({ 'commit', '-qm', subject })
  return git({ 'rev-parse', 'HEAD' })
end
git({ 'init', '-q' }); git({ 'config', 'user.name', 'Test' }); git({ 'config', 'user.email', 'test@example.invalid' })
git({ 'config', 'commit.gpgsign', 'false' })
commit('base')
local before_amend = commit('second')
git({ 'commit', '--amend', '-qm', 'second amended' })
local before_rebase = commit('third')
git({ 'rebase', '-i', 'HEAD~2' }, { env = { GIT_SEQUENCE_EDITOR = "sed -i '1s/^pick/edit/'", GIT_EDITOR = 'true' } })
git({ 'commit', '--amend', '-qm', 'amended inside rebase' })
git({ 'rebase', '--continue' }, { env = { GIT_EDITOR = 'true' } })
local before_reset = git({ 'rev-parse', 'HEAD' })
git({ 'reset', '--hard', 'HEAD~1' }); git({ 'reset', '--hard', 'HEAD' })
package.loaded['features.commands'] = {
  close_preview = function() end, close_commit_info_float = function() end, is_preview_open = function() return false end,
}
local reflog = require('features.reflog')
reflog.setup(vim.api.nvim_create_augroup('ReflogCheckpointTest', { clear = true }))
require('fugitive_utils').set_buf_work_tree(0, root)
vim.cmd('Greflog')
local b = vim.api.nvim_get_current_buf()
local function green_rows()
  local rows = {}
  local ns = vim.api.nvim_create_namespace('fugitive_reflog_static')
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(b, ns, 0, -1, { details = true })) do
    if mark[4].hl_group == 'FugitiveReflogCheckpoint' then
      assert(mark[3] == 0, 'marker must color the selector, not the commit hash')
      rows[#rows + 1] = mark[2] + 1
    end
  end
  return rows
end
local hashes = vim.split(git({ 'reflog', '--format=%H' }), '\n', { plain = true })
local marked = {}
for _, row in ipairs(green_rows()) do marked[#marked + 1] = hashes[row] end
assert(#marked == 3, vim.inspect(marked))
for _, hash in ipairs({ before_amend, before_rebase, before_reset }) do
  assert(vim.tbl_contains(marked, hash), 'missing pre-operation destination: ' .. hash)
end
local system = vim.system
local output
vim.system = function(argv, ...)
  if argv[1] == 'git' and argv[2] == 'reflog' then
    return { wait = function() return { code = 0, stdout = output } end }
  end
  return system(argv, ...)
end
local function fixture(records, expected)
  local lines = {}
  for _, record in ipairs(records) do
    lines[#lines + 1] = record[1] .. '\t' .. record[1]:sub(1, 7) .. '\tHEAD@{1700000000}\t' .. record[2]
  end
  output = table.concat(lines, '\n') .. '\n'
  vim.fn.maparg('R', 'n', false, true).callback()
  assert(vim.deep_equal(green_rows(), expected), vim.inspect(green_rows()))
end
local a, c, d = string.rep('a', 40), string.rep('c', 40), string.rep('d', 40)
-- An ongoing rebase can have an amend as its newest record.
fixture({ { a, 'commit (amend): internal' }, { c, 'rebase (start): checkout base' }, { d, 'commit: before' } }, { 3 })
-- No invented recovery point when the start predates the loaded reflog window.
fixture({ { a, 'rebase (finish): returning to main' }, { c, 'commit (amend): internal' }, { d, 'rebase (pick): old' } }, {})
fixture({ { a, 'rebase (abort): returning to main' }, { c, 'rebase (start): checkout base' }, { d, 'commit: before' } }, { 3 })
-- Ordinary commits, branch switches and no-op resets are not checkpoints.
fixture({ { a, 'reset: moving to HEAD' }, { a, 'checkout: moving from topic to main' }, { c, 'commit: ordinary' }, { d, 'commit: initial' } }, {})
-- Refresh replaces, rather than accumulates, green marks.
fixture({ { a, 'commit (amend): amended' }, { c, 'commit: before' } }, { 2 })
fixture({ { a, 'commit: plain' }, { c, 'commit: before' } }, {})
vim.system = system
vim.api.nvim_buf_delete(b, { force = true }); vim.fn.delete(root, 'rf')
print('PASS: real amend/rebase/reset recovery selectors, internal/ongoing/truncated/aborted rebases, no-op reset, refresh cleanup')
