-- nvim --headless --clean -u NONE -l tests/split_diff.lua
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.rtp:prepend(plugin)
vim.opt.rtp:append(vim.fn.stdpath('data') .. '/site')
vim.opt.rtp:prepend(vim.fn.stdpath('data') .. '/lazy/nvim-treesitter/runtime')
local syntax = require('git.features.syntax_highlight')
local structural = require('git.features.syntax_word_diff')
local split = require('git.features.split_diff')
local native = require('git.features.syntax_native')
if native.command() then native.config.min_nodes = 0 end
local parses, compares = 0, 0
local parser, compare = vim.treesitter.get_string_parser, structural.compare
vim.treesitter.get_string_parser = function(...) parses = parses + 1; return parser(...) end
structural.compare = function(...) compares = compares + 1; return compare(...) end
local before = { 'function calculate(value)', '  return value + 1', 'end' }
local after = { 'function calculate(value, extra)', '  return value + 1', 'end' }
local function buffer(name, lines, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft or 'lua'
  return buf
end
local left = buffer('git-diff://test/before/sample.lua', before)
local right = buffer('git-diff://test/after/sample.lua', after)
vim.api.nvim_win_set_buf(0, left)
local left_win = vim.api.nvim_get_current_win()
vim.wo.winhighlight = 'Normal:NormalNC,DiffText:Search'
vim.cmd('diffthis')
vim.cmd('rightbelow vsplit')
local right_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(right_win, right)
vim.cmd('diffthis')
local session = assert(split.attach(left_win, right_win))
local function ready()
  assert(vim.wait(30000, function() return not session.pending end, 1), 'split comparison never completed')
  assert(session.active, 'split session unexpectedly closed')
end
ready()
assert(session.sources.old and session.sources.new, 'complete source trees missing')
local count = compares
local saved_parses = parses
local row = session.plan.new[0]
assert(row and #row > 0 and not session.plan.old[0], 'inserted argument should only paint new tokens')
for _, mark in ipairs(row) do
  assert(not mark.options.hl_eol and not mark.options.sign_text, 'structural split has whole-line tint or gutter')
  assert(mark.col >= after[1]:find(', extra', 1, true) - 1, 'unchanged function prefix became novel')
end
assert(vim.wo[left_win].winhighlight:find('Normal:NormalNC', 1, true), 'existing non-diff window mapping lost')
assert(vim.wo[left_win].winhighlight:find('DiffText:GitSplitDiffNeutral', 1, true), 'native word background still enabled')
-- An unrelated window displaying the same work buffer must stay undecorated.
vim.cmd('rightbelow vsplit')
local ordinary = vim.api.nvim_get_current_win()
vim.cmd('diffoff')
vim.api.nvim_win_set_buf(ordinary, right)
assert(not split.session(ordinary), 'normal window acquired split ownership')
assert(#vim.api.nvim_buf_get_extmarks(right, vim.api.nvim_create_namespace('git_split_diff'), 0, -1, {}) == 0,
  'split decorations were stored globally in the source buffer')
vim.api.nvim_win_close(ordinary, true)
for _, style in ipairs({ 'delta', 'github', 'diffs' }) do
  syntax.set_word_diff_style(style)
  ready()
  local whole, word = false, false
  for _, mark in ipairs(session.plan.new[0]) do
    whole = whole or mark.options.hl_eol == true
    word = word or mark.options.hl_group == 'FugitiveExtAddText'
  end
  assert(whole and word, style .. ': selected style was not projected')
end
syntax.set_word_diff_style('treesitter'); ready()
assert(compares == count and parses == saved_parses, 'style changes repeated parsing/structural search')
syntax.toggle_changed_fg(); ready()
local novel = false
for _, mark in ipairs(session.plan.new[0]) do novel = novel or mark.options.hl_group == 'FugitiveExtNovelAdd' end
assert(novel, 'split ignored optional native foregrounds')
syntax.toggle_changed_fg(); ready()
assert(compares == count, 'foreground toggle repeated search')
-- Source edits invalidate results even before TextChanged has been delivered.
vim.api.nvim_buf_set_lines(right, 0, 1, false, { 'function calculate(value, other)' })
split.refresh_for(right); ready()
assert(compares == count + 1, 'source edit reused stale graph')
assert(session.plan.new[0][1].col >= 24, 'source edit lost coordinate projection')
-- A second pair does not recompute the resident first pair.
local old2 = buffer('git-diff://test2/before/other.lua', { 'return "old"' })
local new2 = buffer('git-diff://test2/after/other.lua', { 'return "new"' })
vim.cmd('tabnew'); vim.api.nvim_win_set_buf(0, old2)
local w1 = vim.api.nvim_get_current_win(); vim.cmd('diffthis'); vim.cmd('rightbelow vsplit')
local w2 = vim.api.nvim_get_current_win(); vim.api.nvim_win_set_buf(w2, new2); vim.cmd('diffthis')
local second = assert(split.attach(w1, w2))
assert(vim.wait(10000, function() return not second.pending end, 1))
local before_refresh = compares
split.refresh_all(); vim.wait(100)
assert(compares == before_refresh, 'idle refresh recomputed resident pairs')
vim.cmd('tabclose')
assert(vim.wait(1000, function() return not second.active end, 1), 'closed windows retained source ownership')
-- Restore only our native-diff mappings when diff mode is disabled.
vim.api.nvim_win_call(left_win, function() vim.cmd('diffoff') end)
assert(vim.wait(1000, function() return not session.active end, 1))
assert(vim.wo[left_win].winhighlight:find('DiffText:Search', 1, true), 'original native mapping was not restored')
assert(vim.wo[left_win].winhighlight:find('Normal:NormalNC', 1, true), 'cleanup overwrote unrelated mappings')
assert(not syntax.is_pending(right), 'closed split still pending')
-- Native waits stay off the UI thread and lose ownership on window closure.
if native.command() then
  local system, held, killed = vim.system, false, 0
  vim.system = function(command, opts, callback)
    if command[1] == native.command() then
      held = true
      return { kill = function()
        killed = killed + 1
        vim.schedule(function() callback({ code = 143, stdout = '' }) end)
      end }
    end
    return system(command, opts, callback)
  end
  vim.cmd('tabnew')
  local a = buffer('git-diff://held/before/held.lua', { 'return held_old()' })
  local z = buffer('git-diff://held/after/held.lua', { 'return held_new()' })
  vim.api.nvim_win_set_buf(0, a); local aw = vim.api.nvim_get_current_win(); vim.cmd('diffthis')
  vim.cmd('rightbelow vsplit'); local zw = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(zw, z); vim.cmd('diffthis')
  local pending = assert(split.attach(aw, zw))
  assert(vim.wait(3000, function() return held end, 1), 'split bypassed native worker')
  assert(pending.pending and next(pending.plan.new) == nil and next(pending.plan.old) == nil,
    'pending split painted provisional whole-line ranges')
  vim.cmd('tabclose')
  assert(vim.wait(3000, function() return killed == 1 end, 1), 'closed split retained native worker')
  assert(not pending.active and not split.is_pending(z), 'late native output kept split active')
  vim.system = system
  vim.api.nvim_buf_delete(a, { force = true }); vim.api.nvim_buf_delete(z, { force = true })
end
for _, b in ipairs({ left, right, old2, new2 }) do pcall(vim.api.nvim_buf_delete, b, { force = true }) end
print('PASS: full-source split spans, all four styles, foreground option, warm reuse, edits, separate tabs and cleanup')
