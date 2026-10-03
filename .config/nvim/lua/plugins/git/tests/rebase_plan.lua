-- Run: nvim --headless --clean -u NONE -l tests/rebase_plan.lua
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local engine = require('git.features.rebase_plan_model')
local ui = require('git.features.rebase_plan')
local async = require('git.features.async')
local roots, cases, failures = {}, {}, {}
local function git(root, args, opts)
  local argv = { 'git', '-C', root }; vim.list_extend(argv, args)
  local result = vim.system(argv, vim.tbl_extend('force', { text = true }, opts or {})):wait()
  assert(result.code == 0, table.concat(args, ' ') .. ': ' .. (result.stderr or ''))
  return vim.trim(result.stdout or '')
end
local function write(root, path, content) vim.fn.writefile(content, root .. '/' .. path) end
local function commit(root, title, path, content)
  if path then write(root, path, content or { title }); git(root, { 'add', '--', path }) end
  git(root, { 'commit', '--allow-empty', '-qm', title })
  return git(root, { 'rev-parse', 'HEAD' })
end
local function repo()
  local root = vim.fn.tempname() .. ' rebase plan'; roots[#roots + 1] = root; vim.fn.mkdir(root, 'p')
  git(root, { 'init', '-qb', 'main' })
  for key, value in pairs({ ['user.name'] = 'Test', ['user.email'] = 'test@example.invalid',
    ['commit.gpgsign'] = 'false', ['core.hooksPath'] = root .. '/no-hooks', ['core.autocrlf'] = 'false' }) do
    git(root, { 'config', key, value })
  end
  return root, commit(root, 'base', 'base')
end
local function task(root, fn)
  local done, success, values
  local job, err = async.run(root, fn, function(ok, ...)
    success, values, done = ok, { n = select('#', ...), ... }, true
  end)
  assert(job, err); assert(vim.wait(30000, function() return done end, 5), 'workflow timed out')
  assert(success, values[1]); return unpack(values, 1, values.n)
end
local function parse(m, text, messages)
  local rows, err = engine.parse(m, text, messages); assert(rows, err); return rows
end
local function row(action, hash, subject) return action .. ' ' .. hash:sub(1, 12) .. ' ' .. subject end
local function apply(m, text, messages)
  local rows = parse(m, text, messages)
  local hash, err = task(m.root, function() return engine.execute(m, rows) end)
  assert(hash, err); assert(not err, err); return hash
end
local function test(name, fn) cases[#cases + 1] = { name, fn } end

test('reorder plus inline subject and full body edits, preserving author and WIP', function()
  local root, base = repo()
  local first = commit(root, 'first\n\noriginal body', 'first')
  local second = commit(root, 'second', 'second')
  local third = commit(root, 'third', 'third')
  local old_tree = git(root, { 'rev-parse', 'HEAD^{tree}' })
  write(root, 'base', { 'staged' }); git(root, { 'add', 'base' }); write(root, 'base', { 'staged', 'unstaged' })
  write(root, 'new file', { 'untracked' })
  local staged, unstaged = git(root, { 'diff', '--cached' }), git(root, { 'diff' })
  local m = task(root, function() return engine.load(root, { base = base }) end)
  local title = '日本語 `literal` $(literal) "message"'
  apply(m, { row('pick', second, 'second'), row('pick', first, title), row('pick', third, 'third') },
    { [first] = 'first\n\nnew body\n\nmore body' })
  assert(git(root, { 'log', '--reverse', '--format=%s', base .. '..HEAD' }) == 'second\n' .. title .. '\nthird')
  assert(git(root, { 'show', '-s', '--format=%B', 'HEAD^' }) == title .. '\n\nnew body\n\nmore body')
  assert(git(root, { 'show', '-s', '--format=%an <%ae>', 'HEAD^' }) == 'Test <test@example.invalid>')
  assert(git(root, { 'rev-parse', 'HEAD^{tree}' }) == old_tree)
  assert(git(root, { 'diff', '--cached' }) == staged and git(root, { 'diff' }) == unstaged)
  assert(vim.fn.readfile(root .. '/new file')[1] == 'untracked' and git(root, { 'stash', 'list' }) == '')
  local rewritten = git(root, { 'rev-parse', 'HEAD' })
  task(root, function()
    local undo = require('git.features.history_undo')
    local hash, warning = undo.execute(undo.plan(root, false)); assert(hash == third and not warning, warning)
    hash, warning = undo.execute(undo.plan(root, true)); assert(hash == rewritten and not warning, warning)
  end)
  assert(git(root, { 'diff', '--cached' }) == staged and git(root, { 'diff' }) == unstaged)
end)

test('partial --onto rebase excludes old base and leaves other branches unchanged', function()
  local root, base = repo()
  local old = commit(root, 'old stack base', 'old-only')
  local child = commit(root, 'child', 'child')
  local tip = commit(root, 'tip', 'tip'); git(root, { 'branch', 'old-stack' })
  git(root, { 'checkout', '-qb', 'new-stack', base })
  local onto = commit(root, 'new stack base', 'new-only')
  git(root, { 'checkout', '-q', 'main' })
  local m = task(root, function() return engine.load(root, { base = old, onto = 'new-stack' }) end)
  apply(m, { row('pick', child, 'child'), row('pick', tip, 'tip') })
  assert(git(root, { 'rev-parse', 'HEAD~2' }) == onto)
  assert(git(root, { 'rev-parse', 'old-stack' }) == tip and git(root, { 'rev-parse', 'new-stack' }) == onto)
  assert(vim.fn.filereadable(root .. '/old-only') == 0 and vim.fn.filereadable(root .. '/new-only') == 1)
  assert(git(root, { 'branch', '--show-current' }) == 'main')
end)

test('root reword and clean/no-op plans never consume unrelated staging', function()
  local root, base = repo()
  local tip = commit(root, 'tip', 'tip')
  local m = task(root, function() return engine.load(root, { base = '--root' }) end)
  apply(m, { row('pick', base, 'new root'), row('pick', tip, 'tip') })
  assert(git(root, { 'log', '--reverse', '--format=%s' }) == 'new root\ntip')
  m = task(root, function() return engine.load(root, { base = 'HEAD^' }) end)
  write(root, 'base', { 'staged' }); git(root, { 'add', 'base' })
  local before = git(root, { 'reflog', 'show' })
  local hash, warning, changed = task(root, function()
    return engine.execute(m, parse(m, { row('pick', m.entries[1].hash, 'tip') }))
  end)
  assert(hash == m.head and not warning and changed == false)
  assert(git(root, { 'reflog', 'show' }) == before and git(root, { 'show', ':base' }) == 'staged')
end)

test('squash, fixup and deleted rows become an explicit drop', function()
  local root, base = repo()
  local a = commit(root, 'one', 'one'); local b = commit(root, 'two', 'two')
  local c = commit(root, 'three', 'three'); commit(root, 'deleted', 'deleted')
  local m = task(root, function() return engine.load(root, { base = base }) end)
  apply(m, { row('pick', a, 'one'), row('squash', b, 'two'), row('fixup', c, 'three') })
  assert(git(root, { 'rev-list', '--count', base .. '..HEAD' }) == '1')
  assert(git(root, { 'show', '-s', '--format=%B' }) == 'one\n\ntwo')
  assert(vim.fn.filereadable(root .. '/deleted') == 0 and vim.fn.filereadable(root .. '/three') == 1)
end)

test('replay conflict rolls back HEAD, branch, staged/unstaged/untracked edits', function()
  local root, base = repo()
  local a = commit(root, 'first', 'base', { 'first' }); local b = commit(root, 'second', 'base', { 'second' })
  write(root, 'wip', { 'staged' }); git(root, { 'add', 'wip' }); write(root, 'wip', { 'staged', 'unstaged' })
  write(root, 'untracked', { 'keep' })
  local staged, unstaged = git(root, { 'diff', '--cached' }), git(root, { 'diff' })
  local m = task(root, function() return engine.load(root, { base = base }) end)
  local hash, err = task(root, function()
    return engine.execute(m, parse(m, { row('pick', b, 'second'), row('pick', a, 'first') }))
  end)
  assert(not hash and err:find('could not apply', 1, true), tostring(err))
  assert(git(root, { 'rev-parse', 'HEAD' }) == b and git(root, { 'branch', '--show-current' }) == 'main')
  assert(git(root, { 'diff', '--cached' }) == staged and git(root, { 'diff' }) == unstaged)
  assert(vim.fn.readfile(root .. '/untracked')[1] == 'keep' and git(root, { 'stash', 'list' }) == '')
  assert(vim.fn.isdirectory(root .. '/.git/rebase-merge') == 0)
end)

test('invalid todos, changed HEAD/branch and non-linear ranges refuse before mutation', function()
  local root, base = repo(); local a = commit(root, 'one'); local b = commit(root, 'two')
  local m = task(root, function() return engine.load(root, { base = base }) end)
  for _, text in ipairs({ { row('pick', a, 'one'), row('pick', a, 'again') },
    { row('exec', a, 'rm -rf') }, { row('fixup', a, 'one') }, { 'pick deadbeef outside' }, {} }) do
    assert(not engine.parse(m, text))
  end
  local rows = parse(m, { row('pick', b, 'two'), row('pick', a, 'one') })
  git(root, { 'checkout', '-qb', 'other' })
  local hash, err = task(root, function() return engine.execute(m, rows) end)
  assert(not hash and err:find('branch changed', 1, true))
  git(root, { 'checkout', '-q', 'main' }); commit(root, 'new action')
  hash, err = task(root, function() return engine.execute(m, rows) end)
  assert(not hash and err:find('HEAD or branch changed', 1, true))
  git(root, { 'checkout', '-qb', 'side', base }); local side = commit(root, 'side', 'side')
  git(root, { 'checkout', '-q', 'main' })
  local accepted, selection_err = pcall(function() task(root, function() return engine.load(root, { commit = side }) end) end)
  assert(not accepted and tostring(selection_err):find('ancestor of HEAD', 1, true))
  git(root, { 'merge', '--no-ff', '-qm', 'merge side', 'side' })
  local ok, failure = pcall(function() task(root, function() return engine.load(root, { base = base }) end) end)
  assert(not ok and tostring(failure):find('linear range', 1, true))
end)

local function open(root, base)
  local buf
  ui.open({ work_tree = root, base = base, on_open = function(value) buf = value end })
  assert(vim.wait(10000, function() return buf ~= nil end, 5), 'plan did not open')
  return buf
end
local function press(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), 'xt', false)
end
test('native dd/p/u and i, deferred full-message float, cancellation and real :write', function()
  dofile(vim.fs.dirname(vim.fs.dirname(plugin)) .. '/config/keymap.lua'); vim.o.timeoutlen = 50
  local root, base = repo(); local a = commit(root, 'one\n\nbody', 'one'); local b = commit(root, 'two', 'two')
  local before = git(root, { 'rev-parse', 'HEAD' })
  local buf = open(root, base)
  press('ddp')
  local text = vim.api.nvim_buf_get_lines(buf, 6, -1, false)
  assert(text[1]:find(b:sub(1, 12), 1, true) and text[2]:find(a:sub(1, 12), 1, true))
  press('u'); press('u')
  assert(vim.api.nvim_buf_get_lines(buf, 6, 7, false)[1]:find(a:sub(1, 12), 1, true))
  vim.api.nvim_win_set_cursor(0, { 7, #row('pick', a, '') })
  press('iNEW <Esc>')
  assert(vim.api.nvim_buf_get_lines(buf, 6, 7, false)[1]:match('NEW one$'))
  press('gk')
  local draft = vim.api.nvim_get_current_buf(); assert(draft ~= buf and vim.bo[draft].buftype == 'acwrite')
  vim.api.nvim_buf_set_lines(draft, 0, -1, false, { 'NEW one', '', 'edited body', '', 'paragraph two' }); vim.cmd('write')
  assert(not vim.api.nvim_buf_is_valid(draft) and git(root, { 'rev-parse', 'HEAD' }) == before)
  vim.api.nvim_set_current_buf(buf)
  local select, confirmed, choices = vim.ui.select
  vim.ui.select = function(items, _, cb) choices, confirmed = items, cb end
  vim.cmd('write'); assert(confirmed); confirmed('Cancel')
  assert(git(root, { 'rev-parse', 'HEAD' }) == before and vim.api.nvim_buf_is_valid(buf))
  vim.cmd('write'); confirmed(choices[1])
  assert(vim.wait(30000, function() return not vim.api.nvim_buf_is_valid(buf) end, 5))
  vim.ui.select = select
  assert(git(root, { 'show', '-s', '--format=%B', 'HEAD^' }) == 'NEW one\n\nedited body\n\nparagraph two')
end)

test('message/body and base changes participate in native undo', function()
  local root, base = repo(); local a = commit(root, 'one\n\nold body'); commit(root, 'two')
  local buf = open(root, base)
  press('gk'); local draft = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(draft, 0, -1, false, { 'one', '', 'new body' }); vim.cmd('write')
  vim.api.nvim_set_current_buf(buf); press('u'); press('gk')
  draft = vim.api.nvim_get_current_buf()
  assert(table.concat(vim.api.nvim_buf_get_lines(draft, 0, -1, false), '\n') == 'one\n\nold body',
    vim.inspect({ cursor = vim.api.nvim_win_get_cursor(0), text = vim.api.nvim_buf_get_lines(draft, 0, -1, false) }))
  press('q'); vim.api.nvim_set_current_buf(buf)
  press('<C-r>'); press('gk')
  draft = vim.api.nvim_get_current_buf()
  assert(table.concat(vim.api.nvim_buf_get_lines(draft, 0, -1, false), '\n') == 'one\n\nnew body')
  press('q'); vim.api.nvim_set_current_buf(buf); press('u')
  vim.api.nvim_win_set_cursor(0, { 7, 0 }); press('mb')
  assert(vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]:find(a, 1, true))
  press('u')
  assert(vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]:find(base, 1, true))
  press('<C-r>')
  assert(vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]:find(a, 1, true))
  press('u')
  press('gk'); press('q'); vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test('marked old base, new-base prompt and stale confirmation preserve the draft', function()
  local root, base = repo(); local a = commit(root, 'one'); local tip = commit(root, 'two')
  local marked = ui.mark(root, a)
  assert(vim.wait(5000, function() return marked.completed end, 5))
  local buf = open(root)
  assert(vim.api.nvim_buf_line_count(buf) == 7 and vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]:find(a, 1, true))
  local input = vim.ui.input; vim.ui.input = function(_, cb) cb(base) end
  press('mo'); vim.ui.input = input
  assert(vim.wait(5000, function() return vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1]:find(base, 1, true) ~= nil end, 5))
  local select, confirm = vim.ui.select
  vim.ui.select = function(_, _, cb) confirm = cb end
  vim.cmd('write')
  vim.api.nvim_buf_set_lines(buf, 6, 7, false, { row('reword', tip, 'edited while confirming') })
  confirm('Execute rebase plan')
  assert(git(root, { 'rev-parse', 'HEAD' }) == tip and vim.bo[buf].modifiable)
  vim.ui.select = select; vim.api.nvim_buf_delete(buf, { force = true })
end)

test('live todo helpers preserve native editing and mark reword without applying history', function()
  local root = repo(); local hash = commit(root, 'one\n\nbody')
  local buf = vim.api.nvim_create_buf(false, true); vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = 'gitrebase'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { row('pick', hash, 'one') })
  require('git.features.rebase_todo').attach(buf, { root = root })
  press('cr'); assert(vim.api.nvim_get_current_line():match('^reword '))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'sq ' .. hash .. ' one' })
  vim.api.nvim_win_set_cursor(0, { 1, 2 })
  press('i<C-x><C-u><C-y><Esc>')
  assert(vim.api.nvim_get_current_line():match('^squash '), 'actual insert completion failed')
  press('cr')
  assert(require('git.features.rebase_todo').complete(0, 's')[1] == 'squash')
  press('gk')
  assert(vim.wait(5000, function() return vim.api.nvim_get_current_buf() ~= buf end, 5))
  assert(not vim.bo.modifiable and table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n') == 'one\n\nbody')
  press('q'); vim.api.nvim_set_current_buf(buf); vim.api.nvim_buf_delete(buf, { force = true })
end)

test('marking HEAD before new work and visible marks on source commit lists', function()
  local root, base = repo()
  local buf = vim.api.nvim_create_buf(false, true); vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = 'fugitivelog'; require('git.utils').set_buf_work_tree(buf, root)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { base:sub(1, 12) .. ' base' })
  local marked = ui.mark(root, base)
  assert(vim.wait(5000, function() return marked.completed end, 5))
  local ns = vim.api.nvim_get_namespaces().git_rebase_base
  assert(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) == 1)
  commit(root, 'new child')
  local plan = open(root)
  assert(vim.api.nvim_buf_line_count(plan) == 7 and vim.api.nvim_buf_get_lines(plan, 1, 2, false)[1]:find(base, 1, true))
  vim.api.nvim_buf_delete(plan, { force = true })
  ui.clear_mark(root); assert(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) == 0)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test('unsaved message floats and edited headers cannot silently execute or lose drafts', function()
  local root, base = repo(); local tip = commit(root, 'child')
  local buf = open(root, base); press('gk'); local draft = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(draft, 0, -1, false, { 'unsaved message' })
  vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
  local select, prompts = vim.ui.select, 0
  vim.ui.select = function() prompts = prompts + 1 end
  ui.execute(buf); assert(prompts == 0 and git(root, { 'rev-parse', 'HEAD' }) == tip)
  local confirm = vim.fn.confirm; vim.fn.confirm = function() return 2 end
  press('q'); assert(vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_valid(draft))
  vim.fn.confirm = confirm
  vim.api.nvim_set_current_win(vim.fn.bufwinid(draft)); vim.bo[draft].modified = false; press('q')
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { '# Old base (excluded): incorrect' })
  ui.execute(buf); assert(prompts == 0 and git(root, { 'rev-parse', 'HEAD' }) == tip)
  vim.ui.select = select; vim.api.nvim_buf_delete(buf, { force = true })
end)

test('commands, reference completion and History menu reach the same scoped plan', function()
  require('git').setup()
  local root, base = repo(); local tip = commit(root, 'child')
  local buf = vim.api.nvim_create_buf(true, false); vim.api.nvim_set_current_buf(buf)
  require('git.utils').set_buf_work_tree(buf, root); vim.bo[buf].filetype = 'fugitivelog'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { base:sub(1, 12) .. ' base', tip:sub(1, 12) .. ' child' })
  assert(vim.tbl_contains(vim.fn.getcompletion('GitRebasePlan ma', 'cmdline'), 'main'))
  local actions = require('git.features.magit_actions'); actions.attach(buf)
  local function callback(key) assert(vim.fn.maparg(key, 'n', false, true).callback)() end
  local function choose(hash)
    -- Returning from a menu refreshes the real Log in newest-first order.
    for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      local short = line:match('^(%x+)')
      if short and hash:sub(1, #short) == short then
        vim.api.nvim_win_set_cursor(0, { row, 0 }); return row
      end
    end
    error('Commit not found in refreshed Log: ' .. hash)
  end
  vim.api.nvim_win_set_cursor(0, { 1, 0 }); callback('<Space><Space>'); callback('H'); callback('b')
  -- Wait for the asynchronous mark to appear in the source list.
  local ns = vim.api.nvim_get_namespaces().git_rebase_base
  assert(vim.wait(5000, function() return #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) == 1 end, 5))
  choose(base); callback('<Space><Space>'); callback('H'); callback('b')
  assert(vim.wait(5000, function() return #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) == 0 end, 5))
  choose(base); callback('<Space><Space>'); callback('H'); callback('p')
  assert(vim.wait(5000, function() return vim.bo.filetype == 'gitrebaseplan' end, 5))
  assert(vim.api.nvim_buf_get_lines(0, 1, 2, false)[1]:find('--root', 1, true),
    'cleared mark did not restore the cursor-based range including the root commit')
  vim.api.nvim_buf_delete(0, { force = true }); vim.api.nvim_set_current_buf(buf)
  local tip_row = choose(tip); callback('<Space><Space>'); callback('H'); callback('b')
  assert(vim.wait(5000, function()
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
    return #marks == 1 and marks[1][2] == tip_row - 1
  end, 5))
  local base_row = choose(base); callback('<Space><Space>'); callback('H'); callback('b')
  assert(vim.wait(5000, function()
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
    return #marks == 1 and marks[1][2] == base_row - 1
  end, 5))
  callback('<Space><Space>'); callback('H'); callback('p')
  assert(vim.wait(5000, function() return vim.bo.filetype == 'gitrebaseplan' end, 5))
  local plan = vim.api.nvim_get_current_buf()
  assert(vim.api.nvim_buf_get_lines(plan, 1, 2, false)[1]:find(base, 1, true))
  vim.api.nvim_buf_delete(plan, { force = true }); vim.api.nvim_set_current_buf(buf)
  vim.cmd('GitRebaseBase!'); assert(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) == 0)
  vim.api.nvim_win_set_cursor(0, { 1, 0 }); vim.cmd('GitRebaseBase')
  assert(vim.wait(5000, function() return #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) == 1 end, 5))
  vim.cmd('GitRebaseBase!')
  vim.cmd('GitRebasePlan ' .. base .. ' ' .. base)
  assert(vim.wait(5000, function() return vim.bo.filetype == 'gitrebaseplan' end, 5))
  vim.api.nvim_buf_delete(0, { force = true }); vim.api.nvim_buf_delete(buf, { force = true })
end)

local session = require('git.features.rebase_plan_session')
local function start(m, text, messages)
  return task(m.root, function() return engine.execute(m, parse(m, text, messages)) end)
end
local function resume(root, action)
  return task(root, function() return session.resume(root, action) end)
end
local function dirty(root)
  write(root, 'base', { 'staged' }); git(root, { 'add', 'base' }); write(root, 'base', { 'staged', 'unstaged' })
  write(root, 'untracked', { 'saved' })
  return git(root, { 'diff', '--cached' }), git(root, { 'diff' })
end

test('break keeps WIP isolated through two pauses and restores it only after completion', function()
  local root, base = repo()
  local a, b = commit(root, 'one', 'one'), commit(root, 'two', 'two')
  local index, work = dirty(root)
  local m = task(root, function() return engine.load(root, { base = base }) end)
  local head, warning, changed, paused = start(m, { 'break', row('pick', a, 'one'), 'break', row('pick', b, 'two') })
  assert(head == base and paused and changed and warning)
  assert(git(root, { 'status', '--porcelain' }) == '')
  local saved, dir = session.pending(root); assert(saved.stash and vim.fn.filereadable(dir .. '/editor-2.lua') == 1)
  head, warning, changed, paused = resume(root, 'continue')
  assert(head and paused and git(root, { 'status', '--porcelain' }) == '')
  head, warning, changed, paused = resume(root, 'continue')
  assert(head and not paused and not warning and not session.pending(root))
  assert(git(root, { 'diff', '--cached' }) == index and git(root, { 'diff' }) == work)
  assert(vim.fn.readfile(root .. '/untracked')[1] == 'saved')
end)

test('abort restores original HEAD and staged/unstaged/untracked WIP', function()
  local root, base = repo()
  local a, b = commit(root, 'one', 'one'), commit(root, 'two', 'two')
  local before = git(root, { 'rev-parse', 'HEAD' }); local index, work = dirty(root)
  local m = task(root, function() return engine.load(root, { base = base }) end)
  assert(select(4, start(m, { row('pick', a, 'one'), 'break', row('pick', b, 'two') })))
  local head, warning, _, paused = resume(root, 'abort')
  assert(head == before and not warning and not paused)
  assert(git(root, { 'symbolic-ref', '--short', 'HEAD' }) == 'main')
  assert(git(root, { 'diff', '--cached' }) == index and git(root, { 'diff' }) == work)
  assert(vim.fn.filereadable(root .. '/untracked') == 1 and not session.pending(root))
end)

test('edit permits manual amend; draft message changes require reword', function()
  local root, base = repo()
  local a, b = commit(root, 'one', 'one'), commit(root, 'two', 'two')
  local m = task(root, function() return engine.load(root, { base = base }) end)
  assert(not engine.parse(m, { row('edit', a, 'changed'), row('pick', b, 'two') }))
  assert(select(4, start(m, { row('edit', a, 'one'), row('pick', b, 'two') })))
  git(root, { 'commit', '--amend', '-qm', 'manual amended' })
  local head, err, _, paused = resume(root, 'continue'); assert(head and not err and not paused)
  assert(git(root, { 'log', '--reverse', '--format=%s', base .. '..HEAD' }) == 'manual amended\ntwo')
end)

test('exec runs intentionally as shell, failed exec pauses without automatically rerunning it', function()
  local root, base = repo(); local a = commit(root, 'one', 'one')
  local m = task(root, function() return engine.load(root, { base = base }) end)
  local text = { row('pick', a, 'one'), 'exec printf done > exec-result', 'exec false' }
  local head, warning, _, paused = start(m, text)
  assert(head and paused and warning:find('false', 1, true))
  assert(vim.fn.readfile(root .. '/exec-result')[1] == 'done')
  head, warning, _, paused = resume(root, 'continue'); assert(head and not warning and not paused)
  assert(vim.fn.readfile(root .. '/exec-result')[1] == 'done')
  assert(not engine.parse(m, { 'exec echo unsafe\nextra', row('pick', a, 'one') }))
  assert(not engine.parse(m, { 'exec ', row('pick', a, 'one') }))
  assert(not engine.parse(m, { 'break', 'exec true' }))
end)

test('paused conflict can be resolved or skipped; simple-plan conflicts still roll back', function()
  local root, base = repo()
  local a = commit(root, 'one', 'base', { 'one' })
  local b = commit(root, 'two', 'base', { 'two' }); local index, work = dirty(root)
  local m = task(root, function() return engine.load(root, { base = base }) end)
  local head, _, _, paused = start(m, { 'break', row('pick', b, 'two'), row('pick', a, 'one') })
  assert(head and paused)
  head, _, _, paused = resume(root, 'continue'); assert(head and paused)
  assert(git(root, { 'diff', '--name-only', '--diff-filter=U' }) == 'base')
  head, _, _, paused = resume(root, 'skip'); assert(head and not paused)
  -- Original stash may conflict with the retained commit. Its recovery hash
  -- must remain available instead of silently discarding the initial edits.
  assert(vim.fn.filereadable(root .. '/untracked') == 1 or git(root, { 'stash', 'list' }) ~= '')
end)

test('persistent message editor supports reword after a real new Neovim process resumes', function()
  local root, base = repo()
  local a, b = commit(root, 'one', 'one'), commit(root, 'two', 'two')
  local index, work = dirty(root)
  local m = task(root, function() return engine.load(root, { base = base }) end)
  assert(select(4, start(m, { row('pick', a, 'one'), 'break', row('reword', b, 'new two') }, { [b] = 'two\n\nnew body' })))
  local script = vim.fn.tempname() .. '.lua'
  vim.fn.writefile({ 'package.path = ' .. string.format('%q', plugin .. '/lua/?.lua;') .. ' .. package.path',
    'local hash, err, _, paused = require("git.features.rebase_plan_session").resume(' .. string.format('%q', root) .. ', "continue")',
    'assert(hash and not err and not paused, err)' }, script)
  local result = vim.system({ vim.v.progpath, '--headless', '--clean', '-u', 'NONE', '-l', script }, { text = true }):wait()
  os.remove(script); assert(result.code == 0, result.stderr)
  assert(not session.pending(root))
  assert(git(root, { 'show', '-s', '--format=%B', 'HEAD' }) == 'new two\n\nnew body')
  assert(git(root, { 'diff', '--cached' }) == index and git(root, { 'diff' }) == work)
end)

test('external abort/new rebase cannot consume an unrelated saved plan stash', function()
  local root, base = repo(); local a = commit(root, 'one', 'one'); local index, work = dirty(root)
  local m = task(root, function() return engine.load(root, { base = base }) end)
  assert(select(4, start(m, { 'break', row('pick', a, 'one') })))
  local saved = session.pending(root)
  git(root, { 'rebase', '--abort' })
  local script = vim.fn.tempname()
  vim.fn.writefile({ '#!/bin/sh', 'echo break >> "$1"' }, script)
  git(root, { 'rebase', '-i', '--force-rebase', base }, { env = { GIT_SEQUENCE_EDITOR = 'sh ' .. vim.fn.shellescape(script) } })
  local head, err = resume(root, 'abort'); assert(not head and err:find('Another rebase', 1, true))
  assert(session.pending(root).stash == saved.stash)
  git(root, { 'rebase', '--abort' }); os.remove(script)
  head, err = resume(root, 'continue'); assert(head and not err and not session.pending(root))
  assert(git(root, { 'diff', '--cached' }) == index and git(root, { 'diff' }) == work)
end)

test('UI control insertion, preview/action colors, pause banner and native Git continue dispatch', function()
  local root, base = repo(); commit(root, 'one', 'one'); commit(root, 'two', 'two')
  local buf = open(root, base)
  local tick, modified = vim.api.nvim_buf_get_changedtick(buf), vim.bo[buf].modified
  require('git.features.panel_highlight').rebase(buf)
  assert(vim.api.nvim_buf_get_changedtick(buf) == tick and vim.bo[buf].modified == modified)
  local ns = vim.api.nvim_get_namespaces().git_panel_highlight
  local function groups()
    local found = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do found[mark[4].hl_group] = true end
    return found
  end
  assert(groups().GitPanelPick and groups().GitPanelHash and groups().GitPanelTitle and groups().GitPanelKey)
  local function map(key) assert(vim.fn.maparg(key, 'n', false, true).callback)() end
  vim.api.nvim_win_set_cursor(0, { 7, 0 }); map('cf')
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = buf }); assert(groups().GitPanelFixup)
  map('cp'); map('cb'); assert(vim.api.nvim_get_current_line() == 'break')
  local input = vim.ui.input; local submit
  vim.ui.input = function(_, cb) submit = cb end
  map('cx'); submit(nil); assert(vim.api.nvim_buf_line_count(buf) == 9)
  map('cx'); vim.api.nvim_buf_set_lines(buf, 8, 8, false, { '# edited' }); submit('true')
  assert(not table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'):find('exec true', 1, true))
  map('cx'); submit('true'); vim.ui.input = input
  assert(vim.api.nvim_get_current_line() == 'exec true')
  local select = vim.ui.select; vim.ui.select = function(choices, _, cb) cb(choices[1]) end
  ui.execute(buf)
  assert(vim.wait(10000, function() return not async.busy(root) and not vim.bo[buf].modifiable and session.pending(root) and session.pending(root).paused end, 5))
  assert(vim.api.nvim_buf_is_valid(buf))
  local before = git(root, { 'rev-parse', 'HEAD' })
  map('cp'); assert(git(root, { 'rev-parse', 'HEAD' }) == before)
  require('git.commands').git({ args = 'rebase --continue', bufnr = buf })
  assert(vim.wait(10000, function() return not session.pending(root) and not vim.api.nvim_buf_is_valid(buf) end, 5))
  vim.ui.select = select
end)

test('linked worktrees own independent paused plan resources', function()
  local root, base = repo(); local a = commit(root, 'one', 'one')
  local other = vim.fn.tempname() .. ' linked plan'; roots[#roots + 1] = other
  git(root, { 'worktree', 'add', '-qb', 'linked', other, 'HEAD' })
  local m = task(root, function() return engine.load(root, { base = base }) end)
  local n = task(other, function() return engine.load(other, { base = base }) end)
  dirty(root); write(other, 'private', { 'other worktree' })
  assert(select(4, start(m, { 'break', row('pick', a, 'one') })))
  assert(not session.pending(other))
  assert(select(4, start(n, { 'break', row('pick', a, 'one') })))
  local _, main_dir = session.pending(root); local _, linked_dir = session.pending(other)
  assert(main_dir ~= linked_dir and linked_dir:find('/worktrees/', 1, true))
  local head, err = resume(other, 'abort'); assert(head and not err and session.pending(root))
  assert(vim.fn.readfile(other .. '/private')[1] == 'other worktree')
  head, err = resume(root, 'abort'); assert(head and not err and not session.pending(root))
end)

test('restoration conflict retains the exact original recovery stash without reapplying it twice', function()
  local root, base = repo(); local a = commit(root, 'one', 'one'); dirty(root)
  local m = task(root, function() return engine.load(root, { base = base }) end)
  assert(select(4, start(m, { row('pick', a, 'one'), 'break' })))
  local saved = session.pending(root)
  write(root, 'base', { 'changed by edit' }); git(root, { 'add', 'base' }); git(root, { 'commit', '--amend', '--no-edit', '-q' })
  local head, warning, _, paused = resume(root, 'continue')
  assert(head and not paused and warning:find(saved.stash, 1, true))
  assert(not session.pending(root) and git(root, { 'rev-parse', 'refs/stash' }) == saved.stash)
  assert(git(root, { 'show', saved.stash .. '^2:base' }) == 'staged')
  assert(git(root, { 'show', saved.stash .. ':base' }) == 'staged\nunstaged')
  assert(git(root, { 'show', saved.stash .. '^3:untracked' }) == 'saved')
  local repeated, err = resume(root, 'continue'); assert(not repeated and err:find('No saved', 1, true))
end)

test('continue preserves staged conflict resolutions without restashing them', function()
  local root, base = repo()
  local a = commit(root, 'one', 'target', { 'one' })
  local b = commit(root, 'two', 'target', { 'two' }); local index, work = dirty(root)
  local m = task(root, function() return engine.load(root, { base = base }) end)
  assert(select(4, start(m, { 'break', row('pick', b, 'two'), row('pick', a, 'one') })))
  assert(select(4, resume(root, 'continue')))
  assert(git(root, { 'diff', '--name-only', '--diff-filter=U' }) == 'target')
  local stash = session.pending(root).stash
  write(root, 'target', { 'resolved second' }); git(root, { 'add', 'target' })
  local head, _, _, paused = resume(root, 'continue'); assert(head and paused)
  assert(git(root, { 'show', 'HEAD:target' }) == 'resolved second')
  assert(session.pending(root).stash == stash, 'resolution was stashed as a new WIP entry')
  write(root, 'target', { 'resolved first' }); git(root, { 'add', 'target' })
  local warning
  head, warning, _, paused = resume(root, 'continue'); assert(head and not warning and not paused)
  assert(git(root, { 'show', 'HEAD:target' }) == 'resolved first')
  assert(git(root, { 'diff', '--cached' }) == index and git(root, { 'diff' }) == work)
end)

test('abort UI cancellation and changed HEAD cannot abort a newer reviewed state', function()
  local root, base = repo(); local a = commit(root, 'one', 'one')
  local m = task(root, function() return engine.load(root, { base = base }) end)
  assert(select(4, start(m, { row('edit', a, 'one') })))
  local select, submit = vim.ui.select
  vim.ui.select = function(_, _, cb) submit = cb end
  session.open(root, 'abort'); assert(vim.wait(5000, function() return submit ~= nil end, 5))
  submit('Cancel'); assert(session.pending(root))
  submit = nil; session.open(root, 'abort'); assert(vim.wait(5000, function() return submit ~= nil end, 5))
  git(root, { 'commit', '--amend', '-qm', 'new reviewed state' })
  local head = git(root, { 'rev-parse', 'HEAD' })
  submit('Abort rebase plan'); assert(vim.wait(5000, function() return not async.busy(root) end, 5))
  assert(session.pending(root) and git(root, { 'rev-parse', 'HEAD' }) == head)
  vim.ui.select = select
  assert(resume(root, 'abort'))
end)

for _, case in ipairs(cases) do
  local ok, err = pcall(case[2])
  if ok then print('PASS: ' .. case[1]) else failures[#failures + 1] = case[1] .. ': ' .. tostring(err); print('FAIL: ' .. failures[#failures]) end
end
for _, root in ipairs(roots) do vim.fn.delete(root, 'rf') end
assert(#failures == 0, table.concat(failures, '\n'))
print(('PASS: %d rebase plan integration scenarios'):format(#cases))
