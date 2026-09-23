-- Run from the plugin root: nvim --headless --clean -u NONE -l tests/lifecycle.lua
local test_path = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(test_path, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path

local utils = require('git.utils')
local renderer = require('git.features.status_renderer')
local syntax = require('git.features.syntax_highlight')
local status = require('git.features.status')
package.loaded.utilities = { smart_close = function() vim.cmd('bdelete') end }
local root = vim.fn.getcwd()
local snapshots, commits = {}, 0
local original_snapshot = renderer.snapshot_async
renderer.snapshot_async = function(bufnr, work_tree, opts, callback)
  snapshots[#snapshots + 1] = { opts = opts, callback = callback }
end
renderer.unpushed_commits_async = function() commits = commits + 1 end
-- No subprocesses or network: hold async work, fail synchronous Git queries.
vim.system = function()
  return { wait = function() return { code = 1, stdout = '', stderr = 'test' } end }
end
status.setup(vim.api.nvim_create_augroup('FugitiveLifecycleTest', { clear = true }))

local function group_exists(name)
  return pcall(vim.api.nvim_get_autocmds, { group = name })
end

local function open()
  return assert(status.open({ work_tree = root, split = true }))
end

-- q hides a split status and retains its initialized buffer across repeated opens.
local cached = open()
local initial_snapshots = #snapshots
local initial_events = #vim.api.nvim_get_autocmds({ group = 'FugitiveStatusRefresh' .. cached })
for _ = 1, 50 do
  vim.fn.maparg('q', 'n', false, true).callback()
  assert(vim.api.nvim_buf_is_loaded(cached), 'q discarded the warm status buffer')
  assert(open() == cached, 'opening status created a new buffer')
  vim.api.nvim_exec_autocmds('FileType', { buffer = cached })
  assert(#snapshots == initial_snapshots, 'reopening/repeated FileType started more work')
  assert(#vim.api.nvim_get_autocmds({ group = 'FugitiveStatusRefresh' .. cached }) == initial_events)
end

-- Changes while hidden invalidate the cache without running Git until reopening.
local source = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(source, root .. '/lifecycle-test-source')
vim.fn.maparg('q', 'n', false, true).callback()
vim.api.nvim_exec_autocmds('BufWritePost', { buffer = source })
assert(#snapshots == initial_snapshots, 'hidden status started work on file write')
assert(open() == cached and #snapshots == initial_snapshots + 1)
vim.fn.maparg('q', 'n', false, true).callback()
vim.api.nvim_exec_autocmds('User', { pattern = 'FugitiveChanged', data = { work_tree = root } })
assert(#snapshots == initial_snapshots + 1, 'hidden status started work on repo change')
assert(open() == cached and #snapshots == initial_snapshots + 2)
vim.api.nvim_buf_delete(source, { force = true })
vim.api.nvim_buf_delete(cached, { force = true })

for _, mode in ipairs({ 'bdelete', 'bwipeout' }) do
  for _ = 1, 50 do
    local b = open()
    local pending = snapshots[#snapshots]
    local before_commits = commits
    vim.cmd(mode)
    assert(not group_exists('FugitiveStatusRefresh' .. b), mode .. ' leaked status handlers')
    assert(not group_exists('FugitiveExtensionSyntax' .. b), mode .. ' leaked syntax handlers')
    assert(not syntax.refresh(b), mode .. ' retained a syntax refresher')
    assert(not pending.opts.is_current(), mode .. ' kept an async snapshot alive')
    -- Simulate a Git result arriving after unload, when bdelete can leave a valid buffer ID.
    pending.callback({ 'Head: stale', 'Help: g?' })
    assert(commits == before_commits, 'late result started more work after teardown')
    if vim.api.nvim_buf_is_valid(b) then vim.api.nvim_buf_delete(b, { force = true }) end
  end
end
assert(#vim.api.nvim_get_autocmds({ event = 'ColorScheme', group = 'FugitiveExtensionHighlights' }) == 1)

-- Shared repository listeners used by branch/stash/etc. also die with their buffer.
for _ = 1, 50 do
  local b = vim.api.nvim_create_buf(false, true)
  vim.b[b].fugitive_work_tree, vim.b[b].git_dir = root, root .. '/.git'
  local group = vim.api.nvim_create_augroup('RepoLifetime' .. b, { clear = true })
  utils.setup_repo_refresh(group, b, function() error('dead listener invoked') end)
  vim.api.nvim_buf_delete(b, { force = true })
  assert(not group_exists('RepoLifetime' .. b))
end
vim.api.nvim_exec_autocmds('User', { pattern = 'FugitiveChanged' })

-- Reattaching syntax is idempotent; a queued refresh cannot revive an unloaded buffer.
local b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(b)
syntax.attach(b)
local count = #vim.api.nvim_get_autocmds({ buffer = b })
for _ = 1, 20 do syntax.attach(b) end
assert(#vim.api.nvim_get_autocmds({ buffer = b }) == count)
vim.api.nvim_exec_autocmds('TextChanged', { buffer = b })
vim.cmd('bdelete')
vim.wait(10, function() return false end)
assert(not syntax.refresh(b))

-- The renderer rejects obsolete results before mutating its model or ownership flag.
local complete
vim.system = function(_, _, callback) complete = callback end
b = vim.api.nvim_create_buf(false, true)
local current = false
local published = 0
original_snapshot(b, root, { is_current = function() return current end }, function()
  published = published + 1
end)
complete({ code = 0, stdout = '# branch.head main\0', stderr = '' })
vim.wait(10, function() return false end)
assert(published == 0 and not renderer.is_owned(b))
current = true
original_snapshot(b, root, { is_current = function() return current end }, function()
  published = published + 1
end)
complete({ code = 0, stdout = '# branch.head main\0', stderr = '' })
assert(vim.wait(100, function() return published == 1 end))
assert(renderer.is_owned(b))
print('PASS: warm reopen, repeated FileType, delete/wipe cleanup, late results, shared listeners, syntax lifetime')
