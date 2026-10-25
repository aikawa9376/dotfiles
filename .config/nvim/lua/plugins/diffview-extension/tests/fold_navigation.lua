-- Revisiting a closed diff fold must preserve it, even when it hides many rows.
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.rtp:prepend(plugin)
vim.opt.rtp:prepend(vim.fs.dirname(plugin) .. '/git')
vim.opt.rtp:prepend(vim.fn.stdpath('data') .. '/lazy/utilities.lua')
for _, name in ipairs({ 'diffview.nvim', 'plenary.nvim', 'nvim-web-devicons', 'nvim-treesitter/runtime' }) do
  vim.opt.rtp:prepend(vim.fn.stdpath('data') .. '/lazy/' .. name)
end
local api = vim.api
local temporary = vim.fn.tempname()
vim.env.XDG_STATE_HOME, vim.env.XDG_CACHE_HOME = temporary .. '/state', temporary .. '/cache'
local root = temporary .. '/repo'; vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false' }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end
git({ 'init', '-qb', 'main' })
local lines = {}
for i = 1, 3000 do lines[i] = 'local value_' .. i .. ' = ' .. i end
for _, path in ipairs({ 'a.lua', 'b.lua' }) do vim.fn.writefile(lines, root .. '/' .. path) end
git({ 'add', '.' }); git({ 'commit', '-qm', 'before' })
lines[1500], lines[2900] = 'local value_1500 = 99999', 'local value_2900 = 99999'
for _, path in ipairs({ 'a.lua', 'b.lua' }) do vim.fn.writefile(lines, root .. '/' .. path) end
git({ 'add', '.' }); git({ 'commit', '-qm', 'after' })
vim.o.scrolloff = 10
require('git').setup({ word_diff_style = 'github' })
-- Install the extension's lifecycle hook without GitHub/network services.
require('diffview_extension.folds').setup(api.nvim_create_augroup('DiffviewFoldTest', { clear = true }))
require('diffview').setup(dofile(vim.fs.dirname(plugin) .. '/diffview.lua').opts)
local view = assert(require('diffview.lib').diffview_open({ '-C' .. root, 'HEAD^..HEAD' }))
view:open()
local function settled(entry)
  assert(vim.wait(5000, function()
    if not view.cur_entry or entry and view.cur_entry ~= entry then return false end
    for _, win in ipairs(view.cur_layout.windows) do if not win:is_file_open() then return false end end
    local worker = view:set_file_in_flight()
    return view.cur_entry.opened and (not worker or worker:is_done())
  end, 5), 'File switch did not finish')
end
settled()
local original = view.cur_entry
local other
for _, entry in view.files:iter() do if entry ~= original then other = entry end end
assert(other)
local function main_call(fn) return api.nvim_win_call(view.cur_layout:get_main_win().id, fn) end
local function round_trip()
  view:set_file(other, true); settled(other)
  view:set_file(original, true); settled(original)
end
local fold_start = main_call(function() return vim.fn.foldclosed(2000) end)
assert(fold_start > 0 and main_call(function() return vim.fn.foldclosedend(2000) - fold_start end) > 1000)
main_call(function() api.nvim_win_set_cursor(0, { fold_start, 0 }) end)
local before = main_call(vim.fn.winsaveview)
round_trip()
for _, win in ipairs(view.cur_layout.windows) do
  api.nvim_win_call(win.id, function()
    assert(vim.fn.foldclosed(2000) == fold_start, 'Revisiting a closed fold opened over 1000 unchanged lines')
    assert(vim.fn.foldclosed(500) > 0 and vim.fn.foldclosed(2990) > 0, 'Unrelated folds changed')
  end)
end
assert(main_call(function() return api.nvim_win_get_cursor(0)[1] end) == fold_start, 'Closed fold cursor moved')
assert(main_call(vim.fn.winsaveview).topline == before.topline, 'Closed fold viewport moved')
-- An intentionally opened context line stays visible on return.
main_call(function() vim.cmd('normal! zo'); api.nvim_win_set_cursor(0, { 2000, 0 }) end)
round_trip()
assert(main_call(function() return vim.fn.foldclosed(2000) end) == -1, 'Opened context was unexpectedly collapsed')
assert(main_call(function() return api.nvim_win_get_cursor(0)[1] end) == 2000)
-- Explicit carried locations retain upstream's reveal behavior.
main_call(function() vim.cmd('normal! zM'); api.nvim_win_set_cursor(0, { fold_start, 0 }) end)
view:snapshot_main_view(original.path)
view:set_carry_lnum(original, 2000)
assert(view:restore_main_view(original.path))
assert(main_call(function() return vim.fn.foldclosed(2000) end) == -1, 'Carried context line was hidden')
-- Fast switching must finish at the latest file without losing the closed fold.
main_call(function() vim.cmd('normal! zM'); api.nvim_win_set_cursor(0, { fold_start, 0 }) end)
for _ = 1, 12 do view:set_file(other, true); view:set_file(original, true) end
settled(original)
assert(main_call(function() return vim.fn.foldclosed(2000) end) == fold_start, 'Rapid switching opened a closed fold')
view:close()
vim.fn.delete(root, 'rf')
print('PASS: long closed folds, revisits, open context, explicit carry and rapid file switching')
