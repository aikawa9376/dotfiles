local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
vim.opt.rtp:prepend(vim.fs.dirname(plugin) .. '/lazyagent')
require('features.commit')
local notes = require('lazyagent.notes')
local b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(b)
vim.b[b].lazyagent_note_source = { kind = 'buffer', root = '/tmp', name = 'fold fixture' }
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  'diff --git a/sample.lua b/sample.lua', '@@ -1 +1 @@', '-old', '+new', '',
  'diff --git a/other.lua b/other.lua', '@@ -1 +1 @@', '-before', '+after',
})
vim.wo.foldmethod = 'manual'
vim.wo.foldtext = 'v:lua.fugitive_foldtext()'
vim.cmd('1,4fold')
vim.cmd('6,9fold')
local first = notes.add({ bufnr = b, root = '/tmp', start_line = 3, text = 'old side note', icon = '!' })
local second = notes.add({ bufnr = b, root = '/tmp', start_line = 4, text = 'new side note', icon = '!' })
assert(vim.fn.foldtextresult(1):find('! 2', 1, true), 'closed file fold must summarize its Notes')
assert(not vim.fn.foldtextresult(6):find('!', 1, true), 'unrelated fold must not show a Note icon')
assert(notes.show_at_cursor({ bufnr = b, lnum = 1, focus = true }))
local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
assert(text:find('old side note', 1, true) and text:find('new side note', 1, true))
vim.fn.maparg('q', 'n', false, true).callback()
vim.cmd('1foldopen')
assert(notes.show_at_cursor({ bufnr = b, lnum = 1, silent = true }) == false, 'expanded header must not pretend to carry a Note')
assert(notes.show_at_cursor({ bufnr = b, lnum = 3, focus = true }))
vim.fn.maparg('q', 'n', false, true).callback()
notes.remove(first.id)
vim.cmd('1foldclose')
assert(vim.fn.foldtextresult(1):find('!', 1, true) and not vim.fn.foldtextresult(1):find('! 2', 1, true))
notes.remove(second.id)
assert(not vim.fn.foldtextresult(1):find('!', 1, true), 'removed Notes must disappear from folded text')
notes._reset()
vim.api.nvim_buf_delete(b, { force = true })
print('PASS: commit fold Note count, folded preview, expansion, removal, and unrelated folds')
