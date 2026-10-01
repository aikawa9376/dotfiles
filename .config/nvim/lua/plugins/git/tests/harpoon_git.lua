local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
local config = vim.fs.dirname(vim.fs.dirname(plugin))
package.path = plugin .. '/lua/?.lua;' .. config .. '/?.lua;' .. package.path
vim.opt.rtp:prepend(plugin)
vim.cmd('filetype plugin on')
local installed = vim.env.HARPOON_TEST_PLUGIN_ROOT or vim.fn.stdpath('data') .. '/lazy'
for _, name in ipairs({ 'harpoon', 'plenary.nvim', 'vim-flog', 'fzf-lua' }) do vim.opt.rtp:prepend(installed .. '/' .. name) end
-- Harpoon synchronizes on every list edit; use an isolated store.
local storage = vim.fn.tempname()
vim.env.XDG_DATA_HOME = storage
vim.fn.mkdir(vim.fn.stdpath('data'), 'p')
local api = vim.api
local root = vim.fn.tempname() .. ' repo:日本語'
vim.fn.mkdir(root, 'p')
local objects = require('git.objects')
local function run(args, where) return vim.trim(objects.run(where or root, args)) end
run({ 'init', '-q', '-b', 'main' }); run({ 'config', 'user.name', 'Test' }); run({ 'config', 'user.email', 'test@example.invalid' }); run({ 'config', 'commit.gpgsign', 'false' })
local path = 'a:space 日本語.txt'
vim.fn.writefile({ 'one', 'two', 'three' }, root .. '/' .. path)
run({ 'add', '.' }); run({ 'commit', '-qm', 'first' })
local first = run({ 'rev-parse', 'HEAD' })
vim.fn.writefile({ 'one', 'changed', 'three' }, root .. '/' .. path)
run({ 'add', '.' }); run({ 'commit', '-qm', 'second' })
local second = run({ 'rev-parse', 'HEAD' })
require('git').setup()
vim.cmd('cd ' .. vim.fn.fnameescape(root))
local harpoon = require('harpoon')
vim.fn.mkdir(vim.fn.stdpath('data'), 'p')
dofile(vim.fs.dirname(plugin) .. '/harpoon.lua').config()
local items = require('plugins.harpoon_items')
local adapter = require('plugins.harpoon_git')
local list = harpoon:list('multiple'); list:clear()
local function source()
  vim.cmd('silent! only!')
  vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/' .. path))
end
local function encoded(item) return vim.json.decode(vim.json.encode(item)) end
local function pin()
  local item = items.create(list.config)
  assert(item and item.context.git, 'not a Git pin: ' .. vim.bo.filetype)
  local copy = encoded(item)
  assert(items.equals(item, copy), 'identity changed after persistence')
  return copy
end
local function reopen(item)
  local current = api.nvim_get_current_buf()
  source()
  if api.nvim_buf_is_valid(current) and current ~= api.nvim_get_current_buf() then api.nvim_buf_delete(current, { force = true }) end
  local buf = adapter.open(item.context.git)
  assert(buf, 'failed reopening ' .. item.context.git.view)
  return buf
end
source()
api.nvim_win_set_cursor(0, { 2, 2 })
items.toggle(); assert(list:length() == 1)
items.toggle(); assert(list:length() == 0, 'ma failed to remove ordinary pin')
items.toggle()
local ordinary = list:get(1)
assert(ordinary.value == path and ordinary.context.row == 2)
local legacy = { value = path, context = { row = 99, col = 99 } }
items.select(legacy); assert(api.nvim_win_get_cursor(0)[1] == 3 and api.nvim_win_get_cursor(0)[2] == 4, 'legacy clamp')
local preview_lines = items.preview(ordinary); assert(preview_lines[2] == 'changed')
api.nvim_buf_set_lines(0, 1, 2, false, { 'unsaved' })
assert(items.preview(ordinary)[2] == 'unsaved', 'file preview missed draft')
vim.cmd('write')
-- Status semantic file anchor follows section/row changes.
local status = require('git.features.status').open({ work_tree = root, split = true })
assert(vim.wait(3000, function() return table.concat(api.nvim_buf_get_lines(status, 0, -1, false), '\n'):find(path, 1, true) end, 10))
local file_row
for row = 1, api.nvim_buf_line_count(status) do
  local entry = require('git.features.status_renderer').entry_at(status, row)
  if entry and not entry.header and entry.path == path then file_row = row; break end
end
assert(file_row)
api.nvim_win_set_cursor(0, { file_row, 0 })
local status_pin = pin()
assert(status_pin.context.git.anchor.key == path)
items.toggle(); assert(list:length() == 2)
items.toggle(); assert(list:length() == 1, 'ma failed to remove status pin')
vim.fn.writefile({ 'new' }, root .. '/000-new.txt')
status = reopen(status_pin)
assert(vim.wait(3000, function()
  local entry = require('git.features.status_renderer').entry_at(status, api.nvim_win_get_cursor(0)[1])
  return entry and entry.path == path
end, 10), 'status anchor drifted')
-- Log keeps selection after a newer commit changes list order.
source(); require('git.features.log').open({ work_tree = root })
local log_pin = pin(); assert(log_pin.context.git.hash == second)
source(); run({ 'add', '.' }); run({ 'commit', '-qm', 'third' })
reopen(log_pin)
assert(api.nvim_get_current_line():sub(1, 7) == second:sub(1, 7), 'log selected new row instead of saved hash')
-- Commit restores immutable parent/file/patch position and expanded files.
source(); local c = require('git.features.commit')
local b = c.open({ work_tree = root, revision = second })
c.expand_file(b, path)
for row = 1, api.nvim_buf_line_count(b) do
  local entry, info = c.entry_at(b, row)
  if entry and info.patch_row then api.nvim_win_set_cursor(0, { row, 0 }); break end
end
local commit_pin = pin(); assert(commit_pin.context.git.patch_row)
b = reopen(commit_pin)
local entry, info = c.entry_at(b, api.nvim_win_get_cursor(0)[1])
assert(entry.path == path and info.patch_row == commit_pin.context.git.patch_row)
-- Preview blob converts to durable object identity; index pins remain live.
source(); objects.open(second .. ':' .. path, 'edit', root)
api.nvim_win_set_cursor(0, { 2, 2 })
local blob_pin = pin()
assert(blob_pin.context.git.revision == second)
reopen(blob_pin); assert(api.nvim_get_current_line() == 'changed')
source(); objects.open(':0:' .. path, 'edit', root)
local index_pin = pin(); assert(index_pin.context.git.object == ':0:' .. path)
reopen(index_pin)
-- Ref kind/filter and worktree paths survive close/wipe.
source(); objects.open(second .. ':' .. path, 'edit', root)
require('git.features.log').open({ work_tree = root, range = 1, line1 = 2, line2 = 2 })
local line_log_pin = pin()
assert(line_log_pin.context.git.line_history.revision == second)
reopen(line_log_pin)
assert(vim.b.fugitive_log_line_history.revision == second and vim.b.fugitive_log_line_history.path == path)
source(); require('git.features.branch').open({ work_tree = root, filter = 'local_' })
local branch_pin = pin(); assert(branch_pin.context.git.ref == 'main')
reopen(branch_pin); assert(vim.b.branch_filter == 'local_' and vim.b.branch_map[api.nvim_win_get_cursor(0)[1]] == 'main')
source(); require('git.features.worktree').open({ work_tree = root })
local wt_pin = pin(); assert(wt_pin.context.git.path == root)
reopen(wt_pin); assert(vim.b.worktree_entries[api.nvim_win_get_cursor(0)[1]].path == root)
local other = vim.fn.tempname() .. '/repo'
local same_named = vim.fn.tempname() .. '/repo'
for _, repo in ipairs({ other, same_named }) do
  vim.fn.mkdir(repo, 'p'); run({ 'init', '-q', '-b', 'main' }, repo)
  run({ 'config', 'user.name', 'Test' }, repo); run({ 'config', 'user.email', 'test@example.invalid' }, repo)
  run({ 'config', 'commit.gpgsign', 'false' }, repo)
  vim.fn.writefile({ 'other' }, repo .. '/other.txt')
  run({ 'add', '.' }, repo); run({ 'commit', '-qm', 'other' }, repo)
end
source(); require('git.features.worktree').open({ work_tree = other }); local other_pin = pin()
source(); require('git.features.worktree').open({ work_tree = same_named }); local same_named_pin = pin()
assert(items.display(other_pin) ~= items.display(same_named_pin), 'same-named repositories have identical labels')
source(); adapter.open(other_pin.context.git); assert(vim.b.fugitive_work_tree == other)
source(); require('git.features.branch').open({ work_tree = other }); local other_branch = pin()
source(); adapter.open(other_branch.context.git); assert(vim.b.fugitive_work_tree == other)
vim.fn.delete(other, 'rf'); vim.fn.delete(same_named, 'rf')
-- Stash numbering changes; the selected snapshot is found by its hash.
source(); vim.fn.writefile({ 'stash one' }, root .. '/' .. path); run({ 'stash', 'push', '-qm', 'one' })
require('git.features.stash').open({ work_tree = root })
local stash_pin = pin()
source(); vim.fn.writefile({ 'stash two' }, root .. '/' .. path); run({ 'stash', 'push', '-qm', 'two' })
reopen(stash_pin); assert(api.nvim_get_current_line():match('^stash@{1}'), 'stash selector drifted')
source(); status = require('git.features.status').open({ work_tree = root, split = true, focus = false })
local stash_row
assert(vim.wait(3000, function()
  for row, text in ipairs(api.nvim_buf_get_lines(status, 0, -1, false)) do
    if text:find('stash@{1}', 1, true) then stash_row = row; return true end
  end
end, 10))
api.nvim_win_set_cursor(0, { stash_row, 0 }); local status_stash_pin = pin()
assert(status_stash_pin.context.git.anchor.stash_hash == stash_pin.context.git.hash)
source(); vim.fn.writefile({ 'stash three' }, root .. '/' .. path); run({ 'stash', 'push', '-qm', 'three' })
status = reopen(status_stash_pin)
assert(vim.wait(3000, function() return api.nvim_get_current_line():find('stash@{2}', 1, true) end, 10), 'status stash anchor drifted: ' .. vim.inspect({ cursor = api.nvim_win_get_cursor(0), lines = api.nvim_buf_get_lines(status, 0, -1, false), anchor = status_stash_pin.context.git.anchor }))
-- Reflog entry identity retains operation and timestamp, not its moving selector.
source(); require('git.features.reflog').open({ work_tree = root })
local reflog_pin = pin()
source(); run({ 'reset', '--mixed', first }); run({ 'reset', '--mixed', second })
reopen(reflog_pin)
local e = require('git.features.reflog').entry_at(api.nvim_get_current_buf(), api.nvim_win_get_cursor(0)[1])
assert(e.hash == reflog_pin.context.git.hash and e.action == reflog_pin.context.git.action)
-- WIP exposes its actual snapshot hashes rather than pinning an unnamed scratch buffer.
source(); vim.fn.writefile({ 'wip' }, root .. '/' .. path)
assert(require('git.features.wip').save(root))
require('git.features.wip').open(root); api.nvim_win_set_cursor(0, { 2, 0 })
local wip_pin = pin(); reopen(wip_pin)
assert(vim.b.git_wip_entries[api.nvim_win_get_cursor(0)[1] - 1].hash == wip_pin.context.git.hash)
run({ 'reset', '--hard', second })
-- Graph and generic output are also reconstructible; output reopens as data only.
source(); require('git.graph').open(nil, 'native')
local graph_pin = pin(); reopen(graph_pin); assert(vim.b.git_graph.backend == 'native')
source(); vim.g.flog_write_commit_graph = false
vim.cmd('runtime plugin/flog.vim'); require('git.flog').setup()
require('git.graph').open(nil, 'flog')
local flog_pin = pin()
assert(flog_pin.context.git.hash, 'Flog target not captured')
reopen(flog_pin)
assert(vim.bo.filetype == 'floggraph' and vim.b.fugitive_work_tree == root)
assert(run({ 'rev-parse', vim.fn['flog#Format']('%H') }) == flog_pin.context.git.hash, vim.inspect({ actual = vim.fn['flog#Format']('%H'), expected = flog_pin.context.git.hash }))
source(); vim.cmd('Git show ' .. second)
local output_pin = pin(); assert(output_pin.context.git.view == 'output')
local before_head = run({ 'rev-parse', 'HEAD' })
reopen(output_pin); assert(vim.deep_equal(api.nvim_buf_get_lines(0, 0, -1, false), output_pin.context.git.lines))
assert(run({ 'rev-parse', 'HEAD' }) == before_head)
-- Paired blame uses the current historical frame, independent of its original URI.
source(); local blame = require('git.features.blame')
local panel = blame.open()
assert(vim.wait(3000, function() return blame.navigation(panel) ~= nil end, 10))
api.nvim_win_set_cursor(0, { 2, 0 })
local map = vim.fn.maparg('-', 'n', false, true); map.callback()
assert(vim.wait(3000, function() local n = blame.navigation(panel); return n and n.revision end, 10))
local blame_pin = pin(); assert(blame_pin.context.git.revision == second)
blame.toggle()
source(); panel = adapter.open(blame_pin.context.git)
assert(vim.wait(3000, function() return blame.navigation(panel) ~= nil end, 10))
local n = blame.navigation(panel)
assert(n.revision == second and n.path == path and api.nvim_win_get_cursor(0)[1] == 2)
local paired = 0
for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do if api.nvim_win_get_config(win).relative == '' then paired = paired + 1 end end
assert(paired == 2)
blame.toggle()
-- Real Harpoon menu reordering keeps structured context; preview never opens Git panels.
source(); list:clear(); list:prepend(ordinary); list:prepend(commit_pin)
local win_count = #api.nvim_list_wins()
items.menu(); local menu = harpoon.ui.bufnr
assert(items.menu_item(menu, 1).context.git.revision == second)
local snapshot = require('plugins.harpoon_preview').open({ bufnr = menu, win_id = harpoon.ui.win_id })
assert(snapshot and #api.nvim_list_wins() == win_count + 2, 'preview opened a Git panel')
assert(api.nvim_get_current_win() == harpoon.ui.win_id, 'preview stole focus')
local lines = api.nvim_buf_get_lines(menu, 0, -1, false)
api.nvim_buf_set_lines(menu, 0, -1, false, { lines[2], lines[1] })
assert(items.menu_item(menu, 2).context.git.revision == second)
api.nvim_win_set_cursor(0, { 2, 0 }); harpoon.ui:select_menu_item()
assert(c.model(0).hash == second)
assert(list:get(2).context.git.revision == second)
source(); vim.fn.writefile({ 'other preview', 'same row' }, root .. '/preview.txt')
local other_file = items.create(list.config, root .. '/preview.txt:2:0')
list:clear(); list:prepend(ordinary); list:add(other_file)
items.menu(); menu = harpoon.ui.bufnr
local owner = { bufnr = menu, win_id = harpoon.ui.win_id }
api.nvim_win_set_cursor(owner.win_id, { 1, 0 })
local first_preview = require('plugins.harpoon_preview').open(owner)
assert(api.nvim_buf_get_lines(first_preview.buf_id, 0, 1, false)[1] == 'one')
api.nvim_win_set_cursor(owner.win_id, { 2, 0 })
local next_preview = require('plugins.harpoon_preview').open(owner)
assert(api.nvim_buf_get_lines(next_preview.buf_id, 0, 1, false)[1] == 'other preview', 'same-row preview stayed on the previous file')
vim.fn.maparg('q', 'n', false, true).callback()
assert(vim.wait(1000, function() return harpoon.ui.win_id == nil and #api.nvim_list_wins() == win_count end, 10), 'q left a preview/menu behind')
list:clear(); list:prepend(ordinary); list:add(commit_pin)

harpoon:sync()
harpoon.lists = {}
harpoon.data = require('harpoon.data').Data:new(harpoon.config)
list = harpoon:list('multiple')
assert(list:length() == 2 and items.equals(list:get(2), commit_pin), 'stored pins did not reload')
assert(vim.wait(1000, function() return #api.nvim_list_wins() == win_count end, 10), 'preview leaked')
-- The existing mx picker also selects/deletes structured Git entries and previews data.
source()
local original_fzf = package.loaded['fzf-lua']
local choices, opts
-- Capture the provider boundary without opening fzf's RPC socket/terminal.
package.loaded['fzf-lua'] = { fzf_exec = function(c, o) choices, opts = c, o end }
require('plugins.harpoon_fzf').open({ height = 0.9, width = 0.9 })
assert(#choices == 2)
local previewer = opts.previewer._ctor()
local entry = previewer:parse_entry(choices[2])
assert(entry._scratch_buf and #api.nvim_buf_get_lines(entry._scratch_buf, 0, -1, false) > 1)
api.nvim_buf_delete(entry._scratch_buf, { force = true })
opts.actions.enter({ choices[2] }); assert(c.model(0).hash == second)
opts.actions['ctrl-d']({ choices[2] }); assert(list:length() == 1 and not list:get(1).context.git)
package.loaded['fzf-lua'] = original_fzf
list:clear()
for _, buf in ipairs(api.nvim_list_bufs()) do pcall(api.nvim_buf_delete, buf, { force = true }) end
vim.fn.delete(root, 'rf')
print('PASS: Harpoon file/Git pins, persistence, semantic anchors, paired blame and menu previews')
