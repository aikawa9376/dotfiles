-- Run from the plugin root: nvim --headless --clean -u NONE -l tests/status_header_stability.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
package.loaded['git.features.status_watch'] = { subscribe = function() return function() end end }
package.loaded['git.features.worktree_watch'] = { subscribe = function() return function() end end }

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
git({ 'remote', 'add', 'origin', root })
vim.fn.writefile({ 'hidden' }, root .. '/hidden.txt')
vim.fn.writefile({ 'ordinary' }, root .. '/ordinary.txt')
git({ 'add', '.' })
git({ 'commit', '-qm', 'base' })
local base = git({ 'rev-parse', 'HEAD' })
git({ 'commit', '--allow-empty', '-qm', 'remote commit' })
git({ 'update-ref', 'refs/remotes/origin/main', 'HEAD' })
git({ 'reset', '--hard', '-q', base })
git({ 'branch', '--set-upstream-to=origin/main' })
vim.fn.writefile({ 'stashed' }, root .. '/stash.txt')
git({ 'stash', 'push', '-u', '-qm', 'saved work' })
git({ 'update-index', '--skip-worktree', '--', 'hidden.txt' })
vim.fn.writefile({ 'changed' }, root .. '/hidden.txt')
vim.fn.writefile({ 'ordinary', 'changed' }, root .. '/ordinary.txt')

local flags = require('git.features.index_flags')
local original_system = vim.system
local flag_reads, unpulled_reads = 0, 0
vim.system = function(argv, ...)
  if argv[1] == 'git' and (argv[2] == 'ls-files' and (argv[3] == '-v' or argv[3] == '--stage')
    or argv[2] == 'hash-object') then
    flag_reads = flag_reads + 1
  end
  if argv[1] == 'git' and argv[2] == 'log' then
    for _, arg in ipairs(argv) do
      if type(arg) == 'string' and vim.startswith(arg, 'HEAD..') then
        unpulled_reads = unpulled_reads + 1
      end
    end
  end
  return original_system(argv, ...)
end
local first = flags.inspect(root)
assert(first.changed_count == 1)
local reads = flag_reads
assert(flags.inspect(root, first) == first and flag_reads == reads,
  'unchanged flagged files were reread')
vim.fn.writefile({ 'changed again' }, root .. '/hidden.txt')
local changed = flags.inspect(root, first)
assert(changed ~= first and flag_reads > reads and changed.changed_count == 1,
  'edited flagged file did not invalidate cache')
git({ 'update-index', '--no-skip-worktree', '--', 'hidden.txt' })
assert(#flags.inspect(root, changed).entries == 0, 'index flag update did not invalidate cache')
git({ 'update-index', '--skip-worktree', '--', 'hidden.txt' })

local executable = vim.fn.executable
vim.fn.executable = function(name) return name == 'gh' and 0 or executable(name) end
local status = require('git.features.status')
status.setup(vim.api.nvim_create_augroup('StatusHeaderStabilityTest', { clear = true }))
local b = status.open({ work_tree = root, split = true })
local function contents()
  return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), '\n')
end
assert(vim.wait(5000, function()
  local lines = contents()
  return lines:find('Hidden changes: 1 file', 1, true)
    and lines:find('Index flags [local]', 1, true)
    and lines:find('Unpulled from origin/main (1)', 1, true)
    and lines:find('Stashes (1)', 1, true)
    and not lines:find('Loading repository details', 1, true)
end, 20), 'initial headers were not loaded')

local missing = {}
vim.api.nvim_buf_attach(b, false, {
  on_lines = function()
    local lines = contents()
    for _, header in ipairs({ 'Hidden changes: 1 file', 'Index flags [local]',
      'Unpulled from origin/main (1)', 'Stashes (1)' }) do
      if not lines:find(header, 1, true) then table.insert(missing, header) end
    end
  end,
})
reads = flag_reads
local commits_read = unpulled_reads
vim.fn.maparg('R', 'n', false, true).callback()
assert(vim.wait(5000, function() return flag_reads == reads and not contents():find('Loading', 1, true) end, 20))
vim.wait(500, function() return false end)
assert(#missing == 0, 'warm refresh hid a stable header: ' .. table.concat(missing, ', '))
assert(flag_reads == reads, ('unrelated refresh reread index flags (%d -> %d)'):format(reads, flag_reads))
assert(unpulled_reads == commits_read, 'unrelated refresh reread unpulled commits')

local rewritten = git({ 'commit-tree', base .. '^{tree}', '-p', base, '-m', 'rewritten remote' })
git({ 'update-ref', 'refs/remotes/origin/main', rewritten })
status.refresh_buffer(b)
assert(contents():find('rewritten remote', 1, true),
  'same-count upstream rewrite retained stale unpulled commits')
assert(unpulled_reads > commits_read, 'changed upstream did not reload unpulled commits')

vim.api.nvim_buf_delete(b, { force = true })
vim.system = original_system
vim.fn.executable = executable
vim.fn.delete(root, 'rf')
print('PASS: stable status headers and cached index flags survive warm refresh')
