-- Run from plugin root: nvim --headless --clean -u NONE -l tests/status_reconcile.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local reconcile = require('git.features.status_reconcile')
local b = vim.api.nvim_create_buf(false, true)
local function identity(lines) return lines end
local function set_block(lines)
  local wrapped = { 'prefix' }
  vim.list_extend(wrapped, lines)
  wrapped[#wrapped + 1] = 'suffix'
  vim.api.nvim_buf_set_lines(b, 0, -1, false, wrapped)
end
local function check(old, new, keys)
  set_block(old)
  reconcile.apply(b, 2, #old + 1, new, keys or identity)
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(b, 1, -2, false), new),
    vim.inspect({ old = old, new = new, actual = vim.api.nvim_buf_get_lines(b, 0, -1, false) }))
  assert(vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] == 'prefix')
  assert(vim.api.nvim_buf_get_lines(b, -2, -1, false)[1] == 'suffix')
end

-- Empty sides, boundary edits, repeated keys and binary/Unicode key bytes.
for _, case in ipairs({
  { {}, {} }, { {}, { 'a', 'b' } }, { { 'a', 'b' }, {} },
  { { 'a', 'b' }, { 'x', 'a', 'b', 'y' } },
  { { 'x', 'a', 'b', 'y' }, { 'a', 'b' } },
  { { 'a', '', 'a', 'b' }, { 'b', 'a', '', 'a' } },
  { { 'a', 'b', 'c', 'd', 'e' }, { 'a', 'x', 'c', 'y', 'e' } },
}) do check(case[1], case[2]) end
check({ 'old', 'keep', 'end' }, { 'new', 'keep', 'end', 'extra' }, function(lines)
  local keys = {}
  for row, line in ipairs(lines) do
    keys[row] = (line == 'old' or line == 'new') and 'header\0日本語\nkey' or line
  end
  return keys
end)
check({ 'count', 'ids', 'tail' }, { 'new', 'count', 'tail' })

math.randomseed(617)
local alphabet = { '', 'a', 'b', 'c' }
for _ = 1, 120 do
  local old, new = {}, {}
  for _ = 1, math.random(0, 25) do old[#old + 1] = alphabet[math.random(#alphabet)] end
  for _ = 1, math.random(0, 25) do new[#new + 1] = alphabet[math.random(#alphabet)] end
  check(old, new)
end

-- A changed heading and a surviving file retain their extmarks as rows move.
local old = { 'removed', 'Stashes (1)', 'stash@{0}', 'keep', 'tail' }
local new = { 'Stashes (2)', 'stash@{0}', 'stash@{1}', 'keep', 'tail' }
set_block(old)
local ns = vim.api.nvim_create_namespace('status_reconcile_test')
local heading = vim.api.nvim_buf_set_extmark(b, ns, 2, 0, {})
local keep = vim.api.nvim_buf_set_extmark(b, ns, 4, 0, {})
reconcile.apply(b, 2, #old + 1, new, function(lines)
  return vim.tbl_map(function(line) return line:match('^Stashes') and 'stash_header' or line end, lines)
end)
assert(vim.api.nvim_buf_get_extmark_by_id(b, ns, heading, {})[1] == 1, 'heading anchor lost')
assert(vim.api.nvim_buf_get_extmark_by_id(b, ns, keep, {})[1] == 4, 'file anchor lost')
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(b, 1, -2, false), new))

local many = {}
for i = 1, 3000 do many[i] = 'M file_' .. i end
set_block(many)
local tick = vim.api.nvim_buf_get_changedtick(b)
reconcile.apply(b, 2, #many + 1, many, function() error('unchanged lines requested diff keys') end)
assert(vim.api.nvim_buf_get_changedtick(b) == tick, 'unchanged reconciliation edited the buffer')
vim.api.nvim_buf_delete(b, { force = true })
print('PASS: status reconciliation handles arbitrary edits, preserves anchors, and skips unchanged buffers')
