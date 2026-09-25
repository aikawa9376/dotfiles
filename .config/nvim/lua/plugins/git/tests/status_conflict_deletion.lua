-- Run from plugin root: nvim --headless --clean -u NONE -l tests/status_conflict_deletion.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path

local root = vim.fn.tempname() .. ' conflicts'
vim.fn.mkdir(root, 'p')
local files = { 'a.txt', 'b.txt', 'c.txt', 'd.txt', 'e.txt', 'f.txt', 'g.txt', 'h.txt', 'j.txt' }
local function git(args, allow_failure)
  local argv = { 'git', '-C', root }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  if not allow_failure then assert(result.code == 0, result.stderr) end
  return vim.trim(result.stdout or ''), result
end
local function write(name, content)
  vim.fn.writefile({ content }, root .. '/' .. name)
end

git({ 'init', '-qb', 'main' })
git({ 'config', 'user.name', 'Test' })
git({ 'config', 'user.email', 'test@example.invalid' })
for _, name in ipairs(files) do write(name, 'base') end
git({ 'add', '.' })
git({ 'commit', '-qm', 'base' })
git({ 'switch', '-qc', 'other' })
for _, name in ipairs({ 'a.txt', 'c.txt', 'e.txt', 'g.txt', 'h.txt' }) do write(name, 'theirs') end
write('i.txt', 'theirs new')
write('j.txt', 'theirs changed')
git({ 'rm', '-q', '--', 'b.txt', 'd.txt', 'f.txt' })
git({ 'add', '.' })
git({ 'commit', '-qm', 'other' })
git({ 'switch', '-q', 'main' })
git({ 'rm', '-q', '--', 'a.txt', 'c.txt', 'e.txt', 'g.txt', 'h.txt' })
for _, name in ipairs({ 'b.txt', 'd.txt', 'f.txt' }) do write(name, 'ours') end
write('i.txt', 'ours new')
write('j.txt', 'ours changed')
git({ 'add', '.' })
git({ 'commit', '-qm', 'ours' })
local _, merge = git({ 'merge', 'other' }, true)
assert(merge.code ~= 0, 'expected delete/modify conflicts')
local before = git({ 'status', '--short' })
assert(before:find('DU a.txt', 1, true) and before:find('UD b.txt', 1, true)
  and before:find('AA i.txt', 1, true) and before:find('UU j.txt', 1, true))

local renderer = require('git.features.status_renderer')
local operation = require('git.features.operation')
local inspect = operation.inspect
local inspections = 0
operation.inspect = function(...)
  inspections = inspections + 1
  return inspect(...)
end
local bufnr = vim.api.nvim_create_buf(false, true)
local function row_for(name)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, assert(renderer.snapshot(bufnr, root)))
  for row, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if line:find(name, 1, true) then return row end
  end
  error('missing conflicted row ' .. name)
end
local function choose(name, side)
  local ok, err = renderer.resolve_conflict(bufnr, row_for(name), side)
  assert(ok, err)
end

local original_system = vim.system
local blob_reads = 0
vim.system = function(argv, opts, callback)
  if argv[1] == 'git' and argv[2] == 'cat-file' then blob_reads = blob_reads + 1 end
  return original_system(argv, opts, callback)
end
local first_row = row_for('a.txt')
assert(inspections == 1, 'initial snapshot did not inspect operation')
assert(not (vim.api.nvim_buf_get_lines(bufnr, first_row, first_row + 1, false)[1] or ''):match('^@@'),
  'conflict file diff should start closed')
assert(renderer.update_diff(bufnr, first_row, 'show'))
first_row = row_for('a.txt')
assert((vim.api.nvim_buf_get_lines(bufnr, first_row, first_row + 1, false)[1] or ''):match('^@@'),
  'explicitly opened conflict diff did not persist through refresh')
local first_blob_reads = blob_reads
assert(first_blob_reads > 0, 'expanded conflict did not read its blob')
row_for('b.txt')
assert(inspections == 1, 'unchanged operation was inspected again')
assert(blob_reads == first_blob_reads, 'unchanged conflict blobs were read again')
vim.system = original_system
assert(renderer.update_diff(bufnr, first_row, 'hide'))
first_row = row_for('a.txt')
assert(not (vim.api.nvim_buf_get_lines(bufnr, first_row, first_row + 1, false)[1] or ''):match('^@@'),
  'explicitly collapsed conflict diff reopened on refresh')
assert(renderer.update_diff(bufnr, first_row, 'show'))
local fast_lines
renderer.snapshot_async(bufnr, root, {}, function(lines) fast_lines = lines end)
assert(vim.wait(2000, function() return fast_lines ~= nil end), 'fast snapshot did not finish')
assert(table.concat(fast_lines, '\n'):find('Merge Current:', 1, true),
  'fast stage refresh hid the cached operation header')
assert(inspections == 1, 'fast stage refresh re-inspected operation')

choose('a.txt', 'ours')
choose('b.txt', 'theirs')
assert(vim.fn.filereadable(root .. '/a.txt') == 0 and vim.fn.filereadable(root .. '/b.txt') == 0,
  'choosing a deleted side left the worktree file')
assert(git({ 'ls-files', '-u', '--', 'a.txt', 'b.txt' }) == '',
  'choosing deletion did not resolve the index conflict')

write('c.txt', 'manual result')
local ok, err = renderer.mark_resolved(bufnr, row_for('c.txt'))
assert(ok, err)
assert(git({ 'show', ':c.txt' }) == 'manual result',
  'cr did not stage the current worktree content')

local function expand(name)
  local row = row_for(name)
  assert(renderer.update_diff(bufnr, row, 'show'))
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return row + 1, table.concat(lines, '\n')
end
choose('i.txt', 'ours')
local _, adopted = expand('i.txt')
assert(adopted:find('+ours new', 1, true)
  and not adopted:find('-theirs new', 1, true)
  and adopted:find('stage 1 (base) -> worktree (chosen ours)', 1, true),
  'AA co did not show the adopted addition from base')
write('i.txt', 'edited after choosing ours')
adopted = select(2, expand('i.txt'))
assert(adopted:find('+edited after choosing ours', 1, true),
  'chosen preview did not follow worktree edits')
ok, err = renderer.change_index(bufnr, row_for('i.txt'), 'toggle')
assert(ok, err)
assert(git({ 'show', ':i.txt' }) == 'edited after choosing ours',
  's after co did not stage the displayed worktree content')

choose('j.txt', 'theirs')
adopted = select(2, expand('j.txt'))
assert(adopted:find('-base', 1, true) and adopted:find('+theirs changed', 1, true)
  and adopted:find('stage 1 (base) -> worktree (chosen theirs)', 1, true),
  'UU ct did not show the adopted change from base')
ok, err = renderer.mark_resolved(bufnr, row_for('j.txt'))
assert(ok, err)

local hunk, displayed = expand('e.txt')
assert(displayed:find('+theirs', 1, true) and not displayed:find('-theirs', 1, true),
  'DU did not show incoming content as additions')
local partial, partial_err = renderer.change_index_range(bufnr, hunk + 1, hunk + 1, 'toggle')
assert(not partial and partial_err:find('whole side', 1, true),
  'Visual s silently accepted an entire conflict from one selected line')
partial, partial_err = renderer.discard_range(bufnr, hunk + 1, hunk + 1)
assert(not partial and partial_err:find('file rows', 1, true),
  'Visual X silently discarded an entire conflict from one selected line')
write('e.txt', 'manual edit to replace')
ok, err = renderer.change_index(bufnr, hunk, 'toggle')
assert(ok, err)
assert(git({ 'show', ':e.txt' }) == 'theirs', 's did not accept the displayed incoming side')
assert(git({ 'ls-files', '-u', '--', 'e.txt' }) == '')

hunk, displayed = expand('f.txt')
assert(displayed:find('-ours', 1, true) and not displayed:find('+ours', 1, true),
  'UD did not show current content as removals')
ok, err = renderer.change_index(bufnr, hunk, 'toggle')
assert(ok, err)
assert(vim.fn.filereadable(root .. '/f.txt') == 0, 's did not select incoming deletion')

hunk = expand('d.txt')
ok, err = renderer.discard(bufnr, hunk)
assert(ok, err)
assert(git({ 'show', ':d.txt' }) == 'ours', 'X did not keep current content')
ok, err = renderer.discard(bufnr, row_for('g.txt'))
assert(ok, err)
assert(vim.fn.filereadable(root .. '/g.txt') == 0, 'X did not keep current deletion')
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, assert(renderer.snapshot(bufnr, root)))
local header
for row, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
  if line:match('^Unmerged paths') then header = row; break end
end
assert(header, 'remaining conflict section is missing')
ok, err = renderer.change_index(bufnr, header, 'toggle')
assert(ok, err)
assert(git({ 'show', ':h.txt' }) == 'theirs', 'section s did not accept incoming side')
assert(git({ 'ls-files', '-u' }) == '', 'some conflicts remain unresolved')
assert(inspections == 1, 'file resolution re-inspected unchanged merge operation')
local after = git({ 'status', '--short' })
assert(after:find('D  b.txt', 1, true) and after:find('A  c.txt', 1, true)
  and after:find('A  e.txt', 1, true) and after:find('D  f.txt', 1, true)
  and after:find('A  h.txt', 1, true), after)
git({ 'commit', '-qm', 'merge resolved' })
assert(renderer.snapshot(bufnr, root))
assert(inspections == 2, 'completed merge did not invalidate operation summary')

operation.inspect = inspect
vim.api.nvim_buf_delete(bufnr, { force = true })
vim.fn.delete(root, 'rf')
print('PASS: conflict diff directions, chosen-side previews, operation cache, and resolution actions')
