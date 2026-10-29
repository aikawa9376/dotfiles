-- Availability uses real repository state; mutations are captured at the command boundary.
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local base = vim.fn.tempname()
vim.fn.mkdir(base, 'p')
vim.env.XDG_STATE_HOME = base .. '/state'
vim.o.columns, vim.o.lines = 240, 80
local notifications, sent = {}, {}
local original_input = vim.ui.input
vim.notify = function(message) notifications[#notifications + 1] = tostring(message) end
local actions = require('git.features.magit_actions')
local utils = require('git.utils')
local menu = require('git.features.transient_menu')
require('git.commands').git = function(opts) sent[#sent + 1] = require('git.commands').argv(opts.args) end
local spec, original_show = nil, menu.show
menu.show = function(value, opts) spec = value; return original_show(value, opts) end
local function git(root, ...)
  local argv = { 'git', '-C', root }; vim.list_extend(argv, { ... })
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, table.concat(argv, ' ') .. '\n' .. (result.stderr or ''))
  return vim.trim(result.stdout)
end
local function repo(name)
  local root = base .. '/' .. name; vim.fn.mkdir(root, 'p')
  git(root, 'init', '-qb', 'main')
  git(root, 'config', 'user.name', 'Fixture')
  git(root, 'config', 'user.email', 'fixture@example.invalid')
  git(root, 'config', 'commit.gpgsign', 'false')
  return root
end
local function write(root, text)
  vim.fn.writefile({ text }, root .. '/file.txt')
end
local function commit(root, text)
  write(root, text); git(root, 'add', 'file.txt'); git(root, 'commit', '-qm', text)
  return git(root, 'rev-parse', 'HEAD')
end
local function panel(root, ft, line)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line or 'Repository' })
  utils.set_buf_work_tree(buf, root); vim.bo[buf].filetype = ft or 'gitstatus'
  actions.attach(buf)
  return buf
end
local function press(key)
  local mapping = vim.fn.maparg(key, 'n', false, true)
  assert(type(mapping.callback) == 'function', 'Missing mapping ' .. key)
  mapping.callback()
end
local function open(prefix)
  press('<Space><Space>'); if prefix then press(prefix) end
end
local function text() return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n') end
local checks = 0
local function expect(key, enabled, message)
  local found
  for _, group in ipairs(spec.groups) do for _, action in ipairs(group.actions) do
    if action.key == key then found = action end
  end end
  assert(found, 'Action missing: ' .. key)
  local dimmed = text():find('· ' .. key .. ' ', 1, true) ~= nil
  assert(dimmed == not enabled, message or (spec.kind .. ' ' .. key .. ' availability mismatch\n' .. text()))
  if not enabled then
    local painted = false
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0,
      vim.api.nvim_get_namespaces().git_transient_menu, 0, -1, { details = true })) do
      if mark[4].hl_group == 'Comment' then
        local cell = lines[mark[2] + 1]:sub(mark[3] + 1, mark[4].end_col)
        if cell:find('· ' .. key .. ' ', 1, true) then painted = true end
      end
    end
    assert(painted, 'Disabled action did not receive uniform dim highlighting: ' .. key)
    local before, count = vim.api.nvim_get_current_buf(), #sent
    press(key)
    assert(vim.api.nvim_get_current_buf() == before and #sent == count, 'Disabled action executed: ' .. key)
    assert(#notifications > 0, 'Disabled action did not explain its requirement')
  end
  checks = checks + 1
end
local function refresh()
  vim.api.nvim_exec_autocmds('User', { pattern = 'GitChanged', data = {} })
  vim.wait(30, function() return false end, 5)
end
local root = repo('normal')
local first = commit(root, 'base')
local tip = commit(root, 'tip')
local status = panel(root)

-- No-change commit, stateful arguments, index changes while the menu stays open.
open('c'); expect('c', false); expect('a', true)
press('-e'); expect('c', true); press('-e'); expect('c', false)
write(root, 'unstaged'); refresh(); expect('c', false)
press('-a'); expect('c', true); press('-a')
git(root, 'add', 'file.txt'); refresh(); expect('c', true)
git(root, 'reset', '--hard', 'HEAD'); refresh(); expect('c', false)
press('q')
write(root, 'tracked WIP'); open('r'); expect('r', false)
git(root, 'config', 'rebase.autoStash', 'yes'); refresh(); expect('r', true); press('q')
git(root, 'config', '--unset', 'rebase.autoStash'); git(root, 'reset', '--hard', 'HEAD')

-- Remote-specific suffixes have no implicit fallback. Generic prompts remain usable.
open('P'); expect('p', false); expect('u', false); expect('e', true); expect('r', true)
git(root, 'remote', 'add', 'origin', root)
git(root, 'remote', 'add', 'backup', root)
git(root, 'config', 'branch.main.pushRemote', 'backup')
refresh(); expect('p', true); expect('u', false)
git(root, 'config', 'branch.main.remote', 'origin')
git(root, 'config', 'branch.main.merge', 'refs/heads/main')
refresh(); expect('u', true)
git(root, 'config', '--unset', 'branch.main.merge')
local count = #sent; press('u') -- No refresh: execution must still reject it.
assert(#sent == count and spec.kind == 'push')
expect('u', false); press('q')
open('F'); expect('u', false); expect('p', true); expect('e', true); press('q')
open('r'); expect('p', false); expect('u', false)
git(root, 'update-ref', 'refs/remotes/backup/main', tip)
git(root, 'config', 'branch.main.merge', 'refs/heads/main')
git(root, 'update-ref', 'refs/remotes/origin/main', tip)
refresh(); expect('p', true); expect('u', true); press('q')
write(root, 'pull WIP'); open('F'); press('-r'); expect('u', false)
press('-A'); expect('u', true); press('-A')
git(root, 'config', 'rebase.autoStash', 'true'); refresh(); expect('u', true)
git(root, 'config', 'pull.autostash', 'false'); refresh(); expect('u', false); press('q')
git(root, 'config', '--unset', 'rebase.autoStash'); git(root, 'config', '--unset', 'pull.autostash')
git(root, 'reset', '--hard', 'HEAD')
open('f'); expect('-u', false); expect('u', true); press('q')
open('f'); press('-a'); expect('p', false); expect('u', false); expect('e', false); expect('f', true)
press('-a'); expect('p', true); press('q')
open('l'); press('-f'); expect('h', false)
vim.ui.input = function(_, cb) cb('file.txt') end; press('--'); vim.ui.input = original_input
expect('h', true); press('-g'); press('-r'); expect('h', false); expect('r', true); press('q')

-- Single-file Unstage has the same section constraint as Visual Unstage.
local renderer = require('git.features.status_renderer')
local old_entry_at, section = renderer.entry_at, 'unstaged'
renderer.entry_at = function() return { path = 'file.txt', section = section } end
vim.keymap.set('n', 's', function() end, { buffer = status })
vim.keymap.set('n', 'u', function() end, { buffer = status })
open(); expect('u', false); expect('s', true); press('q')
section = 'staged'; open(); expect('u', true); press('q')
renderer.entry_at = old_entry_at

-- A pending prompt must revalidate the very action that opened it.
local pending
vim.ui.input = function(_, callback) pending = callback end
open('F'); press('e'); assert(pending)
vim.fn.writefile({ tip }, root .. '/.git/MERGE_HEAD')
count = #sent; pending('origin'); assert(#sent == count)
vim.fn.delete(root .. '/.git/MERGE_HEAD')
vim.ui.input = original_input
vim.api.nvim_set_current_buf(status)

-- Conflicting sequences dim the root prefix; the active operation remains recoverable.
for _, state in ipairs({
  { marker = 'MERGE_HEAD', kind = 'merge', prefix = 'm', continue = 'm' },
  { marker = 'CHERRY_PICK_HEAD', kind = 'cherry-pick', prefix = 'A', continue = 'A' },
  { marker = 'REVERT_HEAD', kind = 'revert', prefix = 'V', continue = 'V' },
}) do
  vim.fn.writefile({ first }, root .. '/.git/' .. state.marker)
  open(); expect('r', false)
  if state.kind == 'merge' then expect('A', false); expect('V', false) else expect('m', false) end
  press(state.prefix); assert(spec.kind == state.kind); expect('a', true)
  press('q'); vim.fn.delete(root .. '/.git/' .. state.marker)
end

for _, state in ipairs({
  { dir = 'rebase-merge', prefix = 'r', kind = 'rebase', continue = 'r' },
  { dir = 'rebase-apply', prefix = 'w', kind = 'am', continue = 'w' },
}) do
  local directory = root .. '/.git/' .. state.dir
  vim.fn.mkdir(directory, 'p')
  if state.kind == 'am' then vim.fn.writefile({ '' }, directory .. '/applying')
  else vim.fn.writefile({ 'pick ' .. tip .. ' tip' }, directory .. '/git-rebase-todo') end
  open(state.prefix); assert(spec.kind == state.kind)
  expect(state.continue, true); expect('s', true); expect('a', true)
  vim.fn.delete(directory, 'rf'); refresh(); expect('a', false); press('q')
end

-- A real unresolved index disables continuation, while abort/skip remain available.
local blob = git(root, 'rev-parse', 'HEAD:file.txt')
local result = vim.system({ 'git', '-C', root, 'update-index', '--index-info' },
  { text = true, stdin = '0 ' .. string.rep('0', 40) .. '\tfile.txt\n100644 ' .. blob .. ' 1\tfile.txt\n100644 ' .. blob .. ' 2\tfile.txt\n100644 ' .. blob .. ' 3\tfile.txt\n' }):wait()
assert(result.code == 0, result.stderr)
vim.fn.writefile({ first }, root .. '/.git/CHERRY_PICK_HEAD')
open('A'); expect('A', false); expect('a', true); expect('s', true); press('q')
vim.fn.delete(root .. '/.git/CHERRY_PICK_HEAD'); git(root, 'reset', '--hard', 'HEAD')

-- Local/remote/tag branches and occupation by any worktree.
git(root, 'branch', 'feature', first)
git(root, 'update-ref', 'refs/remotes/origin/topic', tip)
git(root, 'tag', 'release')
local branch = panel(root, 'gitbranch', 'origin/topic')
vim.b[branch].branch_map = { 'origin/topic' }; vim.b[branch].branch_kinds = { 'remote' }
open('b'); expect('m', false); expect('D', false); expect('X', false); press('q')
vim.b[branch].branch_map = { 'feature' }; vim.b[branch].branch_kinds = { 'local_' }
open('b'); expect('m', true); expect('D', true); expect('X', true)
git(root, 'worktree', 'add', base .. '/linked', 'feature')
refresh(); expect('D', false); expect('X', false); expect('m', true); press('q')
vim.b[branch].branch_map = { 'main' }
open('b'); expect('D', false); expect('X', false); press('q')

-- Selected Pull follows updated configuration and can recover from an initially missing upstream.
vim.b[branch].branch_map = { 'feature' }
open('F'); expect('s', false)
git(root, 'config', 'branch.feature.remote', 'origin'); git(root, 'config', 'branch.feature.merge', 'refs/heads/main')
refresh(); expect('s', true); press('s')
assert(vim.deep_equal(sent[#sent], { 'pull', 'origin', 'refs/heads/main' }))

-- Row refreshes may enrich a label, but may not redirect an existing key callback.
local log = panel(root, 'gitlog', tip .. ' subject')
local rewritten
vim.keymap.set('n', 'cw', function() rewritten = vim.api.nvim_get_current_line():match('^(%x+)') end, { buffer = log })
open(); expect('cw', true)
vim.api.nvim_buf_set_lines(log, 0, -1, false, { first .. ' replacement' })
assert(vim.wait(1000, function() return text():find('· cw ', 1, true) ~= nil end, 5),
  'Noncurrent source edits did not refresh availability')
press('cw'); assert(not rewritten); expect('cw', false); press('q')
vim.api.nvim_buf_set_lines(log, 0, -1, false, { tip .. ' original' })
open(); vim.api.nvim_buf_set_lines(log, 0, -1, false, { tip .. ' enriched statistics' })
press('cw'); assert(rewritten == tip)
open()
local source_win = vim.fn.bufwinid(log)
local replacement = vim.api.nvim_create_buf(true, false)
vim.api.nvim_win_set_buf(source_win, replacement)
rewritten = nil; press('cw'); assert(not rewritten); expect('cw', false); press('q')
vim.api.nvim_set_current_buf(log)

-- Refnames that look like hashes retain their branch context and namespace.
git(root, 'branch', 'deadbeef', first)
local hex = panel(root, 'gitbranch', 'deadbeef')
vim.b[hex].branch_map = { 'deadbeef' }; vim.b[hex].branch_kinds = { 'local_' }
open('P'); assert(text():find('Ref: deadbeef', 1, true) and not text():find('Commit:', 1, true))
vim.ui.input = function(_, cb) cb('origin') end; press('s'); vim.ui.input = original_input
assert(vim.deep_equal(sent[#sent], { 'push', 'origin', 'refs/heads/deadbeef:refs/heads/deadbeef' }))

-- Main and linked worktree actions use the Git worktree inventory.
local wt = panel(root, 'gitworktree', root)
vim.b[wt].worktree_entries = { { path = root, head = tip, branch = 'main' } }
vim.keymap.set('n', 'X', function() error('primary removal dispatched') end, { buffer = wt })
open(); expect('D', false); press('Z'); expect('m', false); expect('k', false); press('q')
vim.b[wt].worktree_entries = { { path = base .. '/linked', head = first, branch = 'feature' } }
open('Z'); expect('m', true); expect('k', true)
git(root, 'worktree', 'lock', base .. '/linked'); refresh(); expect('m', false); expect('k', false)
press('q'); git(root, 'worktree', 'unlock', base .. '/linked')

-- Missing Reflog spin mappings are disabled, never fed as raw normal keys.
local group = vim.api.nvim_create_augroup('AvailabilityFixture', { clear = true })
require('git.features.reflog').setup(group)
require('git.features.reflog').open({ work_tree = root })
open('A'); expect('s', false); expect('n', false); press('q')

-- Detached HEAD keeps explicitly addressed operations available.
git(root, 'checkout', '--detach', tip)
panel(root)
open('P'); expect('p', false); expect('u', false); expect('e', true); press('q')
open('b'); expect('s', false); expect('S', false); expect('c', true); press('q')
git(root, 'checkout', 'main')

-- Unborn HEAD still permits first commit and explicit patch application.
local unborn = repo('unborn')
panel(unborn)
open('c'); expect('a', false); expect('e', false); expect('w', false); expect('c', false)
write(unborn, 'first'); git(unborn, 'add', 'file.txt'); refresh(); expect('c', true); press('q')
open('z'); expect('z', false); expect('i', false); press('q')
open('H'); expect('u', false); expect('r', false); press('q')
open('W'); press('a'); expect('a', true); expect('c', true); press('q')
open('l'); expect('h', false); expect('o', true); press('q')
git(unborn, 'fetch', '-q', root, 'refs/heads/main:refs/remotes/source/main')
git(unborn, 'read-tree', '--empty')
panel(unborn, 'gitlog', tip .. ' imported commit')
open('A'); expect('A', true); expect('a', true); press('q')
open('V'); expect('V', true); expect('v', true); press('q')
open('v'); expect('C', true); expect('V', true); press('q')
panel(unborn); open('U'); expect('c', true); press('-a'); expect('c', false); press('q')

-- Stateful workflows include sparse-checkout, Notes, and empty stash lists.
panel(root)
open('>'); expect('a', false); expect('r', false); expect('d', false); expect('l', false)
press('-c'); press('-s'); expect('e', false); expect('s', false)
press('-s'); expect('e', true); press('q')
open('z'); expect('z', false); expect('p', false); expect('a', true); expect('v', true); expect('b', true); expect('k', false); press('q')
local note_log = panel(root, 'gitlog', tip .. ' tip')
open('T'); expect('s', false); expect('r', false); expect('T', true)
git(root, 'notes', 'add', '-m', 'note', tip); refresh(); expect('s', true); expect('r', true); press('q')
vim.fn.writefile({ 'ref: refs/notes/commits' }, root .. '/.git/NOTES_MERGE_REF')
open('T'); expect('c', true); expect('a', true)
vim.fn.delete(root .. '/.git/NOTES_MERGE_REF'); refresh(); expect('c', false); expect('a', false); press('q')

-- Mainline selection changes replay eligibility within the same panel.
git(root, 'branch', 'side', first)
git(root, 'checkout', 'side'); vim.fn.writefile({ 'side' }, root .. '/side.txt'); git(root, 'add', '.'); git(root, 'commit', '-qm', 'side')
git(root, 'checkout', 'main'); git(root, 'merge', '--no-ff', '-m', 'merge', 'side')
local merge = git(root, 'rev-parse', 'HEAD')
panel(root, 'gitlog', merge .. ' merge')
open('A'); expect('A', false); expect('a', false)
vim.ui.input = function(_, cb) cb('1') end; press('-m'); vim.ui.input = original_input
expect('A', true); expect('a', true); press('q')
open('v'); expect('a', false); expect('v', false); expect('C', false); expect('V', false); press('q')

-- Shallow-only flags can still be cleared after the repository becomes complete.
local shallow = base .. '/shallow'
result = vim.system({ 'git', 'clone', '-q', '--depth=1', 'file://' .. root, shallow }, { text = true }):wait()
assert(result.code == 0, result.stderr)
panel(shallow); open('f'); expect('-u', true); press('-u'); expect('f', true)
git(shallow, 'fetch', '--unshallow', 'origin'); refresh(); expect('f', false); expect('-u', true)
press('-u'); expect('f', true); expect('-u', false); press('q')

-- Incompatible plain-patch flags dim both checking and execution until corrected.
panel(root); open('W'); press('a'); press('-c'); press('-r'); expect('a', false); expect('c', false)
press('-r'); expect('a', true); expect('c', true); press('q')

-- Custom commands expose missing context and honor their declared mutation policy.
require('git.features.custom_commands').setup({
  { key = 's', label = 'Status read', args = { 'status' }, mutation = false },
  { key = 'c', label = 'Selected commit', args = { 'show', '{commit}' }, mutation = false },
  { key = 'm', label = 'Mutation', args = { 'add', '.' } },
})
open('!'); expect('s', true); expect('c', false); expect('m', true); press('q')

-- A live mutation owner blocks mutations, while reads and argument editing remain usable.
local async, old_busy = require('git.features.async'), require('git.features.async').busy
panel(root)
async.busy = function() return true end
open('c'); expect('a', false); expect('-a', true); press('q')
open('d'); expect('u', true); expect('s', true); press('q')
async.busy = old_busy

-- Cherry-pick's explicit no-commit suffix must not inherit the default --ff.
local pick = repo('pick')
local pick_base = commit(pick, 'before')
git(pick, 'checkout', '-qb', 'donor')
local pick_tip = commit(pick, 'after')
git(pick, 'checkout', 'main')
panel(pick, 'gitlog', pick_tip .. ' donor')
open('A'); press('a')
assert(vim.deep_equal(sent[#sent], { 'cherry-pick', '--no-commit', pick_tip }))
git(pick, unpack(sent[#sent]))
assert(git(pick, 'rev-parse', 'HEAD') == pick_base and git(pick, 'diff', '--cached') ~= '')
git(pick, 'reset', '--hard', 'HEAD')
open('A'); press('-s'); press('A')
assert(vim.deep_equal(sent[#sent], { 'cherry-pick', '--signoff', pick_tip }))
git(pick, unpack(sent[#sent]))
assert(git(pick, 'log', '-1', '--format=%B'):find('Signed-off-by:', 1, true))

-- An unlisted stash object remains a valid explicit input.
write(pick, 'unlisted WIP')
local hidden_stash = git(pick, 'stash', 'create')
git(pick, 'reset', '--hard', 'HEAD')
panel(pick); open('z'); expect('p', false); expect('a', true)
vim.ui.input = function(_, cb) cb(hidden_stash) end; press('a'); vim.ui.input = original_input
git(pick, unpack(sent[#sent])); assert(vim.fn.readfile(pick .. '/file.txt')[1] == 'unlisted WIP')

-- A normal file selection must not be passed as a submodule path.
vim.fn.writefile({ '[submodule "fixture"]', '\tpath = vendor/fixture', '\turl = https://example.invalid/fixture.git' }, root .. '/.gitmodules')
git(root, 'update-index', '--add', '--cacheinfo', '160000,' .. first .. ',vendor/fixture')
panel(root, 'gitstatus', 'M file.txt')
open('o'); expect('p', true)
vim.ui.input = function(opts, cb)
  assert(opts.prompt == 'Submodule path: '); cb('vendor/fixture')
end
press('p'); vim.ui.input = original_input
assert(vim.deep_equal(sent[#sent], { 'submodule', 'update', '--init', '--recursive', '--', 'vendor/fixture' }))
git(root, 'reset', '--hard', 'HEAD')
open('o'); expect('p', false); expect('u', false); press('q')

vim.fn.delete(base, 'rf')
print(('PASS: %d real-state menu availability checks, refreshes, prompt and target guards'):format(checks))
