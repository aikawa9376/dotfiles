local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
vim.opt.rtp:prepend(plugin)
local model = require('git.features.commit_model')
local rewrite = require('git.features.commit_rewrite')
local edits = require('git.features.history_edits')
local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
local function git(args) return vim.trim(assert(model.git(root, args))) end
local function write(text) vim.fn.writefile(text, root .. '/file') end
local function commit(message) git({ 'add', '.' }); git({ 'commit', '-qm', message }); return git({ 'rev-parse', 'HEAD' }) end
git({ 'init', '-q', '-b', 'main' }); git({ 'config', 'user.name', 'Test' }); git({ 'config', 'user.email', 'test@example.invalid' })
git({ 'config', 'commit.gpgsign', 'false' })
write({ 'one' }); local first = commit('first\n\nbody')
write({ 'two' }); local head = commit('second')
write({ 'old stash' }); git({ 'stash', 'push', '-qm', 'existing' })
local stash = git({ 'rev-parse', 'refs/stash' })
local function reflog() return git({ 'reflog', '--format=%H%x09%gs' }) end
local original_reflog = reflog()
require('git').setup()
vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/file'))
local origin = vim.api.nvim_get_current_buf()
local system = vim.system
local function no_mutation(action)
  local calls = {}
  vim.system = function(argv, opts, callback)
    for _, value in ipairs(argv) do
      assert(not vim.tbl_contains({ 'commit', 'stash', 'rebase', 'reset', 'apply', 'commit-tree' }, value),
        'no-op started a Git mutation: ' .. table.concat(argv, ' '))
    end
    calls[#calls + 1] = argv
    return system(argv, opts, callback)
  end
  action()
  vim.system = system
  assert(git({ 'rev-parse', 'HEAD' }) == head)
  assert(reflog() == original_reflog, 'no-op added a reflog entry')
  assert(git({ 'rev-parse', 'refs/stash' }) == stash)
  return calls
end
-- Same-message backend reword must not even create a stash on a dirty index.
write({ 'staged' }); git({ 'add', 'file' }); write({ 'staged', 'unstaged' })
vim.fn.writefile({ 'untracked' }, root .. '/untracked')
local staged, unstaged = git({ 'diff', '--cached' }), git({ 'diff' })
no_mutation(function()
  local hash, err, changed = rewrite.apply(root, first:sub(1, 8), { message = { 'first', '', 'body' } })
  assert(hash == first and not err and changed == false)
  hash, err, changed = rewrite.apply(root, head, { message = { 'second', '' } })
  assert(hash == head and not err and changed == false)
  assert(select(3, rewrite.apply(root, head, {})) == false)
  local callbacks = 0
  require('git.features.commands').reword_commit(first, 'first\n\nbody', function() callbacks = callbacks + 1 end)
  vim.wait(20, function() return false end)
  assert(callbacks == 0, 'unchanged reword refreshed its panel')
end)
assert(git({ 'diff', '--cached' }) == staged and git({ 'diff' }) == unstaged)
-- An unchanged message float save closes without confirmation or Git commands.
local actions = require('git.features.commit_actions')
local completed = false
actions.open_edit_commit(first, origin, { reopen = false, on_complete = function() completed = true end })
local draft = vim.api.nvim_get_current_buf()
local confirm = vim.fn.confirm
vim.fn.confirm = function() error('unchanged save asked for confirmation') end
local calls = no_mutation(function() vim.cmd('write') end)
vim.fn.confirm = confirm
assert(#calls == 0 and not completed and not vim.api.nvim_buf_is_valid(draft))
-- An unchanged inline Commit save is also local only, and A/cw only focus text.
local view = require('git.features.commit')
local b = view.open({ work_tree = root, revision = first })
calls = no_mutation(function()
  vim.fn.maparg('A', 'n', false, true).callback()
  assert(view.write(b))
end)
assert(#calls == 0)
vim.api.nvim_set_current_buf(origin)
git({ 'reset', '--hard', head }); write({ 'unstaged only' }); original_reflog = reflog()
-- Empty-index fixup and same-message reword-with-index do not create helpers.
no_mutation(function()
  local hash, err, changed = edits.mix_index(root, first, 'first\n\nbody')
  assert(hash == head and not err and changed == false)
  assert(select(3, edits.mix_index(root, head)) == false)
  vim.cmd('Git commit --amend --no-edit')
end)
-- Real Status A/ce callbacks are guarded, and A never applies the selected stash.
local status_api = require('git.features.status')
local status = status_api.open({ work_tree = root, split = true })
assert(vim.wait(5000, function()
  return not table.concat(vim.api.nvim_buf_get_lines(status, 0, -1, false), '\n'):find('Loading', 1, true)
end, 20))
local function press(key)
  local map = vim.fn.maparg(key, 'n', false, true)
  assert(map.buffer == 1 and (map.callback or map.rhs), key)
  if map.callback then return map.callback() end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(map.rhs, true, false, true), 'nx', false)
end
no_mutation(function() press('A'); press('ce') end)
-- Stage a real change, select a stash row, and A amends HEAD with that index.
write({ 'amended stage' }); git({ 'add', 'file' }); write({ 'amended stage', 'unstaged retained' })
status_api.open({ work_tree = root, split = true })
assert(vim.wait(5000, function()
  return table.concat(vim.api.nvim_buf_get_lines(status, 0, -1, false), '\n'):find('Staged', 1, true)
end, 20))
for row, line in ipairs(vim.api.nvim_buf_get_lines(status, 0, -1, false)) do
  if line:match('^stash@{') then vim.api.nvim_win_set_cursor(0, { row, 0 }); break end
end
press('A')
assert(git({ 'rev-parse', 'HEAD' }) ~= head)
assert(git({ 'show', 'HEAD:file' }) == 'amended stage')
assert(git({ 'show', '-s', '--format=%s', 'HEAD' }) == 'second')
assert(git({ 'diff', '--cached' }) == '')
assert(git({ 'diff' }):find('+unstaged retained', 1, true))
assert(git({ 'rev-parse', 'refs/stash' }) == stash)
-- Meaningful metadata requests still execute even without staged changes.
vim.api.nvim_set_current_buf(origin)
vim.cmd('Git commit --amend --no-edit --author="Other <other@example.invalid>"')
assert(git({ 'show', '-s', '--format=%an', 'HEAD' }) == 'Other')
for _, buf in ipairs(vim.api.nvim_list_bufs()) do pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
vim.fn.delete(root, 'rf')
print('PASS: unchanged reword/amend/fixup start no mutations, hashes/reflogs/stash stable, float/inline saves, Status A stage-only and metadata flags')
