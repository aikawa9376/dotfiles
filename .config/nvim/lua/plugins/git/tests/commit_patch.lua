local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local patches = require('git.features.commit_patch')
local rewrite = require('git.features.commit_rewrite')
local model = require('git.features.commit_model')
local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
local function run(args)
  local argv = { 'git', '-C', root }; vim.list_extend(argv, args)
  return vim.system(argv, { text = false }):wait()
end
local function git(args) local r = run(args); assert(r.code == 0, r.stderr); return r.stdout or '' end
local function write(path, text)
  local f = assert(io.open(root .. '/' .. path, 'wb')); f:write(text); f:close()
end
local function commit(msg)
  git({ 'add', '.' }); git({ 'commit', '-qm', msg }); return vim.trim(git({ 'rev-parse', 'HEAD' }))
end
local function apply(target, patch, mixed)
  local hash, warning = rewrite.apply(root, target, { patch = patch, reverse = true, mixed = mixed })
  assert(hash, warning); assert(not warning, warning); return hash
end
git({ 'init', '-q', '-b', 'main' }); git({ 'config', 'user.name', 'Test' }); git({ 'config', 'user.email', 'test@example.invalid' })
git({ 'config', 'commit.gpgsign', 'false' })
write('anchor', 'anchor\n'); local seed = commit('seed')
local function fixture(path, old, new)
  git({ 'reset', '--hard', seed })
  if old then write(path, old); commit('before') end
  if new then write(path, new) else vim.fn.delete(root .. '/' .. path) end
  local target = commit('changes')
  local data = assert(model.load(root, target))
  local entry
  for _, candidate in ipairs(data.entries) do if candidate.path == path then entry = candidate end end
  local patch = assert(model.patch(data, assert(entry)))
  return target, patch
end
local function locate(patch, value)
  for row, line in ipairs(patch) do if line == value then return row end end
  error('Missing patch row ' .. value)
end
local function select(patch, first, last)
  local row = locate(patch, first)
  local hunk = row
  while hunk > 1 and not patch[hunk]:match('^@@ ') do hunk = hunk - 1 end
  return assert(patches.selection(patch, hunk, row, last and locate(patch, last) or row))
end
-- Preserve quoted Git paths and EOF markers, including multiple adjacent deletions.
local path = '日本語 space\t"quote.txt'
local target, patch = fixture(path, 'one\ntwo\nthree', 'one\nnew\nanother')
apply(target, select(patch, '-two', '-three'))
assert(git({ 'show', 'HEAD:' .. path }) == 'one\ntwo\nthree\nnew\nanother')
assert(vim.trim(git({ 'status', '--porcelain' })) == '')
target, patch = fixture(path, 'one\ntwo', 'one\nnew')
apply(target, select(patch, '-two', '+new'))
assert(git({ 'show', 'HEAD:' .. path }) == 'one\ntwo')
-- Removing just the replacement leaves an existing empty file, not a deletion.
target, patch = fixture(path, 'old', 'new')
apply(target, select(patch, '+new'))
assert(git({ 'show', 'HEAD:' .. path }) == '')
-- A selected added EOF line is removed without dropping the preceding newline.
target, patch = fixture(path, 'one\n', 'one\nnew')
apply(target, select(patch, '+new'))
assert(git({ 'show', 'HEAD:' .. path }) == 'one\n')
-- Partial creation/deletion has consistent /dev/null and mode metadata.
target, patch = fixture(path, nil, 'one\ntwo\nthree\n')
apply(target, select(patch, '+one', '+two'))
assert(git({ 'show', 'HEAD:' .. path }) == 'three\n')
target, patch = fixture(path, nil, 'one\ntwo\n')
apply(target, select(patch, '+one', '+two'))
assert(run({ 'show', 'HEAD:' .. path }).code ~= 0)
target, patch = fixture(path, 'one\ntwo\nthree\n', nil)
apply(target, select(patch, '-one', '-two'))
assert(git({ 'show', 'HEAD:' .. path }) == 'one\ntwo\n')
-- Selection in a later hunk leaves the earlier hunk intact.
local before, after = {}, {}
for i = 1, 25 do before[i], after[i] = 'line ' .. i, 'line ' .. i end
after[2], after[23] = 'changed early', 'changed late'
target, patch = fixture('multi', table.concat(before, '\n') .. '\n', table.concat(after, '\n') .. '\n')
local hunk = locate(patch, '+changed late')
while not patch[hunk]:match('^@@ ') do hunk = hunk - 1 end
apply(target, assert(patches.hunk(patch, hunk)))
after[23] = before[23]
assert(git({ 'show', 'HEAD:multi' }) == table.concat(after, '\n') .. '\n')
-- A line selection on a rename keeps the current filename.
git({ 'reset', '--hard', seed })
write('old name', 'one\ntwo\nthree\nfour\nfive\n'); commit('before rename')
git({ 'mv', 'old name', path }); write(path, 'one\nnew\nthree\nfour\nfive\n'); target = commit('rename')
local data = assert(model.load(root, target)); assert(data.entries[1].status == 'R')
patch = assert(model.patch(data, data.entries[1]))
apply(target, select(patch, '-two', '+new'))
assert(git({ 'show', 'HEAD:' .. path }) == 'one\ntwo\nthree\nfour\nfive\n')
assert(run({ 'show', 'HEAD:old name' }).code ~= 0)
-- Historical Mixed removal follows the target and restores only selected edits.
target, patch = fixture('mixed', 'one\ntwo\n', 'one\nnew\nextra\n')
write('later', 'later\n'); commit('descendant')
local rewritten = apply(target, select(patch, '+extra'), true)
assert(vim.trim(git({ 'rev-parse', 'HEAD^' })) == rewritten)
assert(git({ 'show', 'HEAD:mixed' }) == 'one\nnew\n')
assert(table.concat(vim.fn.readfile(root .. '/mixed'), '\n') == 'one\nnew\nextra')
assert(git({ 'diff', '--cached' }) == '')
assert(git({ 'diff' }):find('+extra', 1, true))
-- Descendant replay failure rolls back the target and restores user changes.
git({ 'reset', '--hard', seed })
write('dependent', 'one\n'); commit('before')
write('dependent', 'two\n'); target = commit('target')
data = assert(model.load(root, target)); patch = assert(model.patch(data, data.entries[1]))
write('dependent', 'three\n'); local tip = commit('descendant')
write('anchor', 'staged\n'); git({ 'add', 'anchor' }); write('anchor', 'staged\nunstaged\n')
local staged, unstaged = git({ 'diff', '--cached' }), git({ 'diff' })
local failed, failure = rewrite.apply(root, target, { patch = patch, reverse = true })
assert(not failed and failure)
assert(vim.trim(git({ 'rev-parse', 'HEAD' })) == tip)
assert(git({ 'diff', '--cached' }) == staged and git({ 'diff' }) == unstaged)
assert(vim.fn.isdirectory(root .. '/.git/rebase-merge') == 0)
-- If restoring the user's stash conflicts, Mixed still retains its recovery patch.
target, patch = fixture('recovery', 'one\ntwo\n', 'one\nnew\nextra\n')
patch = select(patch, '+extra')
write('recovery', 'one\nnew\nuser extra\n')
local changed, warning = rewrite.apply(root, target, { patch = patch, reverse = true, mixed = true })
assert(changed and warning and warning:find('Saved changes remain in stash', 1, true))
local recovery = assert(warning:match('Recovery patch: ([^\n]+)'))
assert(vim.deep_equal(vim.fn.readfile(recovery), patch))
assert(run({ 'rev-parse', 'refs/stash' }).code == 0)
vim.fn.delete(recovery)
vim.fn.delete(root, 'rf')
print('PASS: commit patch selection, special paths, EOF, creation/deletion, adjacent changes, later hunks, rename, historical Mixed')
