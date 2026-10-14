local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local view = require('git.features.pr')
local b = assert(view.open({ root = f.root, url = f.pr.url }))
local function wait(fn, message)
  assert(vim.wait(5000, fn, 10), (message or 'Timeout') .. '\n' .. table.concat(f.notifications, '\n'))
end
wait(function() return view.model(b) ~= nil end)
local entries = view.model(b).entries
assert(#entries == 4)
local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'xt', false)
end
local function find(path, header)
  for row = 1, vim.api.nvim_buf_line_count(b) do
    local entry, info = view.entry_at(b, row)
    if entry and entry.path == path and (info.header == true) == header then return row end
  end
end
local function focus(index, header)
  vim.api.nvim_win_set_cursor(0, { assert(find(entries[index].path, header ~= false)), 0 })
end
local function expanded(index) return find(entries[index].path, false) ~= nil end
local function selected(index)
  local entry, info = view.entry_at(b, vim.fn.line('.'))
  return entry and entry.path == entries[index].path and info.header
end
local function expand(index)
  focus(index)
  press('>')
  wait(function() return expanded(index) end, 'File did not expand')
end
-- Keep a growing metadata draft and an unrelated diff open throughout movement.
for row, line in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
  if line == 'PR title' then
    vim.api.nvim_buf_set_lines(b, row - 1, row, false, { 'Draft title', '', 'Extra draft body' })
    break
  end
end
expand(4)
expand(1)
focus(1, false)
press(']]')
wait(function() return selected(2) and expanded(2) end, ']] did not expand the next file')
assert(not expanded(1), ']] left the departing diff expanded')
assert(expanded(4), ']] collapsed an unrelated diff')
press('[[')
wait(function() return selected(1) and expanded(1) end, '[[ did not expand the previous file')
assert(not expanded(2) and expanded(4), '[[ changed the wrong diff expansion')
expand(2)
focus(1)
press('2]]')
wait(function() return selected(3) and expanded(3) end, '2]] did not reach the third file')
assert(not expanded(1) and not expanded(2), 'Counted movement left a departed/skipped diff open')
assert(expanded(4), 'Counted movement collapsed an unrelated diff')
press('99]]')
wait(function() return selected(4) and expanded(4) end, ']] did not stop at the last file')
assert(not expanded(3), ']] left the previous diff open at the boundary')
press(']]')
assert(selected(4) and expanded(4), ']] wrapped or collapsed the last file')
focus(4, false)
press('[[')
assert(selected(4) and expanded(4), '[[ from a hunk should first reach its own file header')
press('2[[')
wait(function() return selected(2) and expanded(2) end, '2[[ did not reach the second file')
assert(not expanded(4) and not expanded(3), 'Reverse movement left a departed diff open')
press('99[[')
wait(function() return selected(1) and expanded(1) end, '[[ did not stop at the first file')
press('[[')
assert(selected(1) and expanded(1), '[[ wrapped or collapsed the first file')
local text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), '\n')
assert(text:find('Draft title', 1, true) and text:find('Extra draft body', 1, true) and vim.bo[b].modified,
  'File navigation lost the growing metadata draft')
assert(f.pr.title == 'PR title', 'Navigation submitted metadata')
vim.api.nvim_buf_delete(b, { force = true })
f.cleanup()
print('PASS: PR file navigation closes departing/skipped diffs, expands destinations, preserves unrelated diffs/drafts, counts and boundaries')
