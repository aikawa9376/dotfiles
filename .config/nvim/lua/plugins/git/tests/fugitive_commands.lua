local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
vim.opt.rtp:prepend(plugin)
vim.g.git_status_auto_fetch = false
require('git').setup()
local objects = require('git.objects')
local roots = {}
local root
local function git(args) return vim.trim(objects.run(root, args)) end
local function edit(path) vim.cmd('edit! ' .. vim.fn.fnameescape(root .. '/' .. (path or 'a.txt'))) end
local function draft(text) vim.api.nvim_buf_set_lines(0, 0, 1, false, { text or 'draft' }) end
local function first(buf) return vim.api.nvim_buf_get_lines(buf or 0, 0, 1, false)[1] end
local function fixture()
  vim.cmd('silent! only!'); vim.cmd('diffoff!')
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  root = vim.fn.tempname() .. ' parity'; roots[#roots + 1] = root
  vim.fn.mkdir(root .. '/dir', 'p')
  git({ 'init', '-q', '-b', 'main' }); git({ 'config', 'user.name', 'Test' })
  git({ 'config', 'user.email', 'test@example.invalid' }); git({ 'config', 'commit.gpgsign', 'false' })
  vim.fn.writefile({ 'old', 'tail' }, root .. '/a.txt'); vim.fn.writefile({ 'nested' }, root .. '/dir/file.txt')
  git({ 'add', '.' }); git({ 'commit', '-qm', 'first' })
  vim.fn.writefile({ 'head', 'tail' }, root .. '/a.txt'); git({ 'add', '.' }); git({ 'commit', '-qm', 'second' })
  vim.cmd.cd(root); edit()
end
local function blocked(command)
  assert(not pcall(vim.cmd, command), 'Must reject: ' .. command)
end

fixture()
draft(); vim.cmd('Gwrite %')
assert(vim.fn.readfile(root .. '/a.txt')[1] == 'draft' and not vim.bo.modified)
assert(vim.fn.filereadable(root .. '/%') == 0 and git({ 'show', ':a.txt' }):match('^draft'))
draft('explicit'); vim.cmd('Gwrite a.txt'); assert(git({ 'show', ':a.txt' }):match('^explicit'))
vim.fn.writefile({ 'ignored.txt' }, root .. '/.gitignore')
vim.fn.writefile({ 'ignored' }, root .. '/ignored.txt'); edit('ignored.txt'); draft('forced'); vim.cmd('Gwrite!')
assert(git({ 'show', ':ignored.txt' }) == 'forced')

fixture()
vim.fn.writefile({ 'saved uncommitted', 'tail' }, root .. '/a.txt'); edit()
vim.cmd('Gedit HEAD~1:a.txt')
local index_before = git({ 'show', ':a.txt' })
blocked('Gwrite')
assert(vim.fn.readfile(root .. '/a.txt')[1] == 'saved uncommitted' and git({ 'show', ':a.txt' }) == index_before)
vim.cmd('Gwrite!'); assert(vim.fn.readfile(root .. '/a.txt')[1] == 'old')

fixture()
vim.cmd('Gedit'); draft('index draft'); vim.cmd('Gwrite')
assert(not vim.bo.modified and vim.fn.readfile(root .. '/a.txt')[1] == 'index draft')
draft('next index'); vim.cmd('write')
assert(git({ 'show', ':a.txt' }):match('^next index') and vim.fn.readfile(root .. '/a.txt')[1] == 'index draft')
vim.fn.writefile({ 'external' }, root .. '/a.txt'); git({ 'add', '--', 'a.txt' })
vim.cmd('Gread :0:%'); draft('after reload'); vim.cmd('write')
assert(git({ 'show', ':a.txt' }) == 'after reload')

fixture()
local work = vim.api.nvim_get_current_buf()
vim.cmd('Gedit'); vim.cmd('Gedit'); assert(vim.api.nvim_get_current_buf() == work)
vim.cmd('Gedit a.txt'); assert(vim.api.nvim_get_current_buf() == work)
draft('saved'); vim.cmd('write'); vim.cmd('Gedit %'); assert(first() == 'saved')
draft('discard'); vim.cmd('Gedit! HEAD:%'); assert(first() == 'head')
vim.cmd('Gedit'); assert(vim.api.nvim_get_current_buf() == work)
vim.cmd('Gedit !~1:%'); assert(first() == 'old')
edit(); vim.cmd('Gedit'); vim.fn.writefile({ 'disk', 'tail' }, root .. '/a.txt')
vim.cmd('Gread'); assert(first() == 'disk' and vim.bo.modified)
edit(); vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'A', 'B', 'C' })
vim.cmd('1,2Gread HEAD:%'); assert(vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'head', 'tail', 'C' }))
vim.cmd('0Gread HEAD:%'); assert(vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'head', 'tail', 'head', 'tail', 'C' }))

fixture()
local original_window = vim.api.nvim_get_current_win()
vim.cmd('Gpedit +2 HEAD:%')
assert(vim.api.nvim_get_current_win() == original_window and vim.fn.line('.') == 1)
local preview
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.wo[win].previewwindow then preview = win end
end
assert(preview and vim.api.nvim_win_get_cursor(preview)[1] == 2 and first(vim.api.nvim_win_get_buf(preview)) == 'head')
vim.cmd('pclose'); vim.cmd('vertical Gsplit HEAD')
assert(vim.b.custom_git_commit and vim.api.nvim_win_get_width(0) < vim.o.columns)
vim.cmd('only'); edit(); vim.cmd('7Gsplit HEAD:%')
assert(vim.api.nvim_win_get_height(0) == 7)
vim.cmd('only'); edit(); vim.cmd('0Gsplit HEAD:%')
assert(#vim.api.nvim_tabpage_list_wins(0) == 1 and first() == 'head')
vim.cmd('Gedit :'); assert(vim.bo.filetype == 'gitstatus')

fixture()
vim.fn.writefile({}, root .. '/empty.txt')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'A', 'B', 'C' })
vim.cmd('1,2Gread empty.txt'); assert(vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'C' }))

fixture()
vim.cmd('Gedit'); vim.cmd('GDelete')
assert(vim.fn.filereadable(root .. '/a.txt') == 1 and git({ 'ls-files', '--', 'a.txt' }) == '')
edit('dir/file.txt'); local kept = vim.api.nvim_get_current_buf(); vim.cmd('GRemove')
assert(vim.api.nvim_buf_is_loaded(kept) and first(kept) == '' and vim.api.nvim_buf_get_name(kept) == root .. '/dir/file.txt')

fixture()
vim.cmd('Gedit HEAD:a.txt'); blocked('GRemove'); blocked('GMove moved.txt')
assert(vim.fn.filereadable(root .. '/a.txt') == 1 and git({ 'ls-files', '--', 'a.txt' }) == 'a.txt')
edit('dir/file.txt'); vim.cmd('GRename renamed.txt')
assert(vim.api.nvim_buf_get_name(0) == root .. '/dir/renamed.txt' and vim.fn.filereadable(root .. '/renamed.txt') == 0)
edit(); draft('moved draft'); vim.cmd('GMove ' .. vim.fn.fnameescape(root .. '/absolute.txt'))
assert(vim.api.nvim_buf_get_name(0) == root .. '/absolute.txt' and vim.fn.readfile(root .. '/absolute.txt')[1] == 'moved draft')
assert(not vim.bo.modified)

fixture()
vim.cmd('Gedit'); draft('index move'); vim.cmd('GMove renamed.txt')
assert(vim.b.git_object.path == 'renamed.txt' and vim.b.lazyagent_note_source.path == 'renamed.txt')
assert(vim.bo.buftype == 'acwrite' and vim.api.nvim_buf_get_name(0) == objects.uri(root, ':0:renamed.txt'))
vim.cmd('write'); assert(git({ 'show', ':renamed.txt' }):match('^index move'))
assert(vim.fn.readfile(root .. '/renamed.txt')[1] == 'head')

fixture()
local original = vim.api.nvim_get_current_win()
vim.cmd('vertical Gdiffsplit')
assert(vim.api.nvim_get_current_win() ~= original and vim.bo.buftype == 'acwrite' and vim.b.git_object.stage == '0')
assert(vim.api.nvim_win_get_width(0) < vim.o.columns)
vim.cmd('only'); vim.cmd('diffoff'); edit(); vim.cmd('Gedit HEAD:a.txt')
local historical = vim.api.nvim_get_current_win(); vim.cmd('Gdiffsplit')
assert(vim.api.nvim_get_current_win() ~= historical and vim.api.nvim_buf_get_name(0) == root .. '/a.txt')
vim.cmd('only'); vim.cmd('diffoff'); vim.cmd('Gedit')
local index_win = vim.api.nvim_get_current_win(); vim.cmd('Gdiffsplit!')
assert(vim.api.nvim_get_current_win() == index_win)
local comparisons = 0
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  local source = vim.b[vim.api.nvim_win_get_buf(win)].git_object
  if source and source.revision == git({ 'rev-parse', 'HEAD' }) then comparisons = comparisons + 1 end
end
assert(comparisons == 1)

fixture()
vim.fn.writefile({ 'new file' }, root .. '/new.txt'); git({ 'add', '--', 'new.txt' }); edit('new.txt')
vim.cmd('Gedit'); vim.cmd('Gdiffsplit!')
assert(#vim.api.nvim_tabpage_list_wins(0) == 2)
local blank = false
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  local buf = vim.api.nvim_win_get_buf(win)
  if first(buf) == '' then blank = true; assert(not vim.bo[buf].modifiable) end
end
assert(blank, 'A new indexed file must compare against an empty HEAD file')

fixture()
git({ 'checkout', '-qb', 'other', 'HEAD~1' }); vim.fn.writefile({ 'other', 'tail' }, root .. '/a.txt')
git({ 'add', '.' }); git({ 'commit', '-qm', 'other' }); git({ 'checkout', '-q', 'main' })
assert(not pcall(git, { 'merge', '--no-edit', 'other' })); edit()
vim.cmd('Gdiffsplit'); assert(vim.b.git_object.stage == '1')
vim.cmd('only'); vim.cmd('diffoff'); edit(); vim.cmd('Gdiffsplit! HEAD'); assert(#vim.api.nvim_tabpage_list_wins(0) == 2)
vim.cmd('only'); vim.cmd('diffoff'); edit(); vim.cmd('Gdiffsplit!')
assert(#vim.api.nvim_tabpage_list_wins(0) == 3)
assert(vim.fn.maparg('d2o', 'n', false, true).buffer == 1 and vim.fn.maparg('d3o', 'n', false, true).buffer == 1)

fixture()
git({ 'checkout', '-qb', 'other', 'HEAD~1' }); vim.fn.writefile({ 'other nested' }, root .. '/dir/file.txt')
git({ 'add', '.' }); git({ 'commit', '-qm', 'other' }); git({ 'checkout', '-q', 'main' }); git({ 'merge', '--no-edit', 'other' })
vim.cmd('Gedit HEAD:a.txt'); local merge_win = vim.api.nvim_get_current_win(); vim.cmd('Gdiffsplit!')
assert(#vim.api.nvim_tabpage_list_wins(0) == 3 and vim.api.nvim_get_current_win() == merge_win)

fixture()
vim.fn.writefile({ 'unrelated' }, root .. '/dir/file.txt'); git({ 'add', '.' }); git({ 'commit', '-qm', 'third' })
original = vim.api.nvim_get_current_win(); vim.cmd('Gclog!')
assert(#vim.fn.getqflist() == 3 and vim.api.nvim_get_current_win() == original)
vim.cmd('cclose'); vim.cmd('Gclog'); assert(vim.b.custom_git_commit and vim.b.git_commit == git({ 'rev-parse', 'HEAD' }))
vim.cmd('cclose'); edit(); original = vim.api.nvim_get_current_win(); vim.cmd('Gllog!')
assert(#vim.fn.getloclist(0) == 3 and vim.api.nvim_get_current_win() == original)
vim.cmd('lclose'); vim.cmd('1,2Gclog!')
assert(#vim.fn.getqflist() == 2 and vim.api.nvim_get_current_win() == original)
vim.cmd('cclose'); vim.cmd('1,2Gclog'); assert(vim.b.git_object and vim.b.git_object.path == 'a.txt')

fixture()
git({ 'mv', 'a.txt', 'renamed.txt' }); git({ 'commit', '-qm', 'rename' }); edit('renamed.txt')
vim.cmd('0Gclog!'); local items = vim.fn.getqflist(); assert(#items == 3)
for i, item in ipairs(items) do
  local name = vim.api.nvim_buf_get_name(item.bufnr)
  assert(name:match(i == 1 and '/renamed.txt$' or '/a.txt$'), name)
end
vim.cmd('cclose'); vim.cmd('Gcd ' .. vim.fn.fnameescape(root .. '/dir'))
assert(vim.fn.getcwd() == root .. '/dir'); vim.cmd('Glcd ' .. vim.fn.fnameescape(root)); assert(vim.fn.getcwd() == root)

vim.cmd.cd('/tmp')
for _, buf in ipairs(vim.api.nvim_list_bufs()) do pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
for _, path in ipairs(roots) do vim.fn.delete(path, 'rf') end
print('PASS: Fugitive file safety, contextual objects, read ranges, move/delete, diff targets/focus, and quickfix/location history')
