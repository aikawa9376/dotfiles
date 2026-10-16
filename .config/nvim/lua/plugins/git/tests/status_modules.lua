local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
vim.g.git_status_auto_fetch = false
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid' }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout or '')
end
git({ 'init', '-qb', 'main' })
vim.fn.writefile({ 'one' }, root .. '/sample.txt')
git({ 'add', '.' }); git({ 'commit', '-qm', 'initial' })
vim.fn.writefile({ 'one', 'two' }, root .. '/sample.txt')
local modules = require('git.features.status_modules')
local requests, opened, stopped = {}, {}, 0
modules.setup({
  { id = 'notes', title = 'Related notes', before = 'unstaged', events = { { event = 'User', pattern = 'ShelfTest' } },
    load = function(ctx, done)
      requests[#requests + 1] = { ctx = ctx, done = done }
      return function() stopped = stopped + 1 end
    end,
    open = function(ctx, item) opened[#opened + 1] = { ctx = ctx, item = item } end },
  { id = 'tail', title = 'deadbeef Tail', after = 'unstaged', load = function(_, done)
    done({ { id = 'fake', text = 'stash@{0}\nM fake.txt' } })
  end },
  { id = 'broken', title = 'Broken', before = 'commits', load = function() error('provider failed') end },
  { id = 'absent', title = 'Fallback', after = 'index_flags', load = function(_, done)
    done({ { id = 'fallback', text = 'Last section' } })
  end },
})
local executable = vim.fn.executable
vim.fn.executable = function(name) return name == 'gh' and 0 or executable(name) end
local status = require('git.features.status')
status.setup(vim.api.nvim_create_augroup('StatusModulesTest', { clear = true }))
local b = assert(status.open({ work_tree = root, split = true }))
local function wait(fn, message) assert(vim.wait(5000, fn, 10), message or 'Timeout') end
local function lines() return vim.api.nvim_buf_get_lines(b, 0, -1, false) end
local function at(text)
  for row, line in ipairs(lines()) do if line:find(text, 1, true) then return row end end
end
local function press(key) vim.fn.maparg(key, 'n', false, true).callback() end
local function item(id)
  for row, info in pairs(modules.rows(b)) do if info.item and info.item.id == id then return row end end
end
local function reply(values) requests[#requests].done(values) end
wait(function() return #requests > 0 and at('Tail (1)') and at('Unavailable:') and at('Commits [latest 15+]') end)
assert(not at('Related notes'), 'Pending empty shelf should not introduce placeholder rows')
assert(at('Tail (1)') > at('Unstaged changes'), 'after placement was ignored')
assert(at('Unavailable:') and at('provider failed'), 'Provider error did not stay local to its shelf')
assert(lines()[#lines()] == 'Last section', 'Missing anchors should fall back to the end')
assert(requests[1].ctx.root == root and requests[1].ctx.branch == 'main' and requests[1].ctx.paths[1] == 'sample.txt')
reply({ { id = 'a', text = 'Same title' }, { id = 'b', text = 'Same title' } })
wait(function() return item('b') ~= nil end)
assert(at('Related notes') < at('Unstaged changes'), 'before placement was ignored')
vim.api.nvim_win_set_cursor(0, { item('b'), 0 })
press('<CR>')
assert(opened[1].item.id == 'b' and opened[1].ctx.root == root, 'Open used display text instead of item identity')
vim.api.nvim_exec_autocmds('CursorMoved', { buffer = b })
modules.refresh(b)
wait(function() return #requests == 2 end)
reply({ { id = 'b', text = 'Renamed title' }, { id = 'a', text = 'Same title' } })
wait(function() return at('Renamed title') ~= nil end)
assert(vim.fn.line('.') == item('b'), 'Refreshing/reordering lost the selected item')
vim.api.nvim_win_set_cursor(0, { at('Related notes'), 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-i>', true, false, true), 'xt', false)
assert(vim.fn.foldclosed(at('Related notes')) == at('Related notes'), 'Shelf did not fold')
local before = at('Tail (1)')
vim.api.nvim_win_set_cursor(0, { at('M sample.txt'), 0 })
assert(require('git.features.status_renderer').entry_at(b, vim.fn.line('.')), 'Native entry lost its projected row')
press('o')
assert(at('Tail (1)') > before, 'Inline diff did not move the shelf\n' .. table.concat(lines(), '\n'))
local fake = assert(item('fake'))
assert(modules.at(b, fake).item.text:find('\n') and lines()[fake] == 'stash@{0} M fake.txt')
assert(require('git.features.status_renderer').entry_at(b, fake) == nil, 'Shelf item became a Git file')
vim.api.nvim_win_set_cursor(0, { at('deadbeef Tail'), 0 })
assert(not require('git.features.magit_actions').context(b).commit, 'Shelf heading became a Git commit')
assert(not require('git.features.commit_diff').status_items(b, fake, fake), 'Shelf item became a Visual stash target')
vim.api.nvim_win_set_cursor(0, { fake, 0 })
press('d'); press('X'); press('cw')
assert(vim.api.nvim_get_current_buf() == b and git({ 'stash', 'list' }) == '', 'Shelf text invoked a Git action')
local expanded = table.concat(lines(), '\n')
assert(expanded:find('+two', 1, true), 'Native diff expansion used wrong projected rows')
modules.refresh(b)
wait(function() return #requests == 3 end)
reply({ { id = 'b', text = 'Renamed title' } })
wait(function() return at('Related notes (1)') ~= nil end)
assert(table.concat(lines(), '\n'):find('+two', 1, true), 'Shelf update closed an expanded Git diff')
assert(vim.fn.foldclosed(at('Related notes')) == at('Related notes'), 'Shelf update lost fold state')
-- Staging still targets the real file after a shelf has been inserted above it.
vim.api.nvim_win_set_cursor(0, { at('M sample.txt'), 0 })
press('s')
wait(function() return git({ 'diff', '--cached', '--name-only' }) == 'sample.txt' end)
wait(function() return at('Staged changes') ~= nil end)
-- Older providers cannot publish into a new repository snapshot or a closed view.
modules.refresh(b)
wait(function() return #requests >= 4 end)
local stale = requests[#requests]
git({ 'checkout', '-qb', 'other' })
press('R')
wait(function() return requests[#requests].ctx.branch == 'other' end)
stale.done({ { id = 'stale', text = 'Old branch result' } })
reply({ { id = 'fresh', text = 'Current branch result' } })
wait(function() return at('Current branch result') ~= nil end)
assert(not at('Old branch result'), 'Stale provider replaced the current branch')
vim.api.nvim_exec_autocmds('User', { pattern = 'ShelfTest' })
local count = #requests
wait(function() return #requests > count end)
local late = requests[#requests]
vim.api.nvim_buf_delete(b, { force = true })
late.done({ { id = 'late', text = 'Closed view' } })
vim.wait(20, function() return false end)
assert(stopped > 0 and next(modules.rows(b)) == nil, 'Provider ownership was not released')
-- Multiple views must keep independent results even with the same item IDs.
local first, second = vim.api.nvim_create_buf(false, true), vim.api.nvim_create_buf(false, true)
modules.attach(first, function() end); modules.attach(second, function() end)
modules.refresh(first, { root = '/first', branch = 'main' })
modules.refresh(second, { root = '/second', branch = 'main' })
wait(function() return requests[#requests].ctx.root == '/second' end)
local first_request, second_request = requests[#requests - 1], requests[#requests]
second_request.done({ { id = 'same', text = 'Second repository' } })
first_request.done({ { id = 'same', text = 'First repository' } })
local function projected(buf) return table.concat(modules.compose(buf, { 'Head: main' }), '\n') end
wait(function() return projected(first):find('First repository') and projected(second):find('Second repository') end)
assert(not projected(first):find('Second repository') and not projected(second):find('First repository'))
modules.refresh(first)
wait(function() return requests[#requests].ctx.root == '/first' end)
reply({ { id = 'duplicate', text = 'A' }, { id = 'duplicate', text = 'B' } })
wait(function() return projected(first):find('Duplicate Status item', 1, true) end)
modules.cleanup(first); modules.cleanup(second)
vim.api.nvim_buf_delete(first, { force = true }); vim.api.nvim_buf_delete(second, { force = true })
modules.setup({})
vim.fn.delete(root, 'rf')
print('PASS: status shelves, placement, semantic rows/cursors, folds, Git staging, provider errors/events and stale/closed results')
