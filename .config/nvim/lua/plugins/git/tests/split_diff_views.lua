-- Real providers: Status d, Commit d, Gdiff, Gitsigns and Diffview file switches.
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.rtp:prepend(plugin)
vim.opt.rtp:append(vim.fn.stdpath('data') .. '/site')
for _, name in ipairs({ 'nvim-treesitter/runtime', 'gitsigns.nvim', 'diffview.nvim', 'plenary.nvim', 'nvim-web-devicons' }) do
  vim.opt.rtp:prepend(vim.fn.stdpath('data') .. '/lazy/' .. name)
end
local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false' }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait(); assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
git({ 'init', '-qb', 'main' })
local old = { 'function Shared(value)', '  return value + 1', 'end' }
local new = { 'function Shared(value, extra)', '  return value + 1', 'end' }
vim.fn.writefile(old, root .. '/file.lua'); vim.fn.writefile({ 'return 41' }, root .. '/other.lua')
git({ 'add', '.' }); git({ 'commit', '-qm', 'before' })
vim.fn.writefile(new, root .. '/file.lua'); vim.fn.writefile({ 'return 42' }, root .. '/other.lua')
vim.fn.writefile({ '  AddedCall(value)' }, root .. '/added.lua')
git({ 'add', '.' }); git({ 'commit', '-qm', 'after' })
require('git').setup()
require('gitsigns').setup({ update_debounce = 10 })
local split = require('git.features.split_diff')
local syntax = require('git.features.syntax_highlight')
local function wait_pair(label)
  local session
  assert(vim.wait(10000, function()
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      session = split.session(w)
      if session and not session.pending and session.active then return true end
    end
    return false
  end, 5), label .. ': no ready split session')
  assert(vim.wo[session.old.win].diff and vim.wo[session.new.win].diff, label .. ': native alignment disabled')
  return session
end
local function press(key) assert(vim.fn.maparg(key, 'n', false, true).callback, key)() end
-- Status d uses the actual unsaved working file instead of replacing it with a snapshot.
vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/file.lua'))
local work = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(work, 0, 1, false, { 'function Shared(value, unsaved)' })
vim.fn.writefile({ 'function Shared(value, disk)', '  return value + 1', 'end' }, root .. '/file.lua')
local status = require('git.features.status')
local b = assert(status.open({ work_tree = root, split = true, auto_fetch = false }))
local row
assert(vim.wait(3000, function()
  for i, line in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do if line == 'M file.lua' then row = i; return true end end
end, 5))
vim.api.nvim_win_set_cursor(0, { row, 0 }); press('d')
local session = wait_pair('Status d')
assert(session.new.buf == work and vim.bo[work].modified, 'Status split discarded or hid the unsaved worktree buffer')
assert(session.new.lines[1]:find('unsaved', 1, true), 'Status split read disk instead of current content')
assert(session.plan.new[0], 'Status d did not apply structural spans')
vim.cmd('tabclose')
-- Commit d uses immutable versions and changes style live.
local commit = require('git.features.commit')
b = commit.open({ work_tree = root, split = true })
for i, line in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do if line == 'M file.lua' then row = i; break end end
vim.api.nvim_win_set_cursor(0, { row, 0 }); press('d')
session = wait_pair('Commit d')
assert(vim.deep_equal(session.old.lines, old) and vim.deep_equal(session.new.lines, new), 'Commit used wrong revision sides')
syntax.set_word_diff_style('github'); wait_pair('Commit github')
assert(session.style == 'github' and session.plan.new[0][1].options.hl_eol)
syntax.set_word_diff_style('treesitter'); wait_pair('Commit treesitter')
vim.cmd('tabclose')
-- Gdiff keeps its existing object/index semantics.
vim.cmd('tabnew'); vim.api.nvim_win_set_buf(0, work); vim.cmd('Gvdiffsplit HEAD^')
session = wait_pair('Gvdiffsplit')
assert(vim.deep_equal(session.old.lines, old) and session.new.buf == work)
vim.cmd('tabclose')
-- Gitsigns keeps its own index buffer and native diff layout.
vim.cmd('tabnew'); vim.api.nvim_win_set_buf(0, work)
assert(vim.wait(3000, function() return require('gitsigns.cache').cache[work] ~= nil end, 5))
require('gitsigns').diffthis()
session = wait_pair('Gitsigns diffthis')
assert(vim.api.nvim_buf_get_name(session.old.buf):match('^gitsigns://') and session.new.buf == work)
assert(session.plan.new[0], 'Gitsigns diffthis has no selected style')
vim.cmd('tabclose')
-- Blame d snapshots the selected historical/uncommitted versions as before.
vim.cmd('tabnew'); vim.api.nvim_win_set_buf(0, work)
local blame = require('git.features.blame')
local panel = blame.open()
assert(vim.wait(3000, function() return vim.fn.bufwinid(panel) ~= -1 end, 5))
vim.api.nvim_set_current_win(vim.fn.bufwinid(panel)); vim.api.nvim_win_set_cursor(0, { 1, 0 }); press('d')
session = wait_pair('Blame d')
assert(vim.api.nvim_buf_get_name(session.old.buf):match('^git%-blame%-diff://'))
assert(session.plan.new[0], 'Blame d did not apply structural spans')
press('q')
assert(vim.wait(3000, function() return not session.active end, 5), 'Blame diff close retained split ownership')
-- The installed Diffview config hook establishes a/b roles and preserves file switching.
local spec = dofile(vim.fs.dirname(plugin) .. '/diffview.lua')
require('diffview').setup(spec.opts)
local view = require('diffview.lib').diffview_open({ '-C' .. root, 'HEAD^..HEAD' })
assert(view); view:open()
assert(vim.wait(10000, function() return view.files and view.files:len() == 3 and view.cur_entry end, 5))
for _, entry in view.files:iter() do if entry.path == 'file.lua' then view:set_file(entry, true); break end end
assert(vim.wait(10000, function() return view.cur_entry.path == 'file.lua' end, 5))
session = wait_pair('DiffviewOpen')
assert(session.old.win == view.cur_layout.a.id and session.new.win == view.cur_layout.b.id, 'Diffview logical sides reversed')
assert(session.plan.new[0] and session.sources.old and session.sources.new)
local first = session
local second_entry
for _, entry in view.files:iter() do if entry.path == 'other.lua' then second_entry = entry end end
assert(second_entry, 'Diffview second file missing')
view:set_file(second_entry, true)
assert(vim.wait(10000, function()
  local s = split.session(view.cur_layout.b.id)
  return s and s ~= first and not s.pending and s.new.lines[1] == 'return 42'
end, 5), 'Diffview file change reused wrong pair')
assert(not first.active, 'Diffview file switch retained old source ownership')
local second = split.session(view.cur_layout.b.id)
local added_entry
for _, entry in view.files:iter() do if entry.path == 'added.lua' then added_entry = entry end end
assert(added_entry)
view:set_file(added_entry, true)
local added_ready = vim.wait(10000, function()
  local s = split.session(view.cur_layout.b.id)
  return s and s ~= second and not s.pending and s.new.lines[1] == '  AddedCall(value)'
end, 5)
if not added_ready then
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local s = split.session(w)
    print(vim.inspect({ win = w, diff = vim.wo[w].diff, name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)),
      side = vim.w[w].git_split_side, session = s and { pending = s.pending, old = s.old.lines, new = s.new.lines,
        sources = s.sources and { old = not not s.sources.old, new = not not s.sources.new }, parsing = s.parsing } }))
  end
end
assert(added_ready, 'Diffview null side did not finish')
assert(not second.active, 'Diffview addition retained the preceding source pair')
second = split.session(view.cur_layout.b.id)
assert(next(second.plan.old) == nil and second.plan.new[0], 'Diffview addition projected onto null side')
for _, mark in ipairs(second.plan.new[0]) do
  assert(mark.col >= 2 and not mark.options.sign_text and not mark.options.hl_eol,
    'one-sided code addition tinted indentation, gutter or the whole line')
  assert(mark.options.hl_group == 'GitExtSyntaxAdd', 'one-sided addition incorrectly emphasized words')
end
view:close()
assert(vim.wait(1000, function() return not second.active end, 5), 'Diffview close retained session')
vim.fn.delete(root, 'rf')
print('PASS: real Status/Commit/Blame d, Gvdiffsplit, Gitsigns diffthis and DiffviewOpen/file switching/null sides')
