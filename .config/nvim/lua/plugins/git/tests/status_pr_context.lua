local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
vim.g.git_status_auto_fetch = false
-- Deliver invalidations and GitHub responses explicitly, in either order.
package.loaded['git.features.status_watch'] = { subscribe = function() return function() end end }
package.loaded['git.features.worktree_watch'] = { subscribe = function() return function() end end }
package.loaded['git.features.status_probe'] = { new = function()
  return { check = function() end, stop = function() end }
end }
local system, executable = vim.system, vim.fn.executable
local root, second = vim.fn.tempname(), vim.fn.tempname()
local function git(cwd, args)
  local argv = { 'git', '-C', cwd, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid' }
  vim.list_extend(argv, args)
  local result = system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end
for _, cwd in ipairs({ root, second }) do
  vim.fn.mkdir(cwd, 'p')
  git(cwd, { 'init', '-qb', 'main' })
  git(cwd, { 'remote', 'add', 'origin', cwd })
  git(cwd, { 'commit', '--allow-empty', '-qm', 'initial' })
end
local requests, read = {}, 0
vim.fn.executable = function(name) return name == 'gh' and 1 or executable(name) end
vim.system = function(argv, opts, done)
  if argv[1] ~= 'gh' then return system(argv, opts, done) end
  local head = vim.fn.index(argv, '--head')
  requests[#requests + 1] = { root = opts.cwd, branch = head >= 0 and argv[head + 2] or nil, done = done }
  return { kill = function() end }
end
local status, loading = require('git.features.status'), require('git.features.loading')
status.setup(vim.api.nvim_create_augroup('StatusPrContextTest', { clear = true }))
local function wait(fn) assert(vim.wait(5000, fn, 10), 'Status did not settle') end
local function text(buf) return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end
local function request(branch, cwd)
  read = read + 1
  wait(function() return requests[read] ~= nil end)
  local item = requests[read]
  assert(item.branch == branch and item.root == (cwd or root), vim.inspect(item))
  return item
end
local function reply(item, number, branch)
  local prs = number and { { number = number, title = 'PR for ' .. branch, headRefName = branch,
    url = 'https://github.com/org/repo/pull/' .. number } } or {}
  item.done({ code = 0, stdout = vim.json.encode(prs), stderr = '' })
end
local function settled(buf) wait(function() return not loading.busy(buf) end) end
local function changed(branch)
  git(root, { 'checkout', '-qb', branch })
  require('git.utils').fire_git_changed({ work_tree = root })
end
local function press(key) vim.fn.maparg(key, 'n', false, true).callback() end
local buf = assert(status.open({ work_tree = root, split = true }))
reply(request('main'), 1, 'main'); settled(buf)
assert(text(buf):find('[branch: main]', 1, true))

-- Manual all scope belongs to this branch, even if the next count is equal.
for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
  if line:find('Pull requests (', 1, true) then vim.api.nvim_win_set_cursor(0, { row, 0 }); break end
end
press('<CR>')
reply(request('main'), 1, 'main'); reply(request(nil), 1, 'main'); settled(buf)
assert(text(buf):find('[all]', 1, true))
changed('other')
local other = request('other')
assert(text(buf):find('Head: other', 1, true) and not text(buf):find('#1 ', 1, true))
reply(other, 2, 'other'); settled(buf)
assert(text(buf):find('[branch: other]', 1, true))
local header
for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
  if line:find('Pull requests (', 1, true) then header = row end
end
assert(vim.fn.foldclosed(header) == -1, 'New branch PRs should start open')

local stale_painted = false
vim.api.nvim_buf_attach(buf, false, { on_lines = function()
  if text(buf):find('STALE', 1, true) then stale_painted = true end
end })
-- Both a branch request and an all-PR fallback can finish after checkout.
press('R')
local old_branch = request('other')
changed('third')
wait(function() return text(buf):find('Head: third', 1, true) end)
assert(not text(buf):find('#2 ', 1, true))
reply(old_branch, 999, 'STALE branch')
reply(request('third'))
local old_all = request(nil)
changed('fourth')
wait(function() return text(buf):find('Head: fourth', 1, true) end)
reply(old_all, 999, 'STALE all')
request('fourth').done({ code = 1, stdout = '', stderr = 'GitHub read failed\nretry later' })
settled(buf)
assert(not stale_painted and not text(buf):find('#', 1, true))
assert(text(buf):find('Pull requests: unavailable', 1, true) and text(buf):find('retry later', 1, true))
press('R'); reply(request('fourth'), 4, 'fourth'); settled(buf)
assert(text(buf):find('#4 ', 1, true) and not text(buf):find('unavailable', 1, true))
press('R'); request('fourth').done({ code = 0, stdout = '{broken', stderr = '' }); settled(buf)
assert(text(buf):find('Invalid JSON', 1, true) and not text(buf):find('#4 ', 1, true))

-- Detached HEAD has no branch filter and an empty repository list stays hidden.
git(root, { 'checkout', '--detach', '-q' })
require('git.utils').fire_git_changed({ work_tree = root })
reply(request(nil)); settled(buf)
assert(not text(buf):find('Pull requests', 1, true))

-- Hidden views also invalidate in-flight results and refresh when reopened.
press('R')
local hidden = request(nil)
press('q')
git(root, { 'checkout', '-q', 'main' })
require('git.utils').fire_git_changed({ work_tree = root })
vim.wait(30, function() return false end)
reply(hidden, 999, 'STALE hidden')
vim.wait(30, function() return false end)
assert(not stale_painted)
assert(status.open({ work_tree = root, split = true }) == buf)
reply(request('main'), 1, 'main'); settled(buf)

-- Resolve a different project from its file, keeping equal branch names apart.
vim.cmd('edit ' .. vim.fn.fnameescape(second .. '/file.txt'))
local second_buf = assert(status.open({ split = true }))
assert(second_buf ~= buf)
reply(request('main', second), 10, 'second repository'); settled(second_buf)
assert(text(second_buf):find('second repository', 1, true) and not text(buf):find('second repository', 1, true))
vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/file.txt'))
assert(status.open({ split = true }) == buf and text(buf):find('#1 ', 1, true))

assert(status.open({ work_tree = second, split = true }) == second_buf)
press('R')
local closed = request('main', second)
vim.api.nvim_buf_delete(second_buf, { force = true })
reply(closed, 999, 'STALE closed')
vim.wait(30, function() return false end)
assert(not loading.busy(second_buf) and not vim.api.nvim_buf_is_valid(second_buf))
assert(not stale_painted)
vim.api.nvim_buf_delete(buf, { force = true })
vim.system, vim.fn.executable = system, executable
vim.cmd('cd /tmp')
vim.fn.delete(root, 'rf'); vim.fn.delete(second, 'rf')
print('PASS: PR branch scopes, obsolete branch/all replies, errors/retry, detached/hidden/closed views and project isolation')
