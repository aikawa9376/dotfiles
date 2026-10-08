-- Run from plugin root: nvim --headless --clean -u NONE -l tests/status_conflict_regions.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path

local root = vim.fn.tempname() .. ' conflict-regions'
vim.fn.mkdir(root, 'p')
local function git(args, allow_failure)
  local argv = { 'git', '-C', root }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  if not allow_failure then assert(result.code == 0, result.stderr) end
  return result
end
local function write(path, lines) vim.fn.writefile(lines, root .. '/' .. path) end
local function version(changes)
  local lines = {}
  for number = 1, 42 do lines[number] = changes[number] or ('line ' .. number) end
  return lines
end

git({ 'init', '-qb', 'main' })
git({ 'config', 'user.name', 'Test' })
git({ 'config', 'user.email', 'test@example.invalid' })
git({ 'config', 'merge.conflictStyle', 'diff3' })
write('changed.txt', version({}))
write('kept.txt', version({}))
write('manual.txt', version({}))
git({ 'add', '.' })
git({ 'commit', '-qm', 'base' })
git({ 'switch', '-qc', 'other' })
write('changed.txt', version({ [12] = 'theirs conflict 1', [26] = 'theirs conflict 2',
  [40] = 'theirs clean' }))
write('kept.txt', version({ [12] = 'theirs conflict 1', [26] = 'theirs conflict 2',
  [40] = 'theirs clean' }))
write('manual.txt', version({ [5] = 'shared clean', [12] = 'theirs conflict',
  [40] = 'theirs clean' }))
write('added.txt', { 'shared', 'theirs add', 'shared tail' })
git({ 'add', '.' })
git({ 'commit', '-qm', 'theirs' })
git({ 'switch', '-q', 'main' })
write('changed.txt', version({ [2] = 'ours clean', [12] = 'ours conflict 1',
  [26] = 'ours conflict 2' }))
write('kept.txt', version({ [2] = 'ours clean', [12] = 'ours conflict 1',
  [26] = 'ours conflict 2' }))
write('manual.txt', version({ [2] = 'ours clean', [5] = 'shared clean',
  [12] = 'ours conflict' }))
write('added.txt', { 'shared', 'ours add', 'shared tail' })
git({ 'add', '.' })
git({ 'commit', '-qm', 'ours' })
assert(git({ 'merge', 'other' }, true).code ~= 0)
local worktree = table.concat(vim.fn.readfile(root .. '/changed.txt'), '\n')
assert(select(2, worktree:gsub('<<<<<<<', '')) == 2, 'fixture lacks two conflict regions')
assert(worktree:find('|||||||', 1, true), 'fixture lacks diff3 base sections')

local renderer = require('git.features.status_renderer')
local bufnr = vim.api.nvim_create_buf(false, true)
local function snapshot()
  local lines = assert(renderer.snapshot(bufnr, root))
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return table.concat(lines, '\n')
end
local function row_for(pattern, after)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if row > (after or 0) and line:match(pattern) then return row end
  end
  error('missing ' .. pattern)
end
snapshot()
assert(renderer.update_diff(bufnr, row_for('^UU changed%.txt$'), 'show'))
local displayed = snapshot()
assert(displayed:find('-ours conflict 1', 1, true)
  and displayed:find('+theirs conflict 1', 1, true)
  and displayed:find('-ours conflict 2', 1, true)
  and displayed:find('+theirs conflict 2', 1, true),
  'UU omitted a conflicting side')
assert(not displayed:find('[-+]ours clean') and not displayed:find('[-+]theirs clean'),
  'UU included changes outside conflict markers')
assert(not displayed:find('<<<<<<<', 1, true) and not displayed:find('|||||||', 1, true),
  'UU showed conflict marker text')
assert(select(2, displayed:gsub('conflict %d+', '')) >= 2, 'multiple conflict blocks collapsed')
local original_markers = vim.fn.readfile(root .. '/changed.txt')
write('changed.txt', { '<<<<<<< HEAD', 'first ours', 'shared 1', 'shared 2',
  'shared 3', 'last ours', '=======', 'first theirs', 'shared 1', 'shared 2',
  'shared 3', 'last theirs', '>>>>>>> other' })
displayed = snapshot()
assert(select(2, displayed:gsub('conflict 1', '')) == 1
  and displayed:find('-first ours', 1, true)
  and displayed:find('+last theirs', 1, true),
  'one marker block was split into multiple displayed hunks')
assert(renderer.conflict_worktree_line(bufnr, row_for('-first ours')) == 2
  and renderer.conflict_worktree_line(bufnr, row_for('+first theirs')) == 8
  and renderer.conflict_worktree_line(bufnr, row_for('^ shared 3$')) == 5
  and renderer.conflict_worktree_line(bufnr, row_for('+last theirs')) == 12,
  'conflict diff rows did not map to the corresponding worktree marker lines')
write('changed.txt', original_markers)
displayed = snapshot()

assert(renderer.update_diff(bufnr, row_for('^AA added%.txt$'), 'show'))
displayed = snapshot()
assert(displayed:find('-ours add', 1, true) and displayed:find('+theirs add', 1, true),
  'AA did not show its conflicting lines')

local edited = vim.fn.readfile(root .. '/changed.txt')
for index, line in ipairs(edited) do
  if line == 'ours conflict 1' then edited[index] = 'ours revised 1' end
end
write('changed.txt', edited)
local stale, stale_err = renderer.change_index(bufnr, row_for('^UU changed%.txt$'), 'toggle')
assert(not stale and stale_err:find('displayed conflict has changed', 1, true),
  's accepted conflict markers changed after the displayed preview')
displayed = snapshot()
assert(displayed:find('-ours revised 1', 1, true)
  and not displayed:find('-ours conflict 1', 1, true),
  'expanded conflict preview kept a stale worktree block')

write('changed.txt', { 'manually resolved' })
displayed = snapshot()
assert(displayed:find('+manually resolved', 1, true)
  and displayed:find('stage 1 (base) -> worktree (manually resolved)', 1, true)
  and not displayed:find('-ours conflict 1', 1, true),
  'manual resolution did not show its worktree diff from base')
local ok, err
write('manual.txt', version({ [2] = 'ours clean', [5] = 'shared clean',
  [12] = 'manual merge',
  [40] = 'theirs clean' }))
snapshot()
assert(renderer.update_diff(bufnr, row_for('^UU manual%.txt$'), 'show'))
displayed = snapshot()
assert(displayed:find('+manual merge', 1, true)
  and displayed:find('+ours clean', 1, true)
  and displayed:find('+shared clean', 1, true)
  and displayed:find('+theirs clean', 1, true),
  'manual preview omitted the resolved or clean merged changes')
require('git.features.syntax_highlight').attach(bufnr)
local highlight_ns = assert(vim.api.nvim_get_namespaces().git_extension_syntax)
local function conflict_yellow(pattern)
  local row = row_for(pattern)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, highlight_ns,
    { row - 1, 0 }, { row - 1, -1 }, { details = true })
  for _, mark in ipairs(marks) do
    if mark[4].hl_group == 'GitStatusConflictLine' then return true end
  end
  return false
end
assert(conflict_yellow('^%+manual merge$') and conflict_yellow('^%-line 12$'),
  'manual conflict lines lacked the yellow background')
assert(not conflict_yellow('^%+ours clean$')
  and not conflict_yellow('^%+shared clean$')
  and not conflict_yellow('^%+theirs clean$'),
  'clean merged edits received the conflict background')
write('manual.txt', version({ [2] = 'ours clean', [5] = 'shared clean',
  [12] = 'manual revision',
  [40] = 'theirs clean' }))
ok, err = renderer.change_index(bufnr, row_for('^UU manual%.txt$'), 'toggle')
assert(not ok and err:find('displayed conflict has changed', 1, true),
  's staged a manual resolution changed after the displayed preview')
displayed = snapshot()
assert(displayed:find('+manual revision', 1, true),
  'manual preview kept stale worktree content')
require('git.features.syntax_highlight').refresh(bufnr)
assert(conflict_yellow('^%+manual revision$')
  and not conflict_yellow('^%+shared clean$'),
  'conflict background did not follow a refreshed manual preview')
ok, err = renderer.change_index(bufnr, row_for('^UU manual%.txt$'), 'toggle')
assert(ok, err)
local manual = git({ 'show', ':manual.txt' }).stdout
assert(manual:find('ours clean', 1, true)
  and manual:find('theirs clean', 1, true)
  and manual:find('manual revision', 1, true)
  and not manual:find('<<<<<<<', 1, true)
  and git({ 'ls-files', '-u', '--', 'manual.txt' }).stdout == '',
  's did not stage the manually resolved worktree')
write('changed.txt', { '<<<<<<< HEAD', 'incomplete block' })
displayed = snapshot()
assert(displayed:find('Incomplete conflict markers', 1, true),
  'incomplete conflict markers showed unrelated stage changes')
ok, err = renderer.discard(bufnr, row_for('^UU changed%.txt$'))
assert(not ok and err:find('Incomplete conflict markers', 1, true),
  'X overwrote incomplete conflict markers')

write('changed.txt', edited)
snapshot()
assert(renderer.update_diff(bufnr, row_for('^UU changed%.txt$'), 'show'))
snapshot()
ok, err = renderer.change_index(bufnr,
  row_for('conflict 1$', row_for('^UU changed%.txt$')), 'toggle')
assert(ok, err)
assert(select(2, table.concat(vim.fn.readfile(root .. '/changed.txt'), '\n'):gsub('<<<<<<<', '')) == 1
  and git({ 'ls-files', '-u', '--', 'changed.txt' }).stdout ~= '',
  's on a conflict hunk accepted every marker')
snapshot()
ok, err = renderer.change_index(bufnr, row_for('^UU changed%.txt$'), 'toggle')
assert(ok, err)
local resolved = git({ 'show', ':changed.txt' }).stdout
assert(resolved:find('ours clean', 1, true)
  and resolved:find('theirs clean', 1, true)
  and resolved:find('theirs conflict 1', 1, true)
  and resolved:find('theirs conflict 2', 1, true),
  's discarded clean merged edits or failed to select incoming conflict blocks')
assert(not resolved:find('ours revised 1', 1, true)
  and not resolved:find('<<<<<<<', 1, true), 's left conflict markers behind')
snapshot()
assert(renderer.update_diff(bufnr, row_for('^UU kept%.txt$'), 'show'))
snapshot()
ok, err = renderer.resolve_conflict(bufnr, row_for('conflict 1$', row_for('^UU kept%.txt$')), 'theirs')
assert(ok, err)
local partly_resolved = table.concat(vim.fn.readfile(root .. '/kept.txt'), '\n')
assert(partly_resolved:find('theirs conflict 1', 1, true)
  and partly_resolved:find('ours conflict 2', 1, true)
  and select(2, partly_resolved:gsub('<<<<<<<', '')) == 1
  and git({ 'ls-files', '-u', '--', 'kept.txt' }).stdout ~= '',
  'ct on a hunk changed another marker or staged an incomplete file: ' .. partly_resolved)
snapshot()
ok, err = renderer.discard(bufnr, row_for('conflict 1$', row_for('^UU kept%.txt$')))
assert(ok, err)
assert(git({ 'ls-files', '-u', '--', 'kept.txt' }).stdout == '',
  'X on the remaining hunk did not stage the completed result')
local retained = git({ 'show', ':kept.txt' }).stdout
assert(retained:find('theirs conflict 1', 1, true)
  and retained:find('ours conflict 2', 1, true)
  and not retained:find('<<<<<<<', 1, true),
  'X on a hunk changed an already chosen conflict')
snapshot()
ok, err = renderer.discard(bufnr, row_for('^AA added%.txt$'))
assert(ok, err)
local kept = git({ 'show', ':added.txt' }).stdout
assert(kept:find('ours add', 1, true) and not kept:find('theirs add', 1, true)
  and not kept:find('<<<<<<<', 1, true), 'X failed to keep the displayed side')

vim.api.nvim_buf_delete(bufnr, { force = true })
vim.fn.delete(root, 'rf')
print('PASS: UU and AA display and resolve only live conflict-marker regions')
