-- Run: nvim --headless --clean -u NONE -l tests/history_undo.lua
-- Upstream behavior: lazygit/pkg/integration/tests/undo/{undo_commit,undo_checkout_and_drop}.go.
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local async = require('git.features.async')
local undo = require('git.features.history_undo')
local edits = require('git.features.history_edits')
local roots, cases, failures = {}, {}, {}
local function git(root, args, opts)
  local argv = { 'git', '-C', root }; vim.list_extend(argv, args)
  local result = vim.system(argv, vim.tbl_extend('force', { text = true }, opts or {})):wait()
  assert(result.code == 0, table.concat(args, ' ') .. ': ' .. (result.stderr or ''))
  return vim.trim(result.stdout or '')
end
local function task(root, fn)
  local done, success, values
  local job, err = async.run(root, fn, function(ok, ...) success, values, done = ok, { ... }, true end)
  assert(job, err)
  assert(vim.wait(30000, function() return done end, 5), 'Undo workflow timed out')
  assert(success, values[1])
  return unpack(values)
end
local function action(root, redo)
  return task(root, function()
    local plan = undo.plan(root, redo)
    local target, warning = undo.execute(plan)
    assert(target, warning); assert(not warning, warning)
    return plan
  end)
end
local function write(root, path, lines) vim.fn.writefile(lines, root .. '/' .. path) end
local function commit(root, subject, path, content)
  if path then write(root, path, content); git(root, { 'add', '--', path }) end
  git(root, { 'commit', '--allow-empty', '-qm', subject })
  return git(root, { 'rev-parse', 'HEAD' })
end
local function repo()
  local root = vim.fn.tempname() .. ' undo repo'; roots[#roots + 1] = root; vim.fn.mkdir(root, 'p')
  git(root, { 'init', '-qb', 'main' })
  for key, value in pairs({ ['user.name'] = 'Test', ['user.email'] = 'test@example.invalid',
    ['commit.gpgsign'] = 'false', ['core.autocrlf'] = 'false', ['core.hooksPath'] = root .. '/no-hooks' }) do
    git(root, { 'config', key, value })
  end
  return root, commit(root, 'base', 'work', { 'base' })
end
local function head(root, hash, branch)
  assert(git(root, { 'rev-parse', 'HEAD' }) == hash, 'unexpected HEAD')
  if branch then assert(git(root, { 'branch', '--show-current' }) == branch, 'unexpected branch') end
end
local function clean(root)
  assert(git(root, { 'status', '--porcelain' }) == '', 'expected clean index/worktree')
end
local function test(name, fn) cases[#cases + 1] = { name, fn } end
local function restart(root, redo, expected)
  local script = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
  local result = vim.system({ vim.v.progpath, '--headless', '--clean', '-u', 'NONE', '-l', script }, {
    text = true, env = { NVIM_GIT_UNDO_TEST_ROOT = root, NVIM_GIT_UNDO_TEST_REDO = redo and '1' or '0',
      NVIM_GIT_UNDO_TEST_EXPECTED = expected },
  }):wait()
  assert(result.code == 0, (result.stdout or '') .. (result.stderr or ''))
  head(root, expected)
end
if vim.env.NVIM_GIT_UNDO_TEST_ROOT then
  local root = vim.env.NVIM_GIT_UNDO_TEST_ROOT
  action(root, vim.env.NVIM_GIT_UNDO_TEST_REDO == '1')
  head(root, vim.env.NVIM_GIT_UNDO_TEST_EXPECTED)
  return
end

test('upstream checkout/drop sequence: three Undo, three Redo, process restart', function()
  local root = repo()
  commit(root, 'two'); local three = commit(root, 'three'); local four = commit(root, 'four')
  git(root, { 'branch', 'other' })
  assert(edits.drop(root, { four }))
  git(root, { 'checkout', '-q', 'other' })
  assert(edits.drop(root, { four }))
  action(root); head(root, four, 'other'); clean(root)
  action(root); head(root, three, 'main'); clean(root)
  action(root); head(root, four, 'main'); clean(root)
  restart(root, true, three); head(root, three, 'main'); clean(root)
  action(root, true); head(root, four, 'other'); clean(root)
  action(root, true); head(root, three, 'other'); clean(root)
end)

test('upstream commit Undo/Redo preserves dirty file, including discarded undo contribution', function()
  local root, base = repo()
  local tip = commit(root, 'new file', 'added', { 'committed' })
  write(root, 'work', { 'dirty' })
  action(root); head(root, base)
  assert(git(root, { 'show', ':added' }) == 'committed')
  action(root, true); head(root, tip)
  assert(vim.fn.readfile(root .. '/work')[1] == 'dirty')
  assert(git(root, { 'diff', '--cached' }) == '')
  action(root)
  git(root, { 'restore', '--staged', '--', 'added' }); vim.fn.delete(root .. '/added')
  action(root, true); head(root, tip)
  assert(vim.fn.readfile(root .. '/added')[1] == 'committed')
  assert(vim.fn.readfile(root .. '/work')[1] == 'dirty')
  assert(git(root, { 'diff', '--cached' }) == '')
end)

test('multiple soft Undo/Redo of content commits retains later undone changes staged', function()
  local root, base = repo()
  local first = commit(root, 'first', 'work', { 'first' })
  local second = commit(root, 'second', 'work', { 'second' })
  local third = commit(root, 'third', 'work', { 'third' })
  write(root, 'work', { 'third', 'unstaged' }); write(root, 'new file', { 'untracked' })
  action(root); head(root, second)
  action(root); head(root, first)
  action(root); head(root, base)
  for _, target in ipairs({ first, second, third }) do
    action(root, true); head(root, target)
    assert(git(root, { 'show', ':work' }) == 'third', 'lost remaining staged undo contribution')
    assert(vim.deep_equal(vim.fn.readfile(root .. '/work'), { 'third', 'unstaged' }))
    assert(vim.fn.readfile(root .. '/new file')[1] == 'untracked')
    assert(git(root, { 'stash', 'list' }) == '')
  end
  assert(git(root, { 'diff', '--cached' }) == '')
end)

test('content-bearing suffix drop Undo restores a clean tree across branches', function()
  local root = repo()
  local parent = commit(root, 'parent', 'parent', { 'parent' })
  local tip = commit(root, 'drop me', 'added', { 'added' })
  git(root, { 'branch', 'other' })
  assert(edits.drop(root, { tip }))
  git(root, { 'checkout', '-q', 'other' }); assert(edits.drop(root, { tip }))
  action(root); head(root, tip, 'other'); clean(root)
  action(root); head(root, parent, 'main'); clean(root)
  action(root); head(root, tip, 'main'); clean(root)
  for _, step in ipairs({ { parent, 'main' }, { tip, 'other' }, { parent, 'other' } }) do
    action(root, true); head(root, step[1], step[2]); clean(root)
  end
end)

test('Redo preserves independently staged, unstaged, untracked changes and existing stash', function()
  local root = repo()
  write(root, 'work', { 'older stash' }); git(root, { 'stash', 'push', '-qm', 'existing' })
  local existing = git(root, { 'rev-parse', 'refs/stash' })
  local tip = commit(root, 'change', 'added', { 'committed' })
  action(root)
  write(root, 'work', { 'staged' }); git(root, { 'add', 'work' })
  write(root, 'work', { 'staged', 'unstaged' }); write(root, 'untracked', { 'keep' })
  local staged, unstaged = git(root, { 'diff', '--cached', '--', 'work' }), git(root, { 'diff' })
  action(root, true); head(root, tip)
  assert(git(root, { 'diff', '--cached' }) == staged)
  assert(git(root, { 'diff' }) == unstaged)
  assert(vim.fn.readfile(root .. '/untracked')[1] == 'keep')
  assert(git(root, { 'rev-parse', 'refs/stash' }) == existing)
end)

test('partial Redo retains future undone changes plus independently staged changes', function()
  local root = repo()
  local first = commit(root, 'first', 'work', { 'first' })
  local second = commit(root, 'second', 'work', { 'second' })
  action(root); action(root)
  write(root, 'independent', { 'staged independently' }); git(root, { 'add', 'independent' })
  write(root, 'work', { 'second', 'unstaged' })
  action(root, true); head(root, first)
  assert(git(root, { 'show', ':work' }) == 'second')
  assert(git(root, { 'show', ':independent' }) == 'staged independently')
  action(root, true); head(root, second)
  assert(git(root, { 'diff', '--cached', '--name-only' }) == 'independent')
  assert(vim.deep_equal(vim.fn.readfile(root .. '/work'), { 'second', 'unstaged' }))
  assert(git(root, { 'stash', 'list' }) == '')
end)

test('staged conflict during Redo refuses before changing history or user state', function()
  local root, base = repo()
  commit(root, 'original change', 'work', { 'original change' }); action(root)
  write(root, 'work', { 'independent replacement' }); git(root, { 'add', 'work' })
  write(root, 'work', { 'independent replacement', 'unstaged' })
  local before = { git(root, { 'reflog', 'show' }), git(root, { 'diff', '--cached' }), git(root, { 'diff' }) }
  local ok, err = pcall(function() action(root, true) end)
  assert(not ok and tostring(err):find('Redo conflicts', 1, true), tostring(err))
  head(root, base)
  assert(vim.deep_equal(before, { git(root, { 'reflog', 'show' }), git(root, { 'diff', '--cached' }), git(root, { 'diff' }) }))
  assert(git(root, { 'stash', 'list' }) == '')
end)

test('future undone net-zero tree and independently staged changes survive partial Redo', function()
  local root = repo()
  local changed = commit(root, 'change', 'work', { 'changed' })
  local reverted = commit(root, 'restore base', 'work', { 'base' })
  action(root); action(root)
  write(root, 'independent', { 'keep staged' }); git(root, { 'add', 'independent' })
  action(root, true); head(root, changed)
  assert(git(root, { 'show', ':work' }) == 'base')
  action(root, true); head(root, reverted)
  assert(git(root, { 'diff', '--cached', '--name-only' }) == 'independent')
  assert(git(root, { 'show', ':independent' }) == 'keep staged')
end)

test('index changes between Redo preflight and stash abort without losing the new edits', function()
  local root, base = repo()
  commit(root, 'change', 'added', { 'added' }); action(root)
  local system, injected = vim.system, false
  vim.system = function(argv, ...)
    if argv[1] == 'git' and vim.tbl_contains(argv, 'stash') and vim.tbl_contains(argv, 'push') and not injected then
      injected = true
      write(root, 'independent', { 'new staged change' }); git(root, { 'add', 'independent' })
      write(root, 'independent', { 'new staged change', 'new unstaged change' })
      write(root, 'untracked', { 'new untracked change' })
    end
    return system(argv, ...)
  end
  local ok, err = pcall(function() action(root, true) end)
  vim.system = system
  assert(injected and not ok and tostring(err):find('Index changed', 1, true), tostring(err))
  head(root, base)
  assert(git(root, { 'show', ':independent' }) == 'new staged change')
  assert(vim.deep_equal(vim.fn.readfile(root .. '/independent'), { 'new staged change', 'new unstaged change' }))
  assert(vim.fn.readfile(root .. '/untracked')[1] == 'new untracked change')
  assert(git(root, { 'show', ':added' }) == 'added')
  assert(git(root, { 'stash', 'list' }) == '')
end)

test('both drop engines record a logical hard-undo operation', function()
  for _, engine in ipairs({ 'log', 'commit' }) do
    local root, base = repo()
    local tip = commit(root, 'tip content', 'added', { 'added' })
    if engine == 'log' then assert(edits.drop(root, { tip }))
    else assert(require('git.features.commit_rewrite').apply(root, tip, { drop = true })) end
    assert(git(root, { 'reflog', 'show', '-1', '--format=%gs' }):match('^%[nvim git drop%]'))
    local plan = action(root)
    assert(plan.kind == 'drop' and plan.mode == 'hard')
    head(root, tip); clean(root)
    action(root, true); head(root, base); clean(root)
  end
end)

test('failed WIP restoration retains staged/unstaged/untracked contents in a recovery stash', function()
  local root, base = repo()
  write(root, 'work', { 'older stash' }); git(root, { 'stash', 'push', '-qm', 'existing' })
  local existing = git(root, { 'rev-parse', 'refs/stash' })
  local tip = commit(root, 'tip content', 'work', { 'tip' })
  assert(edits.drop(root, { tip })); action(root); head(root, tip)
  write(root, 'work', { 'staged edit' }); git(root, { 'add', 'work' })
  write(root, 'work', { 'staged edit', 'unstaged edit' }); write(root, 'untracked', { 'keep' })
  local target, warning = task(root, function() return undo.execute(undo.plan(root, true)) end)
  assert(target == base and warning and warning:find('Saved changes remain in stash', 1, true))
  local recovery = assert(warning:match('stash (%x+)'))
  assert(git(root, { 'show', recovery .. '^2:work' }) == 'staged edit')
  assert(git(root, { 'show', recovery .. ':work' }) == 'staged edit\nunstaged edit')
  assert(git(root, { 'show', recovery .. '^3:untracked' }) == 'keep')
  assert(git(root, { 'rev-parse', 'stash@{1}' }) == existing)
end)

test('new commit after Undo invalidates old Redo, new commit remains undoable', function()
  local root, base = repo()
  local old = commit(root, 'old', 'work', { 'old' })
  action(root)
  local newer = commit(root, 'new action', 'work', { 'new' })
  local before = git(root, { 'reflog', 'show', '--format=%H%x00%gs' })
  local ok, err = pcall(function() task(root, function() return undo.plan(root, true) end) end)
  assert(not ok and tostring(err):find('Nothing to redo', 1, true))
  head(root, newer)
  assert(git(root, { 'reflog', 'show', '--format=%H%x00%gs' }) == before)
  local plan = action(root); assert(plan.to == newer and plan.from == base and plan.to ~= old)
end)

test('same-HEAD resets are skipped and marked state survives actual process restart', function()
  local root, base = repo()
  local tip = commit(root, 'change', 'work', { 'changed' })
  git(root, { 'reset', '--hard', 'HEAD' })
  action(root); head(root, base)
  restart(root, true, tip); clean(root)
  restart(root, false, base)
end)

test('external rebase is one Undo/Redo action and preserves staged/unstaged/untracked state', function()
  local root, base = repo()
  commit(root, 'first', 'first', { 'first' })
  local original = commit(root, 'second', 'second', { 'second' })
  git(root, { 'rebase', '-i', base }, { env = { GIT_SEQUENCE_EDITOR = "sed -i '1s/^pick/edit/'", GIT_EDITOR = 'true' } })
  git(root, { 'commit', '--amend', '-qm', 'rewritten first' })
  git(root, { 'rebase', '--continue' }, { env = { GIT_EDITOR = 'true' } })
  local rewritten = git(root, { 'rev-parse', 'HEAD' }); assert(rewritten ~= original)
  write(root, 'work', { 'staged' }); git(root, { 'add', 'work' })
  write(root, 'work', { 'staged', 'unstaged' }); write(root, 'untracked', { 'keep' })
  local staged, unstaged = git(root, { 'diff', '--cached' }), git(root, { 'diff' })
  local plan = action(root); assert(plan.kind == 'rebase' and plan.mode == 'hard')
  head(root, original, 'main')
  restart(root, true, rewritten)
  assert(git(root, { 'diff', '--cached' }) == staged and git(root, { 'diff' }) == unstaged)
  assert(vim.fn.readfile(root .. '/untracked')[1] == 'keep')
  assert(git(root, { 'stash', 'list' }) == '')
end)

test('active rebase refuses both directions, aborted rebase does not consume an Undo step', function()
  local root, base = repo()
  local first = commit(root, 'first')
  local tip = commit(root, 'second')
  git(root, { 'rebase', '-i', base }, { env = { GIT_SEQUENCE_EDITOR = "sed -i '1s/^pick/edit/'", GIT_EDITOR = 'true' } })
  local before = git(root, { 'reflog', 'show' })
  for _, redo in ipairs({ false, true }) do
    local ok, err = pcall(function() task(root, function() return undo.plan(root, redo) end) end)
    assert(not ok and tostring(err):find('Finish the current Git operation', 1, true), tostring(err))
    assert(git(root, { 'reflog', 'show' }) == before)
  end
  git(root, { 'commit', '--amend', '--allow-empty', '-qm', 'temporary edit' }); git(root, { 'rebase', '--abort' })
  head(root, tip)
  local plan = action(root)
  assert(plan.kind == 'commit' and plan.from == first and plan.to == tip)
end)

test('detached checkout Undo/Redo preserves branch identity', function()
  local root, base = repo()
  local tip = commit(root, 'change')
  git(root, { 'checkout', '-q', '--detach', base })
  action(root); head(root, tip, 'main')
  action(root, true); head(root, base, '')
end)

test('failed checkout Undo retains user changes and existing branch', function()
  local root = repo()
  git(root, { 'checkout', '-qb', 'temporary' }); commit(root, 'temporary branch')
  git(root, { 'checkout', '-q', 'main' }); git(root, { 'branch', '-D', 'temporary' })
  local original = git(root, { 'rev-parse', 'HEAD' })
  write(root, 'work', { 'staged' }); git(root, { 'add', 'work' })
  write(root, 'work', { 'staged', 'unstaged' }); write(root, 'untracked', { 'keep' })
  local staged, unstaged = git(root, { 'diff', '--cached' }), git(root, { 'diff' })
  local ok = pcall(function() action(root) end)
  assert(not ok, 'checkout to a deleted branch unexpectedly succeeded')
  head(root, original, 'main')
  assert(git(root, { 'diff', '--cached' }) == staged and git(root, { 'diff' }) == unstaged)
  assert(vim.fn.readfile(root .. '/untracked')[1] == 'keep')
  assert(git(root, { 'stash', 'list' }) == '')
end)

test('HEAD, branch and reflog changes invalidate a captured plan', function()
  for _, change in ipairs({ 'head', 'branch', 'reflog' }) do
    local root = repo(); commit(root, 'change')
    local plan = task(root, function() return undo.plan(root, false) end)
    if change == 'head' then commit(root, 'external commit')
    elseif change == 'branch' then git(root, { 'checkout', '-qb', 'other' })
    else git(root, { 'reset', '--hard', 'HEAD' }) end
    local original, reflog = git(root, { 'rev-parse', 'HEAD' }), git(root, { 'reflog', 'show' })
    local target, err = task(root, function() return undo.execute(plan) end)
    assert(not target and err:find('changed', 1, true), tostring(err))
    head(root, original)
    assert(git(root, { 'reflog', 'show' }) == reflog)
  end
end)

test('missing reflog boundaries and unknown actions refuse a recovery guess', function()
  local a, b = string.rep('a', 40), string.rep('b', 40)
  for _, fixture in ipairs({
    { a .. '\0rebase (finish): returning to refs/heads/main\n' .. b .. '\0commit: previous', 'boundary' },
    { a .. '\0rebase (start): checkout main', 'incomplete' },
    { a .. '\0commit: missing predecessor', 'unavailable' },
    { a .. '\0unknown external operation\n' .. b .. '\0commit: previous', 'Unsupported' },
    { a .. '\0[lazygit undo]: reset\n' .. b .. '\0commit: previous', 'Unsupported' },
  }) do
    for _, redo in ipairs({ false, true }) do
      local result, err = undo.parse(fixture[1], redo)
      assert(not result and err:find(fixture[2], 1, true), tostring(err))
    end
  end
end)

test('worktree reflog isolation', function()
  local root, base = repo()
  local tip = commit(root, 'main change', 'added', { 'added' })
  local linked = vim.fn.tempname() .. ' linked'; roots[#roots + 1] = linked
  git(root, { 'worktree', 'add', '-qb', 'linked', linked, base })
  local linked_tip = commit(linked, 'linked change', 'work', { 'linked' })
  local before = git(linked, { 'reflog', 'show', '--format=%H%x00%gs' })
  action(root); head(root, base, 'main'); head(linked, linked_tip, 'linked')
  assert(git(linked, { 'reflog', 'show', '--format=%H%x00%gs' }) == before)
  action(linked); head(linked, base, 'linked')
  restart(root, true, tip); restart(linked, true, linked_tip)
end)

test('GitUndo/GitRedo confirmation: cancel, changed staging and stale plan', function()
  require('git').setup()
  local root, base = repo()
  local tip = commit(root, 'change', 'added', { 'added' })
  require('git.utils').set_buf_work_tree(0, root)
  local select, notify = vim.ui.select, vim.notify
  local choices, confirm, messages
  vim.ui.select = function(items, _, cb) choices, confirm = items, cb end
  vim.notify = function(message) messages = tostring(message) end
  local function open(command)
    choices, confirm, messages = nil, nil, nil
    vim.cmd(command)
    assert(vim.wait(5000, function() return confirm ~= nil end, 5), messages or 'confirmation did not open')
  end
  open('GitUndo')
  local before = git(root, { 'reflog', 'show' })
  confirm('Cancel'); head(root, tip)
  assert(git(root, { 'reflog', 'show' }) == before)
  open('GitUndo'); confirm(choices[1])
  assert(vim.wait(5000, function() return messages ~= nil end, 5)); head(root, base)
  open('GitRedo')
  write(root, 'work', { 'staged during confirmation' }); git(root, { 'add', 'work' })
  confirm(choices[1])
  assert(vim.wait(5000, function() return messages ~= nil end, 5)); head(root, tip)
  assert(git(root, { 'show', ':work' }) == 'staged during confirmation')
  open('GitUndo'); commit(root, 'external empty commit')
  local original = git(root, { 'rev-parse', 'HEAD' }); confirm(choices[1])
  assert(vim.wait(5000, function() return messages ~= nil end, 5))
  assert(messages:find('changed', 1, true), messages); head(root, original)
  vim.ui.select, vim.notify = select, notify
end)

for _, case in ipairs(cases) do
  local ok, err = pcall(case[2])
  if ok then print('PASS: ' .. case[1])
  else failures[#failures + 1] = case[1] .. ': ' .. tostring(err); print('FAIL: ' .. failures[#failures]) end
end
for _, root in ipairs(roots) do vim.fn.delete(root, 'rf') end
assert(#failures == 0, table.concat(failures, '\n'))
print(('PASS: %d Undo/Redo integration scenarios'):format(#cases))
