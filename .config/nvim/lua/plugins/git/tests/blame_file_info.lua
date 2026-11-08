local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local function git(args, author, directory)
  local argv = { 'git', '--literal-pathspecs', '-C', directory or root, '-c', 'user.name=Alice',
    '-c', 'user.email=alice@example.invalid', '-c', 'commit.gpgsign=false' }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true, env = {
    GIT_AUTHOR_DATE = '2025-01-01T12:00:00+0900', GIT_COMMITTER_DATE = '2025-01-01T12:00:00+0900',
    GIT_AUTHOR_NAME = author and 'Bob alias' or 'Alice',
    GIT_AUTHOR_EMAIL = author and 'alias@example.invalid' or 'alice@example.invalid',
  } }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout or '')
end
git({ 'init', '-qb', 'main' })
local old_path, path = 'old name.txt', 'new 名[*].txt'
local contents = { 'one', 'two', 'three', 'four', 'five', 'six' }
vim.fn.writefile(contents, root .. '/' .. old_path)
git({ 'add', '.' }); git({ 'commit', '-qm', 'Initial file' })
local first = git({ 'rev-parse', 'HEAD' })
contents[2] = 'changed'
vim.fn.writefile(contents, root .. '/' .. old_path)
git({ 'commit', '-qam', 'Changed line' }, true)
local second = git({ 'rev-parse', 'HEAD' })
git({ 'mv', old_path, path }); git({ 'commit', '-qm', 'Rename file' })
local rename = git({ 'rev-parse', 'HEAD' })
for index = 1, 11 do
  contents[#contents + 1] = 'extra ' .. index
  vim.fn.writefile(contents, root .. '/' .. path)
  git({ 'commit', '-qam', 'Append ' .. index }, true)
end
vim.fn.writefile({ 'Bob <bob@example.invalid> Bob alias <alias@example.invalid>' }, root .. '/.mailmap')
git({ 'add', '.mailmap' }); git({ 'commit', '-qm', 'Mailmap (unrelated to file)' })
local head = git({ 'rev-parse', 'HEAD' })
contents[#contents + 1] = 'staged'
vim.fn.writefile(contents, root .. '/' .. path); git({ 'add', path })
contents[#contents + 1] = 'unstaged'
vim.fn.writefile(contents, root .. '/' .. path)
vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/' .. path))
local origin, code_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
vim.api.nvim_buf_set_lines(origin, -1, -1, false, { 'unsaved' })
local previous_gh = false
vim.keymap.set('n', 'gh', function() previous_gh = true end, { buffer = origin })
vim.api.nvim_set_option_value('wrap', false, { win = code_win, scope = 'local' })
local blame = require('git.features.blame')
local b = blame.open()
local function wait(fn, label) assert(vim.wait(5000, fn, 10), label) end
wait(function() return vim.fn.bufwinid(b) ~= -1 end, 'blame open')
local panel = vim.api.nvim_get_current_win()
local function press(key) assert(vim.fn.maparg(key, 'n', false, true).callback, key)() end
local function text(buf) return table.concat(vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false), '\n') end
local function info_win()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'gitblamefileinfo' then return win end
  end
end
local function loaded()
  return info_win() and text(vim.api.nvim_win_get_buf(info_win())):find('History summary', 1, true)
end
local function select_text(needle)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if line:find(needle, 1, true) then vim.api.nvim_win_set_cursor(0, { row, 0 }); return end
  end
  error('Missing row: ' .. needle)
end
press('gh')
assert(info_win() == vim.api.nvim_get_current_win(), 'gh should focus the scrollable information float')
assert(text():find('Loading file history', 1, true), 'history should load asynchronously')
wait(loaded, 'file information')
local overview = text()
assert(overview:find(path, 1, true) and overview:find(root, 1, true))
assert(overview:find('Commits: 14   Changes after add: 13   Authors: 2   Renames: 1', 1, true), overview)
assert(overview:find('First added: ' .. first:sub(1, 8), 1, true))
assert(overview:find('Initial file', 1, true) and overview:find('Original path: ' .. old_path, 1, true))
assert(overview:find('2025-01-01 12:00:00+09:00', 1, true))
assert(overview:find('12  Bob <bob@example.invalid>', 1, true), 'mailmap identities should be used')
assert(overview:find('Staged:   +1 / -0 lines', 1, true))
assert(overview:find('Unstaged: +1 / -0 lines', 1, true))
assert(overview:find('unsaved changes (not included in disk diff counts)', 1, true))
assert(overview:find('Recent commits · 12 / 14', 1, true))
assert(not overview:find('Mailmap (unrelated', 1, true), 'history must be file scoped')
select_text('First added:'); press('y'); assert(vim.fn.getreg('"') == first)
press('a')
assert(text():find('Recent commits · 14 / 14', 1, true))
assert(text():find('Rename: ' .. old_path .. ' → ' .. path, 1, true))
press('a'); assert(text():find('Recent commits · 12 / 14', 1, true))
local float = info_win()
local columns = vim.o.columns
vim.o.columns = 45
vim.api.nvim_exec_autocmds('VimResized', {})
assert(vim.api.nvim_win_get_width(float) <= 41 and vim.wo[float].wrap)
vim.o.columns = columns
vim.api.nvim_exec_autocmds('VimResized', {})
press('gh')
assert(not info_win() and vim.api.nvim_get_current_win() == panel)
assert(not vim.wo[code_win].wrap, 'file-info wrapping must stay local')
vim.api.nvim_set_current_win(code_win); press('gh'); wait(loaded, 'code-side gh')
press('<Esc>'); assert(vim.api.nvim_get_current_win() == panel and not previous_gh)

-- Inspect the initial add using its original path, then return to the paired view.
press('gh'); wait(loaded, 'reopened overview')
select_text('First added:'); press('<CR>')
local commit_buf = vim.api.nvim_get_current_buf()
assert(vim.b[commit_buf].git_commit == first and not info_win())
assert(text():find(old_path, 1, true), 'inspection should expand the historical filename')
press('q')
assert(vim.api.nvim_get_current_win() == panel and vim.api.nvim_get_current_buf() == b)
assert(vim.api.nvim_win_get_buf(code_win) == origin and vim.bo[origin].modified)

-- Parent traversal uses the frame path/revision, rather than today's HEAD/path.
vim.api.nvim_win_set_cursor(panel, { 2, 0 }); press('~')
wait(function() return blame.navigation(b).revision == first end, 'historic blame')
press('gh'); wait(loaded, 'historic overview')
overview = text()
assert(overview:find('Path:       ' .. old_path, 1, true))
assert(overview:find('Commits: 1   Changes after add: 0', 1, true), overview)
assert(overview:find('(historical)', 1, true) and not overview:find('Local changes', 1, true))
assert(not overview:find(second:sub(1, 8), 1, true) and not overview:find('Append', 1, true))
press('q'); press('<C-o>')
assert(vim.api.nvim_win_get_buf(code_win) == origin)

-- Closing the session while its float is focused cancels and wipes the child.
press('gh'); wait(loaded, 'before cleanup')
local info_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_delete(b, { force = true })
assert(not info_win() and not vim.api.nvim_buf_is_valid(info_buf))
vim.api.nvim_set_current_win(code_win); press('gh'); assert(previous_gh, 'original buffer gh must be restored')

-- A shallow boundary can look like an add, but must not claim the true first add.
local shallow = vim.fn.tempname()
git({ 'clone', '-q', '--depth=1', 'file://' .. root, shallow })
local info = require('git.features.blame_file_info')
local data, err
info.load({ root = shallow, path = path }, function(result, failure) data, err = result, failure end)
wait(function() return data or err end, 'shallow history')
assert(data and data.shallow and #data.entries == 1, err)
local overview_state = info.open({ root = shallow, path = path,
  frame = { lines = contents }, return_win = code_win })
wait(loaded, 'shallow overview')
assert(text():find('Earliest available:', 1, true) and not text():find('First added:', 1, true))
assert(text():find('Shallow repository:', 1, true))
press('q')

-- Deliberately deliver canceled callbacks to verify UI ownership/generation guards.
local original_load, calls = info.load, {}
info.load = function(_, callback)
  local call = { callback = callback }
  calls[#calls + 1] = call
  return { cancel = function() call.cancelled = true end }
end
local opts = { root = root, path = path, frame = { lines = contents }, return_win = code_win }
overview_state = info.open(opts)
press('R'); assert(calls[1].cancelled)
calls[1].callback(data)
assert(text():find('Loading file history', 1, true), 'stale refresh must not paint')
calls[2].callback(nil, 'controlled failure')
assert(text():find('controlled failure', 1, true))
press('R'); calls[3].callback(data)
assert(loaded(), 'R should recover from a failed read')
press('R')
info_buf = vim.api.nvim_get_current_buf()
press('q'); assert(calls[4].cancelled)
calls[4].callback(data)
assert(not info_win() and not vim.api.nvim_buf_is_valid(info_buf), 'late results must not reopen a float')
overview_state = info.open(opts)
vim.api.nvim_set_current_win(code_win)
wait(function() return not info_win() end, 'leaving should close the float')
assert(calls[5].cancelled)
info.load = original_load

-- Git failures are surfaced without leaving an unowned subprocess or window.
local failure
info.load({ root = root, path = path, revision = 'not-a-revision' }, function(_, message) failure = message end)
wait(function() return failure end, 'invalid revision error')
vim.api.nvim_buf_delete(origin, { force = true })
vim.fn.delete(root, 'rf'); vim.fn.delete(shallow, 'rf')
print('PASS: blame file overview, followed/literal history, contributors, local changes, inspect/return, historical/shallow scope, cancellation and cleanup')
