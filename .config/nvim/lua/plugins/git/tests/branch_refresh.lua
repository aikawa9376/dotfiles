-- Run: python3 tests/run.py branch_refresh
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
vim.opt.rtp:prepend(plugin)
local root = vim.fn.tempname() .. ' branch-refresh'; vim.fn.mkdir(root, 'p')
local system, notify = vim.system, vim.notify
local function git(args, opts)
  local argv = { 'git', '-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
    '-c', 'commit.gpgsign=false' }; vim.list_extend(argv, args)
  local result = system(argv, vim.tbl_extend('force', { text = true }, opts or {})):wait()
  assert(result.code == 0, result.stderr); return vim.trim(result.stdout or '')
end
git({ 'init', '-qb', 'main' })
vim.fn.writefile({ 'base' }, root .. '/file.txt'); git({ 'add', '.' }); git({ 'commit', '-qm', 'base' })
for i = 1, 30 do git({ 'branch', ('branch%02d'):format(i) }) end
local head = git({ 'rev-parse', 'HEAD' })
git({ 'update-ref', 'refs/remotes/upstream/main', head }); git({ 'tag', 'release' })
local reads, sync_reads, held, hold, warnings = 0, 0, {}, false, {}
vim.notify = function(message) warnings[#warnings + 1] = message end
vim.system = function(argv, opts, callback)
  if vim.tbl_contains(argv, 'for-each-ref') then
    reads = reads + 1
    if not callback then sync_reads = sync_reads + 1
    elseif hold then
      local deliver = callback
      callback = function(result)
        held[#held + 1] = function(replacement) deliver(replacement or result) end
      end
    end
  end
  return system(argv, opts, callback)
end
local function wait(fn, message) assert(vim.wait(5000, fn, 5), message or 'Timeout') end
local function settle() vim.wait(220, function() return false end, 10) end
local function changed(repository)
  vim.api.nvim_exec_autocmds('User', { pattern = 'GitChanged', data = { work_tree = repository or root } })
end
local function press(key)
  local map = vim.fn.maparg(key, 'n', false, true)
  assert(type(map.callback) == 'function', 'missing map ' .. key); map.callback()
end
require('git.features.branch').setup(vim.api.nvim_create_augroup('BranchRefreshTest', { clear = true }))
vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/file.txt'))
local source_buf = vim.api.nvim_get_current_buf()
vim.cmd('Gbranch')
local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
local function lines() return vim.api.nvim_buf_get_lines(buf, 0, -1, false) end
local function row_for(name)
  for row, value in ipairs(vim.b[buf].branch_map) do if value == name then return row end end
end
local function view() return vim.api.nvim_win_call(win, vim.fn.winsaveview) end
local function geometry()
  local windows = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    windows[#windows + 1] = { w, vim.api.nvim_win_get_width(w), vim.api.nvim_win_get_height(w) }
  end
  return { layout = vim.fn.winlayout(), windows = windows }
end
settle()
assert(reads == 3 and sync_reads == 3, 'initial inventory was fetched more than once')
local initial_reads = reads
press('gO'); press('q'); settle()
assert(reads == initial_reads, 'clean chooser return refetched the inventory')
press('<Space><Space>'); press('q'); settle()
assert(reads == initial_reads, 'clean transient return refetched the inventory')
changed(root .. '/another-repository'); settle()
assert(reads == initial_reads, 'another repository invalidated Branch')

-- Hold all three Git results: the old view must stay intact until the last one.
local selected = row_for('branch20')
vim.fn.winrestview({ lnum = selected, col = 2, topline = selected - 3, leftcol = 0 })
local old_view, old_lines, widths, shape = view(), lines(), vim.b[buf].branch_layout, geometry()
local long_name = 'a-much-longer-branch-than-the-initial-column'
git({ 'branch', long_name })
hold = true
for _ = 1, 8 do changed() end
vim.wait(80, function() return false end, 5)
assert(reads == initial_reads, 'notification burst was not debounced')
wait(function() return #held == 3 end, 'background queries did not finish')
assert(reads == initial_reads + 3 and sync_reads == 3, 'burst did not use one asynchronous inventory read')
assert(vim.deep_equal(lines(), old_lines) and vim.deep_equal(geometry(), shape), 'loading changed the visible list/layout')
held[1](); held[2](); vim.wait(20, function() return false end, 5)
assert(vim.deep_equal(lines(), old_lines), 'partial Git results were published')
-- User navigation during the read owns the final cursor, not its launch position.
local latest_selection = row_for('branch22')
vim.fn.winrestview({ lnum = latest_selection, col = 2, topline = latest_selection - 3, leftcol = 0 })
old_view = view()
held[3](); held = {}
wait(function() return row_for(long_name) ~= nil end)
assert(row_for('upstream/main') and row_for('release'), 'background inventory lost remote refs or tags')
local new_view = view()
assert(vim.b[buf].branch_map[new_view.lnum] == 'branch22', 'background refresh changed the selected ref')
assert(new_view.lnum - new_view.topline == old_view.lnum - old_view.topline, 'background refresh moved the selection on screen')
assert(new_view.col == old_view.col and new_view.leftcol == old_view.leftcol)
assert(vim.deep_equal(vim.b[buf].branch_layout, widths), 'background refresh shifted the columns')
assert(vim.deep_equal(geometry(), shape), 'background refresh changed window geometry')

-- A manual filter read supersedes held background results and its debounce.
changed(); wait(function() return #held == 3 end)
press('gl')
local filtered, after_filter = lines(), reads
assert(vim.b[buf].branch_filter == 'local_' and sync_reads == 4)
for _, deliver in ipairs(held) do deliver() end
held = {}; settle()
assert(vim.deep_equal(lines(), filtered) and reads == after_filter, 'late results replaced the manual filter')

-- A newer invalidation cancels the older read before it can publish.
changed(); wait(function() return #held == 1 end)
local stale = held[1]; held = {}
git({ 'branch', 'newest' }); changed()
wait(function() return #held == 1 end)
local before_stale = lines()
stale(); vim.wait(20, function() return false end, 5)
assert(vim.deep_equal(lines(), before_stale), 'obsolete request published after a newer invalidation')
held[1](); held = {}; wait(function() return row_for('newest') ~= nil end)

-- A failed refresh retains the last complete view.
local stable = lines()
changed(); wait(function() return #held == 1 end)
held[1]({ code = 128, stdout = '', stderr = 'injected read failure' }); held = {}
wait(function() return #warnings > 0 end)
assert(vim.deep_equal(lines(), stable) and warnings[#warnings]:find('injected read failure', 1, true),
  'failed background refresh cleared the list or lost its error')

-- Hidden notifications perform no queries; normal entry picks up external Git.
hold = false
vim.api.nvim_set_current_buf(source_buf)
local hidden_reads = reads
git({ 'branch', 'while-hidden' }); changed(); settle()
assert(reads == hidden_reads, 'hidden Branch performed background reads')
vim.api.nvim_set_current_buf(buf)
wait(function() return row_for('while-hidden') ~= nil end)
local before_enter = reads
vim.api.nvim_set_current_buf(source_buf)
git({ 'branch', 'external-change' })
vim.api.nvim_set_current_buf(buf)
wait(function() return row_for('external-change') ~= nil end)
assert(reads == before_enter + 1, 'normal entry did not revalidate external changes')

-- R is immediate, cancels a pending notification, and refits the column widths.
changed(); local before_manual = reads
press('R')
assert(reads == before_manual + 1 and vim.b[buf].branch_layout.branch > widths.branch)
settle(); assert(reads == before_manual + 1, 'R left a duplicate queued refresh')

-- An empty filter keeps usable columns for refs discovered by a later update.
press('gt'); git({ 'tag', '-d', 'release' }); press('R')
assert(#vim.b[buf].branch_map == 0 and vim.b[buf].branch_layout.branch > 0)
git({ 'tag', 'new-release' }); changed()
wait(function() return row_for('new-release') ~= nil end)
assert(lines()[1]:find('release', 1, true), 'new refs in an empty filter had no visible name')

-- Unloading also cancels in-flight reads, not only the debounce timer.
hold = true; changed(); wait(function() return #held == 1 end)
local late = held[1]; held = {}
local before_warnings = #warnings
vim.api.nvim_buf_delete(buf, { force = true }); late(); settle()
assert(#warnings == before_warnings, 'late read attempted to publish after wipeout')

-- A separate buffer verifies cleanup before the scheduled read has started.
vim.api.nvim_set_current_buf(source_buf); vim.cmd('Gbranch')
buf = vim.api.nvim_get_current_buf()
changed(); local before_close = reads
vim.api.nvim_buf_delete(buf, { force = true }); settle()
assert(reads == before_close, 'wiped Branch left a debounce timer running')
assert(git({ 'rev-parse', 'HEAD' }) == head and git({ 'status', '--porcelain' }) == '')
vim.system, vim.notify = system, notify
vim.fn.delete(root, 'rf')
print('PASS: Branch menu reuse, coalescing, async atomic publish, stable view/columns, stale/failure/hidden/manual/cleanup paths')
