local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local statistics = require('git.features.status_statistics')
local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
local other = vim.fn.tempname(); vim.fn.mkdir(other, 'p')
local function git(args)
  local argv = { 'git', '-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid' }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end
git({ 'init', '-q' })
vim.fn.writefile({ 'original' }, root .. '/tracked.txt')
git({ 'add', '.' }); git({ 'commit', '-qm', 'initial' })
vim.fn.writefile({ 'aa', 'bb' }, root .. '/new.txt')
assert(vim.uv.fs_utime(root .. '/new.txt', 1000000000, 1000000000))
local open, system, reads, diffs = io.open, vim.system, 0, 0
io.open = function(path, ...)
  if path == root .. '/new.txt' or path == other .. '/new.txt' then reads = reads + 1 end
  return open(path, ...)
end
vim.system = function(args, ...)
  if vim.tbl_contains(args, '--numstat') then diffs = diffs + 1 end
  return system(args, ...)
end
local function model(repository)
  return { work_tree = repository or root, staged = {}, unstaged = {}, untracked = { { path = 'new.txt' } } }
end
local value = model()
statistics.enrich(1, value)
assert(value.untracked[1].additions == 2 and reads == 1 and diffs == 0)
statistics.enrich(1, model())
assert(reads == 1, 'unchanged untracked file was reread')
-- Same size and mtime, but a different inode/content: size+mtime is insufficient.
local old_stat = assert(vim.uv.fs_stat(root .. '/new.txt'))
vim.fn.writefile({ 'a', 'b', 'c' }, root .. '/replacement.txt')
assert(vim.uv.fs_utime(root .. '/replacement.txt', old_stat.atime.sec, old_stat.mtime.sec))
assert(vim.uv.fs_rename(root .. '/replacement.txt', root .. '/new.txt'))
value = model(); statistics.enrich(1, value)
assert(value.untracked[1].additions == 3 and reads == 2, 'replacement reused stale counts')
-- Removal from the untracked set releases ownership even without a file edit.
statistics.enrich(1, { work_tree = root, staged = {}, unstaged = {}, untracked = {} })
statistics.enrich(1, model()); assert(reads == 3, 'retired path retained its cache')
statistics.cleanup(1); statistics.enrich(1, model()); assert(reads == 4, 'cleanup retained cached files')
vim.fn.writefile({ 'other' }, other .. '/new.txt')
value = model(other); statistics.enrich(1, value)
assert(value.untracked[1].additions == 1 and reads == 5, 'cache escaped its repository')
-- Failed reads are retried even if file metadata has not changed.
statistics.cleanup(1)
io.open = function() return nil end
value = model(); statistics.enrich(1, value); assert(value.untracked[1].additions == nil)
io.open = open
value = model(); statistics.enrich(1, value); assert(value.untracked[1].additions == 3)
-- A read racing a writer must not retain the observed count under the old stamp.
statistics.cleanup(1)
io.open = function(path, ...)
  local file = assert(open(path, ...))
  vim.fn.writefile({ 'newer', 'content' }, path)
  return file
end
statistics.enrich(1, model())
local raced_reads = 0
io.open = function(...) raced_reads = raced_reads + 1; return open(...) end
value = model(); statistics.enrich(1, value)
assert(raced_reads == 1 and value.untracked[1].additions == 2, 'racing read was cached')
io.open = open
-- Only the nonempty tracked section needs a diff subprocess.
vim.fn.writefile({ 'original', 'added' }, root .. '/tracked.txt')
value = model(); value.unstaged = { { path = 'tracked.txt' } }
statistics.enrich(1, value)
assert(diffs == 1 and value.unstaged[1].additions == 1)
git({ 'add', 'tracked.txt' })
value = model(); value.staged = { { path = 'tracked.txt' } }
statistics.enrich(1, value)
assert(diffs == 2 and value.staged[1].additions == 1)
vim.system = system; statistics.cleanup(1)
vim.fn.delete(root, 'rf'); vim.fn.delete(other, 'rf')
print('PASS: untracked cache reuse, replacement/race/read failure invalidation, repository/cleanup ownership and empty-section query suppression')
