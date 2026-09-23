-- Real status renderer + LazyAgent Notes, isolated from the user's editor.
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
vim.opt.rtp:prepend(vim.fs.dirname(plugin) .. '/lazyagent')
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end
git({ 'init', '-q' })
vim.fn.writefile({ 'old' }, root .. '/sample.txt')
git({ 'add', 'sample.txt' })
git({ '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'initial' })
vim.fn.writefile({ 'new' }, root .. '/sample.txt')
local executable = vim.fn.executable
vim.fn.executable = function(name) return name == 'gh' and 0 or executable(name) end
local status = require('git.features.status')
status.setup(vim.api.nvim_create_augroup('StatusNoteIntegration', { clear = true }))
local buf = status.open({ work_tree = root, split = true })
assert(vim.wait(5000, function()
  return not table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'):find('Loading')
end, 20))
local notes = require('lazyagent.notes')
local function press(key) vim.fn.maparg(key, 'n', false, true).callback() end
press('gu')
local file_row = vim.api.nvim_win_get_cursor(0)[1]
press('o')
local row
for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do if line == '+new' then row = i end end
assert(row)
local file_buf = vim.fn.bufadd(root .. '/sample.txt')
vim.fn.bufload(file_buf)
local note = assert(notes.add({ bufnr = buf, start_line = row, text = 'Check this change' }))
assert(note.source.status and note.root == root)
assert(notes.count({ bufnr = buf }) == 1, 'status Notes must use the status repository, not cwd')
local rendered = notes.render({ bufnr = buf })
assert(rendered:find('@sample.txt:1', 1, true))
assert(not rendered:find('> +new', 1, true), 'resolved status Note should not attach a diff')
assert(require('lazyagent.note_source').selection_text(buf, row, row) == '@sample.txt:1')
assert(notes.show_at_cursor({ bufnr = file_buf, lnum = 1, focus = true }), 'already loaded file must receive the Note')
vim.fn.maparg('q', 'n', false, true).callback()
local function icon_row()
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, notes.namespace, 0, -1, { details = true })) do
    if mark[4].virt_text then return mark[2] + 1 end
  end
end
local function changed()
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = buf })
end
press('o')
changed()
assert(vim.wait(1000, function() return icon_row() == file_row end, 10), 'collapse misplaced the note')
press('o')
changed()
assert(vim.wait(1000, function() return icon_row() == row end, 10), 'expand did not restore the note')
local win = vim.api.nvim_get_current_win()
vim.api.nvim_win_close(win, true)
status.open({ work_tree = root, split = true, focus = false })
assert(vim.wait(1000, function() return icon_row() == row end, 10), 'warm reopen misplaced the note')
-- File marks track edits without resetting when the file is displayed again.
vim.api.nvim_buf_set_lines(file_buf, 0, 0, false, { 'inserted' })
notes.refresh_buffer(file_buf)
assert(notes.show_at_cursor({ bufnr = file_buf, lnum = 2, focus = true }))
vim.fn.maparg('q', 'n', false, true).callback()
vim.api.nvim_buf_delete(file_buf, { force = true })
file_buf = vim.fn.bufadd(root .. '/sample.txt')
vim.fn.bufload(file_buf)
notes.refresh_buffer(file_buf)
-- The file on disk still has one line: the remembered position is clamped.
assert(notes.show_at_cursor({ bufnr = file_buf, lnum = 1, focus = true }))
vim.fn.maparg('q', 'n', false, true).callback()
notes.remove(note.id)
assert(#vim.api.nvim_buf_get_extmarks(file_buf, notes.namespace, 0, -1, {}) == 0)
notes._reset()
vim.api.nvim_buf_delete(file_buf, { force = true })
vim.api.nvim_buf_delete(buf, { force = true })
vim.fn.executable = executable
vim.fn.delete(root, 'rf')
print('PASS: real status note capture, collapse/expand, and warm reopen')
