-- Actual Git fixtures for less frequent workflows. No network or real repository mutation.
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local base = vim.fn.tempname(); vim.fn.mkdir(base, 'p')
vim.env.XDG_STATE_HOME = base .. '/state'
local notifications = {}
vim.notify = function(message, level) notifications[#notifications + 1] = { message = tostring(message), level = level } end
require('git.editor').environment = function() return { GIT_EDITOR = 'true', GIT_SEQUENCE_EDITOR = 'true' } end
local workflows = require('git.features.magit_workflows')
local workflow = require('git.features.workflow')
local tasks = {}
local original_run = workflow.run
workflow.run = function(...)
  local task, err = original_run(...); if task then tasks[#tasks + 1] = task end; return task, err
end
local function wait()
  assert(vim.wait(30000, function() for _, task in ipairs(tasks) do if not task.completed then return false end end; return true end, 10), 'workflow timed out')
end
local function git(root, ...)
  local args = { 'git', '-C', root }; vim.list_extend(args, { ... })
  local result = vim.system(args, { text = true }):wait()
  assert(result.code == 0, table.concat(args, ' ') .. '\n' .. (result.stderr or ''))
  return vim.trim(result.stdout)
end
local function write(root, path, text)
  vim.fn.mkdir(vim.fs.dirname(root .. '/' .. path), 'p')
  local file = assert(io.open(root .. '/' .. path, 'wb')); file:write(text); file:close()
end
local function repo(name)
  local root = base .. '/' .. name; vim.fn.mkdir(root, 'p'); git(root, 'init', '-b', 'main')
  git(root, 'config', 'user.name', 'Fixture'); git(root, 'config', 'user.email', 'fixture@example.invalid')
  git(root, 'config', 'commit.gpgsign', 'false'); return root
end
local function commit(root, message) git(root, 'add', '.'); git(root, 'commit', '-m', message); return git(root, 'rev-parse', 'HEAD') end
local answers, choices = {}, {}
vim.ui.input = function(_, callback) assert(#answers > 0, 'Unexpected input'); local answer = table.remove(answers, 1); callback(answer ~= false and answer or nil) end
vim.ui.select = function(_, _, callback) assert(#choices > 0, 'Unexpected select'); callback(table.remove(choices, 1)) end
local spec; local ui = { render = function() end }
local function show(value) spec = value; return value end
local function press(key, ...)
  vim.list_extend(answers, { ... })
  for _, group in ipairs(spec.groups) do for _, action in ipairs(group.actions) do
    if action.key == key then action.run(ui); wait(); assert(#answers == 0, 'Unused input for ' .. key); return end
  end end
  error('No action ' .. key .. ' in ' .. spec.kind)
end
local function menu(name, root, extra)
  workflows[name](vim.tbl_extend('force', { work_tree = root, panel = 'status' }, extra or {}), ui, show)
end
local count = 0
local function passed() count = count + 1 end
local sparse = repo('sparse')
write(sparse, 'one/a', '1\n'); write(sparse, 'two words/b', '2\n'); write(sparse, 'three/c', '3\n'); commit(sparse, 'directories')
menu('sparse', sparse); press('s', 'one'); assert(vim.fn.filereadable(sparse .. '/one/a') == 1 and vim.fn.filereadable(sparse .. '/three/c') == 0); passed()
menu('sparse', sparse); press('a', '"two words"'); assert(vim.fn.filereadable(sparse .. '/two words/b') == 1); passed()
menu('sparse', sparse); press('-s'); press('r'); assert(git(sparse, 'config', '--get', 'index.sparse') == 'true'); press('d'); assert(vim.fn.filereadable(sparse .. '/three/c') == 1); press('e'); assert(vim.fn.filereadable(sparse .. '/three/c') == 0); passed()
menu('sparse', sparse); press('-c'); press('-s'); local before = #tasks; press('r'); assert(#tasks == before and notifications[#notifications].message:find('cone mode')); passed()

local imported = repo('imported'); write(imported, 'lib.txt', 'version one\n'); local v1 = commit(imported, 'library one')
local parent = repo('parent'); write(parent, 'main.txt', 'app\n'); commit(parent, 'application')
menu('subtree', parent); press('i'); press('-P', 'vendor/lib'); press('-s'); press('a', imported, 'main')
assert(git(parent, 'show', 'HEAD:vendor/lib/lib.txt') == 'version one'); passed()
write(imported, 'lib.txt', 'version two\n'); commit(imported, 'library two')
menu('subtree', parent); press('i'); press('-P', 'vendor/lib'); press('-s'); press('f', imported, 'main')
assert(git(parent, 'show', 'HEAD:vendor/lib/lib.txt') == 'version two'); passed()
menu('subtree', parent); press('e'); press('-P', 'vendor/lib'); press('-b', 'library-export'); press('s', 'HEAD')
assert(git(parent, 'show', 'library-export:lib.txt') == 'version two'); passed()
local bare = base .. '/destination.git'; vim.fn.mkdir(bare, 'p'); git(bare, 'init', '--bare')
menu('subtree', parent); press('e'); press('-P', 'vendor/lib'); press('p', bare, 'main')
assert(git(bare, 'show', 'main:lib.txt') == 'version two'); passed()

menu('bundle', parent); press('c', 'full.bundle'); local bundle = parent .. '/full.bundle'; assert(vim.fn.filereadable(bundle) == 1)
menu('bundle', parent); press('v', 'full.bundle'); assert(table.concat(vim.api.nvim_buf_get_lines(0,0,-1,false), '\n'):find('okay', 1, true)); passed()
local receiver = repo('receiver'); write(receiver, 'own', 'own\n'); commit(receiver, 'own')
menu('bundle', receiver); press('u', bundle); assert(git(receiver, 'cat-file', '-t', git(parent, 'rev-parse', 'HEAD')) == 'commit')
menu('bundle', receiver); press('f', bundle, 'refs/heads/main:refs/heads/imported'); assert(git(receiver, 'rev-parse', 'imported') == git(parent, 'rev-parse', 'main')); passed()
-- Existing local commits can be imported and merged without a repository argument.
menu('subtree', parent); press('i'); press('-P', 'vendor/local'); press('c', v1)
menu('subtree', parent); press('i'); press('-P', 'vendor/local'); press('m', git(imported, 'rev-parse', 'HEAD'))
assert(git(parent, 'show', 'HEAD:vendor/local/lib.txt') == 'version two'); passed()
local oldsize = vim.uv.fs_stat(bundle).size; menu('bundle', parent); press('c', 'full.bundle'); assert(vim.uv.fs_stat(bundle).size == oldsize and notifications[#notifications].message:find('already exists')); passed()

local patches = repo('patches'); write(patches, 'file with spaces', 'base\n'); local start = commit(patches, 'base')
write(patches, 'file with spaces', 'modified\n'); write(patches, 'binary', 'a\0b'); local change = commit(patches, 'mail change')
git(patches, 'config', 'diff.noprefix', 'true'); git(patches, 'config', 'color.ui', 'always')
menu('patch', patches, { commit = change }); press('c', 'mail'); local files = vim.fn.glob(patches .. '/mail/*.patch', false, true); assert(#files == 1); local mailpatch = files[1]; passed()
menu('patch', patches, { commit = change }); press('s', 'plain.patch'); git(patches, 'config', 'color.ui', 'false'); local plain = patches .. '/plain.patch'; git(patches, 'reset', '--hard', start)
menu('apply', patches); press('c', plain); assert(git(patches, 'status', '--porcelain') == '?? mail/\n?? plain.patch'); press('a', plain)
assert(vim.fn.readfile(patches .. '/file with spaces')[1] == 'modified'); assert(vim.uv.fs_stat(patches .. '/binary').size == 3); passed()
menu('apply', patches); press('-R'); press('a', plain); assert(vim.fn.readfile(patches .. '/file with spaces')[1] == 'base'); passed()
menu('am', patches); press('w', vim.fn.shellescape(mailpatch)); assert(git(patches, 'log', '-1', '--format=%s') == 'mail change'); assert(not require('git.features.operation').inspect(patches)); passed()
git(patches, 'reset', '--hard', start)
local maildir = base .. '/Maildir'; vim.fn.mkdir(maildir .. '/cur', 'p'); vim.fn.mkdir(maildir .. '/new', 'p'); vim.fn.mkdir(maildir .. '/tmp', 'p')
local content = assert(io.open(mailpatch, 'rb')):read('*a'); write(maildir, 'new/message', content)
menu('am', patches); press('m', maildir); assert(git(patches, 'log', '-1', '--format=%s') == 'mail change'); passed()
git(patches, 'reset', '--hard', start); write(patches, 'file with spaces', 'conflict\n'); local divergent = commit(patches, 'divergent')
menu('am', patches); press('-3'); press('w', vim.fn.shellescape(mailpatch)); local operation = require('git.features.operation').inspect(patches)
assert(operation and operation.kind == 'am' and operation.total_steps == 1); menu('am', patches); press('p')
assert(table.concat(vim.api.nvim_buf_get_lines(0,0,-1,false), '\n'):find('mail change', 1, true)); passed()
write(patches, 'file with spaces', 'resolved\n'); git(patches, 'add', '--', 'file with spaces'); menu('am', patches); press('w')
assert(not require('git.features.operation').inspect(patches) and git(patches, 'log', '-1', '--format=%s') == 'mail change'); passed()
git(patches, 'reset', '--hard', divergent); menu('am', patches); press('-3'); press('w', vim.fn.shellescape(mailpatch)); menu('am', patches); choices = { 'Proceed' }; press('a'); assert(git(patches, 'rev-parse', 'HEAD') == divergent); passed()
menu('am', patches); press('-3'); press('w', vim.fn.shellescape(mailpatch)); menu('am', patches); choices = { 'Proceed' }; press('s'); assert(not require('git.features.operation').inspect(patches)); passed()

-- Source worktree and input are captured before a callback changes editor context.
local custom = require('git.features.custom_commands')
local literal = 'literal $(touch NEVER)'
custom.setup({ { key = 't', label = 'Tag', args = { 'tag', '-a', 'fixture-tag', '-m', '{message}', '{commit}' }, inputs = { { name = 'message' } }, output = false } })
custom.open({ work_tree = parent, commit = git(parent, 'rev-parse', 'HEAD'), panel = 'log' }, ui, show)
local input_original = vim.ui.input
vim.ui.input = function(_, cb) vim.cmd('lcd ' .. vim.fn.fnameescape(receiver)); cb(literal) end
press('t'); vim.ui.input = input_original
assert(git(parent, 'for-each-ref', '--format=%(contents:subject)', 'refs/tags/fixture-tag') == literal and vim.fn.filereadable(parent .. '/NEVER') == 0); passed()
assert(not pcall(custom.setup, { { key='x', label='a', args={'log'} }, { key='x', label='b', args={'log'} } })); passed()
custom.execute({ args = { 'log', '--no-walk', '--format=%H', '{commits}' }, mutation = false }, { work_tree = parent, commits = { v1, git(imported, 'rev-parse', 'HEAD') } }); wait()
local listed = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
assert(listed:find(v1, 1, true) and listed:find(git(imported, 'rev-parse', 'HEAD'), 1, true)); passed()
local n = #tasks; custom.execute({ args = { 'show', '{missing}' } }, { work_tree = parent }); wait(); assert(#tasks == n and notifications[#notifications].message:find('missing')); passed()

local tree_repo = repo('tree'); write(tree_repo, 'first/a', 'a\n'); write(tree_repo, 'first/sub/b', 'b\n'); write(tree_repo, 'other/c', 'c\n'); write(tree_repo, '[literal]', 'l\n'); write(tree_repo, 'l', 'l\n'); commit(tree_repo, 'tree base')
write(tree_repo, 'first/a', 'a changed\n'); write(tree_repo, 'first/sub/b', 'b changed\n'); write(tree_repo, 'other/c', 'c changed\n'); write(tree_repo, '[literal]', 'literal changed\n'); write(tree_repo, 'l', 'l changed\n')
local tree = require('git.features.status_tree'); local buf = tree.open({ work_tree = tree_repo })
local function find(path, section)
  for row = 1, vim.api.nvim_buf_line_count(buf) do local node = tree.entry_at(buf, row); if node and node.path == path and node.section == section then return row end end
end
assert(vim.wait(5000, function() return find('first/', 'unstaged') ~= nil end, 10)); local row = find('first/', 'unstaged')
tree.toggle(buf, row); assert(not find('first/a', 'unstaged')); tree.change_index(buf, row, 'toggle'); wait()
assert(git(tree_repo, 'diff', '--cached', '--name-only') == 'first/a\nfirst/sub/b' and git(tree_repo, 'diff', '--name-only'):find('other/c')); passed()
assert(vim.wait(5000, function() return find('first/', 'staged') ~= nil end, 10)); tree.change_index(buf, find('first/', 'staged'), 'unstage'); wait(); assert(git(tree_repo, 'diff', '--cached', '--name-only') == ''); passed()
assert(vim.wait(5000, function() return find('[literal]', 'unstaged') ~= nil end, 10)); tree.change_index(buf, find('[literal]', 'unstaged'), 'toggle'); wait(); assert(git(tree_repo, 'diff', '--cached', '--name-only') == '[literal]'); passed()
assert(vim.fn.maparg('v', 'n', false, true).callback == nil and vim.fn.maparg('<Space><Space>', 'n', false, true).callback)
local ctx = require('git.features.magit_actions').context(buf, find('other/c', 'unstaged')); assert(ctx.panel == 'tree' and ctx.path == 'other/c'); passed()
-- Editing an already-staged rename must not add its missing old index path.
git(tree_repo, 'reset', '--hard'); git(tree_repo, 'mv', 'first/a', 'other/renamed'); write(tree_repo, 'other/renamed', 'renamed edited\n')
write(tree_repo, 'line\nbreak/file', 'new path\n'); tree.refresh(buf)
assert(vim.wait(5000, function() return find('other/renamed', 'unstaged') and find('line\nbreak/', 'untracked') end, 10))
tree.change_index(buf, find('other/renamed', 'unstaged'), 'toggle'); wait()
assert(git(tree_repo, 'show', ':other/renamed') == 'renamed edited'); passed()
assert(vim.wait(5000, function() return find('other/renamed', 'staged') ~= nil end, 10))
tree.change_index(buf, find('other/renamed', 'staged'), 'unstage'); wait()
assert(git(tree_repo, 'diff', '--cached', '--name-only') == ''); passed()
tree.refresh(buf); vim.api.nvim_buf_delete(buf, { force = true }); vim.wait(100, function() return false end, 10); passed()

-- Selected log commits are exported oldest first, not every commit in-between.
local selection = repo('selection'); write(selection, 'file', 'zero\n'); commit(selection, 'zero')
write(selection, 'file', 'one\n'); local one = commit(selection, 'one'); write(selection, 'other', 'two\n'); local two = commit(selection, 'two')
write(selection, 'third', 'three\n'); local three = commit(selection, 'three')
menu('patch', selection, { commits = { three, one }, commit = three }); press('c', 'selected')
local exported = vim.fn.glob(selection .. '/selected/*.patch', false, true); assert(#exported == 2 and exported[1]:find('one') and exported[2]:find('three'), vim.inspect(exported) .. '\n' .. vim.inspect(notifications[#notifications])); passed()
-- Notes travel separately from branches; fetch never replaces the local notes ref.
local annotated = git(parent, 'rev-parse', 'HEAD')
git(parent, 'notes', 'add', '-m', 'shared annotation', annotated)
menu('notes', parent); press('P', bare, 'refs/notes/commits')
assert(git(bare, 'notes', 'show', annotated) == 'shared annotation'); passed()
menu('notes', receiver); press('f', bare, 'refs/notes/commits')
assert(git(receiver, 'notes', '--ref=refs/notes/incoming/commits', 'show', annotated) == 'shared annotation')
menu('notes', receiver); press('m', 'refs/notes/incoming/commits')
assert(git(receiver, 'notes', 'show', annotated) == 'shared annotation'); passed()
git(receiver, 'notes', 'add', '-f', '-m', 'local annotation', annotated)
git(parent, 'notes', 'add', '-f', '-m', 'remote annotation', annotated)
menu('notes', parent); press('P', bare, 'refs/notes/commits')
menu('notes', receiver); press('f', bare, 'refs/notes/commits')
menu('notes', receiver); press('m', 'refs/notes/incoming/commits')
assert(vim.fn.filereadable(receiver .. '/.git/NOTES_MERGE_REF') == 1)
menu('notes', receiver); assert(spec.kind == 'notes'); choices = { 'Proceed' }; press('a')
assert(git(receiver, 'notes', 'show', annotated) == 'local annotation'); passed()
-- Configure push tracking and inspect the actual range-diff view.
git(parent, 'push', bare, 'HEAD:refs/heads/application')
git(parent, 'remote', 'add', 'origin', bare); git(parent, 'fetch', 'origin'); git(parent, 'branch', '--set-upstream-to=origin/application')
git(parent, 'commit', '--allow-empty', '-m', 'review delta')
local review = require('git.features.range_diff').open(parent)
assert(review and vim.wait(5000, function() return review.completed end, 10))
assert(vim.api.nvim_buf_get_name(0):find('git-range-diff://', 1, true) and require('git.utils').get_buf_work_tree(0) == parent); passed()
-- Every new root prefix dispatches from the actual Space Space menu.
local actions = require('git.features.magit_actions')
local sourcebuf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(sourcebuf, 0, -1, false, { annotated .. ' selected commit' })
vim.bo[sourcebuf].filetype = 'gitlog'; require('git.utils').set_buf_work_tree(sourcebuf, parent)
vim.api.nvim_set_current_buf(sourcebuf); actions.attach(sourcebuf)
for prefix, kind in pairs({ ['>'] = 'sparse-checkout', O = 'subtree', U = 'bundle', W = 'patch', w = 'am', T = 'notes', ['!'] = 'custom-commands' }) do
  vim.api.nvim_set_current_buf(sourcebuf); vim.fn.maparg('<Space><Space>', 'n', false, true).callback()
  local mapping = vim.fn.maparg(prefix, 'n', false, true); assert(mapping.callback, 'Missing root prefix ' .. prefix); mapping.callback()
  assert(vim.b.git_action_menu_kind == kind, 'Wrong menu for ' .. prefix); vim.fn.maparg('q', 'n', false, true).callback()
end
passed()
-- Incremental bundles report missing prerequisites and work after the full bundle.
menu('bundle', parent); press('-r', 'HEAD^..HEAD'); press('c', 'incremental.bundle')
local empty = repo('missing-base'); menu('bundle', empty); press('v', parent .. '/incremental.bundle')
assert(notifications[#notifications].level == vim.log.levels.ERROR and notifications[#notifications].message:find('prerequisite')); passed()
git(receiver, 'fetch', bare, 'refs/heads/application:refs/heads/prerequisite')
menu('bundle', receiver); press('f', parent .. '/incremental.bundle', 'HEAD:refs/heads/incremental')
assert(git(receiver, 'rev-parse', 'incremental') == git(parent, 'rev-parse', 'HEAD')); passed()
-- Plain export limits a path literally despite Git pathspec metacharacters.
write(selection, '[one]', 'base\n'); write(selection, 'o', 'base\n'); commit(selection, 'path base')
write(selection, '[one]', 'literal change\n'); write(selection, 'o', 'other change\n')
menu('patch', selection, { path = '[one]', section = 'unstaged' }); press('s', 'literal.patch')
local file = assert(io.open(selection .. '/literal.patch', 'rb')); local bytes = file:read('*a'); file:close()
assert(bytes:find('literal change', 1, true) and not bytes:find('other change', 1, true)); passed()
-- Custom defaults resolve branch at the captured root, and canceled forms do not run.
custom.execute({ label = 'Current branch', args = { 'rev-parse', '--abbrev-ref', '{branch}' }, mutation = false }, { work_tree = parent }); wait()
assert(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == 'main'); passed()
local task_count = #tasks; answers = { false }
custom.execute({ args = { 'tag', '{name}' }, inputs = { { name = 'name' } } }, { work_tree = parent }); wait()
assert(#tasks == task_count); passed()
assert(#answers == 0 and #choices == 0)
vim.fn.delete(base, 'rf')
print(('PASS: %d actual Git sparse/subtree/bundle/patch/mail/custom/tree scenarios'):format(count))
