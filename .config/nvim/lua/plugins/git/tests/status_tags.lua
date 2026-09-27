-- Run from plugin root: nvim --headless --clean -u NONE -l tests/status_tags.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path

local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout or '')
end
local function commit(name)
  vim.fn.writefile({ name }, root .. '/file.txt')
  git({ 'add', 'file.txt' })
  git({ 'commit', '-qm', name })
  return git({ 'rev-parse', 'HEAD' })
end

git({ 'init', '-qb', 'main' })
git({ 'config', 'user.name', 'Test' })
git({ 'config', 'user.email', 'test@example.invalid' })
local zero = commit('zero')
local first = commit('first')
local renderer = require('git.features.status_renderer')
local buf = vim.api.nvim_create_buf(false, true)
local function header(lines)
  for _, line in ipairs(lines) do
    if line:match('^Tags?:') then return line end
  end
end
local function snapshot()
  return assert(renderer.snapshot(buf, root))
end
local initial = snapshot()
assert(not header(initial), 'status displayed a tag when the repository has none')
assert(not table.concat(initial, '\n'):find('Help: g?', 1, true),
  'status still displays the help shortcut in the header')
git({ 'tag', 'v1' })
assert(header(snapshot()) == 'Tag: v1', 'tag at HEAD was not shown')
git({ 'reset', '--hard', '-q', zero })
assert(header(snapshot()) == 'Tag: v1 (1)', 'next tag without an earlier tag was not shown')
git({ 'reset', '--hard', '-q', first })
local middle = commit('middle')
assert(header(snapshot()) == 'Tag: v1 (1)', 'distance from the current tag was wrong')
commit('last')
git({ 'tag', '-a', 'v2', '-m', 'release two' })
git({ 'reset', '--hard', '-q', middle })
assert(header(snapshot()) == 'Tags: v1 (1), v2 (1)',
  'status did not show the current and next tag with their commit counts')
local fast
renderer.snapshot_async(buf, root, {}, function(lines, err)
  assert(lines, err)
  fast = lines
end)
assert(vim.wait(5000, function() return fast ~= nil end, 20))
assert(header(fast) == 'Tags: v1 (1), v2 (1)',
  'fast status refresh dropped the tag header')
git({ 'tag', 'v1.5' })
local moved = header(snapshot())
assert(moved == 'Tags: v1.5, v2 (1)',
  'adding a tag at the same HEAD retained a stale tag header: ' .. tostring(moved))
renderer.cleanup(buf)
vim.fn.delete(root, 'rf')
print('PASS: status shows current and next tags beside branch headers')
