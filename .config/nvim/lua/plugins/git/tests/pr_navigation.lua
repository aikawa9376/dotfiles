local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local content = {}
for i = 1, 36 do content[i] = 'line ' .. i end
vim.fn.writefile(content, f.root .. '/multi.txt')
f.git({ 'add', 'multi.txt' }); f.git({ 'commit', '-qm', 'multi base' })
local base = f.git({ 'rev-parse', 'HEAD' })
f.git({ 'update-ref', 'refs/heads/main', base })
content[2], content[18], content[34] = 'changed two', 'changed eighteen', 'changed thirty-four'
vim.fn.writefile(content, f.root .. '/multi.txt')
vim.fn.writefile({ 'next file' }, f.root .. '/zz-next.txt')
f.git({ 'add', 'multi.txt', 'zz-next.txt' }); f.git({ 'commit', '-qm', 'multi head' })
local head = f.git({ 'rev-parse', 'HEAD' })
f.git({ 'update-ref', 'refs/pull/7/head', head })
f.pr.baseRefOid, f.pr.headRefOid = base, head
local view = require('git.features.pr')
local b = assert(view.open({ root = f.root, url = f.pr.url }))
local function wait(fn, message)
  assert(vim.wait(5000, fn, 10), (message or 'Timeout') .. '\n' .. table.concat(f.notifications, '\n'))
end
wait(function() return view.model(b) ~= nil end)
local function lines() return vim.api.nvim_buf_get_lines(b, 0, -1, false) end
local function at(text)
  for row, line in ipairs(lines()) do if line:find(text, 1, true) then return row end end
  error('Missing row: ' .. text)
end
local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'xt', false)
end
local function current() return vim.api.nvim_get_current_line() end
local function item()
  local entry = view.entry_at(b, vim.fn.line('.'))
  return entry and entry.path
end
-- Native insert stays native, and a growing draft must survive lazy diff expansion.
vim.api.nvim_win_set_cursor(0, { at('PR title'), 0 })
press('iX<Esc>')
assert(current() == 'XPR title', 'i did not insert into the title')
local title = at('XPR title')
vim.api.nvim_buf_set_lines(b, title + 1, title + 1, false, { 'New body line' })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
press('i')
wait(function() return item() == 'multi.txt' end, 'Metadata i did not reach first file')
assert(current():find('M multi.txt', 1, true), 'Metadata i expanded all diffs instead of moving to file')
press('2i')
wait(function() return current():find('@@', 1, true) and current():find('15', 1, true) end,
  '2i did not expand and reach the second hunk')
press('i')
wait(function() return current():find('@@', 1, true) and current():find('31', 1, true) end,
  'i restarted the file instead of reaching its third hunk')
press('i')
wait(function() return item() == 'zz-next.txt' end)
assert(current():find('A zz-next.txt', 1, true), 'i should stop on the next file header')
press('i')
wait(function() return current():match('^@@') ~= nil end)
local last_row = vim.fn.line('.')
press('i')
vim.wait(30, function() return false end, 10)
assert(vim.fn.line('.') == last_row, 'i wrapped past the last diff')
assert(at('XPR title') and at('New body line') and vim.bo[b].modified, 'Navigation erased the PR draft')
assert(f.pr.title == 'PR title', 'Navigation submitted metadata')
vim.api.nvim_buf_delete(b, { force = true })
-- A delayed expansion cannot move the cursor in a replacement buffer.
b = assert(view.open({ root = f.root, url = f.pr.url }))
wait(function() return view.model(b) ~= nil end)
local original_system, requested = vim.system, false
vim.system = function(argv, opts, callback)
  if callback and argv[1] == 'git' and vim.tbl_contains(argv, 'diff') then
    requested = true
    return original_system(argv, opts, function(result)
      vim.defer_fn(function() callback(result) end, 50)
    end)
  end
  return original_system(argv, opts, callback)
end
vim.api.nvim_win_set_cursor(0, { at('M multi.txt'), 0 })
press('i')
wait(function() return requested end)
local scratch = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { 'replacement buffer' })
vim.api.nvim_win_set_buf(0, scratch)
wait(function() return view.model(b).entries[1].patch ~= nil end)
assert(vim.api.nvim_get_current_buf() == scratch and vim.fn.line('.') == 1)
vim.system = original_system
vim.api.nvim_buf_delete(b, { force = true })
f.cleanup()
print('PASS: native insert, growing drafts, Status-style lazy i navigation, counts, hunks/files, final boundary and delayed expansion after buffer replacement')
