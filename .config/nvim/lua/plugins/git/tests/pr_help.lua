local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local view = require('git.features.pr')
local b = assert(view.open({ root = f.root, url = f.pr.url }))
assert(vim.wait(5000, function() return view.model(b) ~= nil end, 10))
local before = vim.api.nvim_buf_get_lines(b, 0, -1, false)
vim.o.columns, vim.o.lines = 60, 24
vim.fn.maparg('?', 'n', false, true).callback()
local help, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
local lines = vim.api.nvim_buf_get_lines(help, 0, -1, false)
local headings = {
  ['Title / description'] = true, ['Diff navigation'] = true,
  ['Compare / open'] = true, ['Comments / review'] = true,
  ['GitHub / panel'] = true, ['Visual selections'] = true,
}
local column, entries, seen = nil, 0, {}
for _, line in ipairs(lines) do
  local keys, label = line:match('^(.-)%s%s+(.+)$')
  if keys then
    if label ~= 'close' then
      local start = assert(line:find(label, #keys + 1, true))
      local at = vim.fn.strdisplaywidth(line:sub(1, start - 1))
      assert(not column or column == at, 'PR help key columns are misaligned')
      assert(vim.fn.strdisplaywidth(line) <= vim.api.nvim_win_get_width(win), 'PR help action wraps at 60 columns')
      assert(not label:find(';', 1, true), 'PR help combines distinct actions on one row')
      column, entries, seen[keys] = at, entries + 1, true
    end
  end
end
assert(entries >= 20 and seen['gc'] and seen['O'] and seen['i'] and seen[':w'] and seen['<C-s>'], 'PR key guide lost actions')
for _, key in ipairs({ 'gu', 'gp', 'gh', 'gU', 'gd' }) do assert(seen[key], 'PR key guide lost section navigation: ' .. key) end
for _, key in ipairs({ 'gF', ']u / [u', ']t / [t' }) do assert(seen[key], 'PR key guide lost review navigation: ' .. key) end
local colored = {}
local aliases_colored = false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(help, vim.api.nvim_create_namespace('git_help'), 0, -1, { details = true })) do
  local line = lines[mark[2] + 1]
  if headings[line] and mark[4].hl_group == 'Type' then colored[line] = true end
  if line:find('o / = / <Tab>', 1, true) and mark[4].hl_group == 'Special' then
    aliases_colored = mark[4].end_col == #'o / = / <Tab>'
  end
end
for heading in pairs(headings) do assert(colored[heading], 'PR help heading missing color: ' .. heading) end
assert(aliases_colored and vim.wo[win].wrap and vim.wo[win].linebreak, 'PR help lost readable text guide styling')
vim.fn.maparg('q', 'n', false, true).callback()
assert(not vim.api.nvim_win_is_valid(win) and vim.api.nvim_get_current_buf() == b)
assert(vim.deep_equal(before, vim.api.nvim_buf_get_lines(b, 0, -1, false)) and not vim.bo[b].modified, 'Help modified the PR draft')
vim.api.nvim_buf_delete(b, { force = true })
f.cleanup()
print('PASS: grouped PR help, aligned key aliases, narrow-window readability and source restoration')
