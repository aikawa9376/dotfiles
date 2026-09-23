local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
vim.opt.rtp:prepend(vim.fs.dirname(plugin) .. '/lazyagent')
local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false' }
  vim.list_extend(argv, args); local r = vim.system(argv, { text = true }):wait(); assert(r.code == 0, r.stderr); return vim.trim(r.stdout or '')
end
git({ 'init', '-q' }); vim.fn.writefile({ 'old' }, root .. '/file.txt'); git({ 'add', '.' }); git({ 'commit', '-qm', 'initial' })
vim.fn.writefile({ 'new' }, root .. '/file.txt'); git({ 'add', '.' }); git({ 'commit', '-qm', 'changed' })
local api, notes = require('features.commit'), require('lazyagent.notes')
notes._reset()
local b = api.open({ work_tree = root })
local function find(text)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do if line == text then return row end end
end
api.expand_file(b, 'file.txt')
local row = assert(find('+new'))
local note = assert(notes.add({ bufnr = b, root = root, start_line = row, text = 'Review new line' }))
assert(note.source.custom_commit and note.source.start_line == 1 and note.source.revision == git({ 'rev-parse', 'HEAD' }))
local old = require('features.commit_notes').capture(b, find('-old'), find('-old'))
assert(old.start_line == 1 and old.side == 'a' and old.revision == git({ 'rev-parse', 'HEAD^' }))
local function marked_row()
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(b, notes.namespace, 0, -1, { details = true })) do
    if mark[3] == 0 and mark[4].virt_text then return mark[2] + 1 end
  end
end
assert(marked_row() == row)
vim.api.nvim_win_set_cursor(0, { find('M file.txt'), 0 })
vim.fn.maparg('o', 'n', false, true).callback()
assert(marked_row() == find('M file.txt'), 'collapsed note not attached to file')
api.expand_file(b, 'file.txt')
assert(marked_row() == find('+new'), 'expanded note not restored')
local snapshot = notes.snapshot()
notes.restore(snapshot)
assert(notes.snapshot().entries[1].source.custom_commit)
notes._reset(); vim.api.nvim_buf_delete(b, { force = true }); vim.fn.delete(root, 'rf')
print('PASS: custom commit Notes, immutable old/new line identity, collapse/expand anchors, persistence')
