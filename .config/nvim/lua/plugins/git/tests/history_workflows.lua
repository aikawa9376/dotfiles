local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local async = require('git.features.async')
local roots = {}
local function repo()
  local root = vim.fn.tempname() .. ' history'; roots[#roots + 1] = root; vim.fn.mkdir(root, 'p')
  local function git(args)
    local argv = { 'git', '-C', root }; vim.list_extend(argv, args)
    local result = vim.system(argv, { text = true }):wait()
    assert(result.code == 0, result.stderr); return vim.trim(result.stdout)
  end
  git({ 'init', '-qb', 'main' }); git({ 'config', 'user.name', 'Test' }); git({ 'config', 'user.email', 'test@example.invalid' })
  vim.fn.writefile({ 'base' }, root .. '/base'); git({ 'add', '.' }); git({ 'commit', '-qm', 'base' }); git({ 'switch', '-qc', 'feature' })
  return root, git
end
local function task(root, fn)
  local done, success, values
  local started, err = async.run(root, fn, function(ok, ...) success, values, done = ok, { ... }, true end)
  assert(started, err); assert(vim.wait(30000, function() return done end, 5), 'Workflow did not finish')
  return success, unpack(values)
end
local root, git = repo()
vim.fn.writefile({ 'one', 'two', 'three' }, root .. '/file one'); git({ 'add', '.' }); git({ 'commit', '-qm', 'target' })
local target = git({ 'rev-parse', 'HEAD' })
vim.fn.writefile({ 'later' }, root .. '/later'); git({ 'add', '.' }); git({ 'commit', '-qm', 'later' })
vim.fn.writefile({ 'ONE', 'two', 'three' }, root .. '/file one'); git({ 'add', 'file one' })
local staged = git({ 'diff', '--cached' })
local ok, found = task(root, function() return require('git.features.fixup_target').detect(root) end)
assert(ok, found); assert(found.commit.hash == target and found.cached)
assert(git({ 'diff', '--cached' }) == staged, 'Detection mutated index')
vim.fn.writefile({ 'LATER' }, root .. '/later'); git({ 'add', 'later' })
local bad, err = task(root, function() return require('git.features.fixup_target').detect(root) end)
assert(not bad and err:find('multiple commits', 1, true), tostring(err)); git({ 'reset', '--hard', 'HEAD' })

local split_root, sg = repo()
vim.fn.writefile({ 'first', 'second' }, split_root .. '/new file'); vim.fn.writefile({ 'another' }, split_root .. '/other')
sg({ 'add', '.' }); sg({ 'commit', '-qm', 'source' }); local source_hash = sg({ 'rev-parse', 'HEAD' })
vim.fn.writefile({ 'later' }, split_root .. '/later'); sg({ 'add', '.' }); sg({ 'commit', '-qm', 'descendant' })
local before = sg({ 'rev-parse', 'HEAD' }); vim.fn.writefile({ 'dirty' }, split_root .. '/untracked')
local model = assert(require('git.features.commit_model').load(split_root, source_hash)); local entry = model.entries[1]
assert(entry.path == 'new file'); local patch = assert(require('git.features.commit_model').patch(model, entry))
local hunk, selected
for i, line in ipairs(patch) do if line:match('^@@') then hunk = i elseif line == '+first' then selected = i end end
patch = assert(require('git.features.commit_patch').selection(patch, hunk, selected, selected))
local success, child, warning = task(split_root, function()
  return require('git.features.commit_rewrite').apply(split_root, source_hash,
    { patch = patch, reverse = true, split = true, message = { 'extracted' }, expected_head = before })
end)
assert(success and child, warning or child); assert(not warning, warning)
assert(sg({ 'log', '-4', '--format=%s' }) == 'descendant\nextracted\nsource\nbase')
assert(sg({ 'show', child .. '^:new file' }) == 'second'); assert(sg({ 'show', child .. ':new file' }) == 'first\nsecond')
assert(vim.fn.readfile(split_root .. '/untracked')[1] == 'dirty'); assert(sg({ 'stash', 'list' }) == '')
local undo = require('git.features.history_undo')
local planned, plan = task(split_root, function() return undo.plan(split_root, false) end)
assert(planned, plan); assert(plan.kind == 'rebase' and plan.target == before)
local applied, restored, warn = task(split_root, function() return undo.execute(plan) end)
assert(applied and restored, warn or restored); assert(sg({ 'rev-parse', 'HEAD' }) == before)
package.loaded['git.features.history_undo'] = nil; undo = require('git.features.history_undo')
local redone, redo_plan = task(split_root, function() return undo.plan(split_root, true) end); assert(redone, redo_plan)
local replayed, result, redo_warn = task(split_root, function() return undo.execute(redo_plan) end)
assert(replayed and result, redo_warn or result); assert(sg({ 'log', '-4', '--format=%s' }) == 'descendant\nextracted\nsource\nbase')

local checkout_root, cg = repo(); cg({ 'commit', '--allow-empty', '-qm', 'feature' }); cg({ 'switch', 'main' })
local cp_ok, cp = task(checkout_root, function() return undo.plan(checkout_root, false) end); assert(cp_ok and cp.kind == 'checkout', cp)
local c_ok, c_value, c_err = task(checkout_root, function() return undo.execute(cp) end)
assert(c_ok and c_value, c_err); assert(cg({ 'branch', '--show-current' }) == 'feature')
local r_ok, rp = task(checkout_root, function() return undo.plan(checkout_root, true) end); assert(r_ok, rp)
assert(select(2, task(checkout_root, function() return undo.execute(rp) end))); assert(cg({ 'branch', '--show-current' }) == 'main')

local collection = require('git.features.patch_collection')
local origin = vim.api.nvim_get_current_win(); local initial_tabs = #vim.api.nvim_list_tabpages()
collection.open({ work_tree = split_root, commit = child, source_win = origin })
assert(vim.wait(30000, function() return collection.session() ~= nil end, 5))
local session = collection.session(); assert(#vim.api.nvim_list_tabpages() == initial_tabs + 1)
local file_row
for row = 1, vim.api.nvim_buf_line_count(session.left) do
  if require('git.features.commit').entry_at(session.left, row) then file_row = row; break end
end
assert(file_row); collection.collect(session, file_row)
assert(vim.wait(10000, function() return #collection.patch(session) > 0 end, 5))
collection.collect(session, file_row)
assert(vim.wait(10000, function() return #collection.patch(session) == 0 end, 5))
collection.collect(session, file_row)
assert(vim.wait(10000, function() return #collection.patch(session) > 0 end, 5))
local text = table.concat(vim.api.nvim_buf_get_lines(session.right, 0, -1, false), '\n'); assert(text:find('+first', 1, true))
vim.api.nvim_set_current_win(session.right_win); vim.fn.maparg('q', 'n', false, true).callback()
assert(#vim.api.nvim_list_tabpages() == initial_tabs)
assert(not vim.api.nvim_buf_is_valid(session.right)); assert(not vim.api.nvim_buf_is_valid(session.left)); assert(collection.session(session.tab) == nil)
-- Undo a commit keeps its changes staged; redo restores the commit and WIP.
local soft_root, hg = repo()
vim.fn.writefile({ 'changed' }, soft_root .. '/base'); hg({ 'add', 'base' }); hg({ 'commit', '-qm', 'change' })
local changed_hash = hg({ 'rev-parse', 'HEAD' })
vim.fn.writefile({ 'changed', 'unstaged' }, soft_root .. '/base')
local so, sp = task(soft_root, function() return undo.plan(soft_root, false) end)
assert(so and sp.mode == 'soft', sp)
local uo, uv, uw = task(soft_root, function() return undo.execute(sp) end); assert(uo and uv and not uw, uw)
assert(hg({ 'diff', '--cached' }):find('+changed', 1, true))
local ro, rr = task(soft_root, function() return undo.plan(soft_root, true) end); assert(ro, rr)
local eo, ev, ew = task(soft_root, function() return undo.execute(rr) end); assert(eo and ev and not ew, ew)
assert(hg({ 'rev-parse', 'HEAD' }) == changed_hash)
assert(vim.fn.readfile(soft_root .. '/base')[2] == 'unstaged')
assert(hg({ 'diff', '--cached' }) == '')

-- Readonly attribution and rendering still leave the event loop responsive.
local ticks = 0
local timer = vim.uv.new_timer()
timer:start(0, 1, vim.schedule_wrap(function() ticks = ticks + 1 end))
local responsive, detection = task(root, function()
  vim.fn.writefile({ 'ONE', 'two', 'three' }, root .. '/file one')
  return require('git.features.fixup_target').detect(root)
end)
timer:stop(); timer:close()
assert(responsive and ticks > 0, tostring(detection))

-- Multiple files and disjoint lines share a single collection session.
collection.open({ work_tree = split_root, commit = child .. '^', source_win = origin })
assert(vim.wait(30000, function() return collection.session() ~= nil end, 5))
local multi = collection.session()
for _, file in ipairs(multi.model.entries) do
  assert(require('git.features.commit_model').patch(multi.model, file))
  multi.selected[file.path] = { whole = true }
end
local aggregate = table.concat(collection.patch(multi), '\n')
assert(aggregate:find('new file', 1, true) and aggregate:find('other', 1, true))
local preserved = sg({ 'rev-parse', 'HEAD' })
local good, moved, w = task(split_root, function()
  return require('git.features.commit_rewrite').apply(split_root, multi.model.hash,
    { patch = collection.patch(multi), reverse = true, split = true,
      message = { 'collected files' }, expected_head = preserved })
end)
assert(good and moved and not w, w or moved)
assert(sg({ 'rev-parse', 'HEAD^{tree}' }) == sg({ 'rev-parse', preserved .. '^{tree}' }), 'Splitting changed final tree')
-- Closing the tab externally must release both owned buffers and callbacks.
local left, right = multi.left, multi.right
vim.cmd('tabclose!')
assert(vim.wait(10000, function() return not vim.api.nvim_buf_is_valid(left) and not vim.api.nvim_buf_is_valid(right) end, 5))
assert(collection.session(multi.tab) == nil)

-- End-to-end right-panel message and split action, including the confirmation.
dofile(vim.fs.dirname(vim.fs.dirname(plugin)) .. '/config/keymap.lua')
vim.o.timeoutlen = 50
vim.cmd('syntax enable')
local ui_root, ug = repo()
vim.fn.writefile({ 'local alpha = 1', 'local beta = 2' }, ui_root .. '/part.lua')
ug({ 'add', '.' }); ug({ 'commit', '-qm', 'combined' })
collection.open({ work_tree = ui_root, source_win = origin })
assert(vim.wait(30000, function() return collection.session() ~= nil end, 5))
local ui = collection.session()
local expand_row
for row = 1, vim.api.nvim_buf_line_count(ui.left) do
  if require('git.features.commit').entry_at(ui.left, row) then expand_row = row; break end
end
vim.api.nvim_win_set_cursor(0, { expand_row, 0 })
local function press(key)
  local map = vim.fn.maparg(key, 'n', false, true)
  assert(map.callback, 'missing collection key: ' .. key); map.callback()
end
local function patch_row()
  for row = 1, vim.api.nvim_buf_line_count(ui.left) do
    local _, info = require('git.features.commit').entry_at(ui.left, row)
    if info and info.patch_row then return row end
  end
end
local collapsed_count = vim.api.nvim_buf_line_count(ui.left)
for _, keys in ipairs({ { 'o', 'o' }, { '=', '=' }, { '<CR>', '<CR>' }, { '>', '<' } }) do
  press(keys[1])
  assert(vim.wait(10000, function() return patch_row() ~= nil end, 5))
  -- Folding from a diff line returns to its file without clearing the selection.
  vim.api.nvim_win_set_cursor(0, { patch_row(), 0 })
  press(keys[2])
  assert(not patch_row() and vim.api.nvim_buf_line_count(ui.left) == collapsed_count,
    'collection diff did not collapse via ' .. keys[2])
  assert(vim.api.nvim_win_get_cursor(0)[1] == expand_row)
  assert(not vim.bo[ui.left].modifiable and vim.bo[ui.left].bufhidden == 'wipe')
end
press('o')
local selected_row
assert(vim.wait(10000, function()
  for row = 1, vim.api.nvim_buf_line_count(ui.left) do
    local file, info = require('git.features.commit').entry_at(ui.left, row)
    if file and info.patch_row and file.patch[info.patch_row] == '+local alpha = 1' then selected_row = row; return true end
  end
end, 5))
-- Actual mapped input must enter Visual mode and reach the line collection action.
vim.api.nvim_win_set_cursor(0, { selected_row, 0 })
for _, key in ipairs({ 'v', 'vv', 'V', '<C-v>' }) do
  local input = vim.api.nvim_replace_termcodes(key, true, false, true)
  vim.api.nvim_feedkeys(input, 'xt', false)
  assert(vim.fn.mode():match('^[vV\22]$'), 'Visual entry was overridden: ' .. key)
  vim.cmd('normal! \27')
end
for _, selected in ipairs({ true, false }) do
  vim.api.nvim_win_set_cursor(0, { selected_row, 0 })
  vim.api.nvim_feedkeys('vvj', 'xt', false)
  assert(vim.fn.mode() == 'V', 'vv did not select whole lines')
  vim.api.nvim_feedkeys(' ', 'xt', false)
  assert(vim.wait(10000, function()
    local patch = table.concat(collection.patch(ui), '\n')
    return selected and patch:find('+local alpha = 1', 1, true) and patch:find('+local beta = 2', 1, true)
      or not selected and patch == ''
  end, 5), 'Visual Space did not toggle the selected lines')
end
vim.api.nvim_win_set_cursor(0, { selected_row, 0 })
vim.api.nvim_feedkeys('v', 'xt', false)
vim.api.nvim_feedkeys(' ', 'xt', false)
assert(vim.wait(10000, function() return #collection.patch(ui) > 0 end, 5))
local syntax_ns = vim.api.nvim_create_namespace('fugitive_extension_syntax')
local function preview_adds()
  assert(vim.wait(10000, function()
    return not require('git.features.syntax_highlight').is_pending(ui.right)
  end, 1), 'collected preview highlighting did not finish')
  local rows, seen = {}, {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(ui.right, syntax_ns, 0, -1, { details = true })) do
    if (mark[4].hl_group == 'FugitiveExtAdd' or mark[4].hl_group == 'FugitiveExtAddText') and not seen[mark[2]] then
      rows[#rows + 1], seen[mark[2]] = mark[2] + 1, true
    end
  end
  return rows
end
assert(#preview_adds() == 1, 'collected diff lost addition highlighting')
local panel_ns = vim.api.nvim_get_namespaces().git_panel_highlight
local accents = {}
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(ui.right, panel_ns, 0, -1, { details = true })) do accents[mark[4].hl_group] = true end
assert(accents.GitPanelTitle and accents.GitPanelHash and accents.GitPanelRef and accents.GitPanelLabel)
local selected_marks = vim.api.nvim_buf_get_extmarks(ui.left, panel_ns, 0, -1, { details = true })
local selected_sign = false
for _, mark in ipairs(selected_marks) do if mark[2] == selected_row - 1 and mark[4].sign_text then selected_sign = true end end
assert(selected_sign, 'collected line has no selection indicator')
local inspect_language = vim.treesitter.language.inspect
vim.treesitter.language.inspect = function(lang)
  if lang == 'lua' then error('Test syntax fallback without a Lua parser') end
  return inspect_language(lang)
end
require('git.features.syntax_highlight').refresh(ui.right)
local code_highlight = vim.api.nvim_buf_call(ui.right, function()
  return vim.fn.synIDattr(vim.fn.synID(preview_adds()[1], 2, 1), 'name')
end)
assert(code_highlight:match('^lua'), 'collected preview lost Lua syntax: ' .. code_highlight)
vim.treesitter.language.inspect = inspect_language
-- Draft text that resembles a patch remains editable prose, even after resize.
vim.api.nvim_buf_set_lines(ui.right, 3, 4, false, { 'diff --git a/draft b/draft', '@@ -0,0 +1 @@', '+draft' })
collection.collect(ui, selected_row, selected_row)
assert(vim.wait(10000, function() return #collection.patch(ui) == 0 end, 5))
assert(#preview_adds() == 0, 'cleared selection or message retained patch highlights')
collection.collect(ui, selected_row, selected_row)
assert(vim.wait(10000, function() return #collection.patch(ui) > 0 end, 5))
local colored = preview_adds()
assert(#colored == 1 and colored[1] > 8, 'preview highlights did not follow the moved separator')
vim.api.nvim_set_current_win(ui.right_win)
vim.api.nvim_buf_set_lines(ui.right, 3, 6, false, { 'from UI' })
local old_select = vim.ui.select
vim.ui.select = function(choices, _, cb) cb(choices[1]) end
vim.fn.maparg('c', 'n', false, true).callback()
vim.ui.select = old_select
assert(vim.wait(30000, function() return ui.closed end, 5), 'UI split did not finish')
assert(ug({ 'log', '-3', '--format=%s' }) == 'from UI\ncombined\nbase')
assert(ug({ 'show', 'HEAD^:part.lua' }) == 'local beta = 2')
assert(ug({ 'show', 'HEAD:part.lua' }) == 'local alpha = 1\nlocal beta = 2')
vim.cmd('tabclose!')

-- A changed HEAD invalidates the already-confirmed undo plan.
local stale_ok, stale = task(checkout_root, function() return undo.plan(checkout_root, false) end)
assert(stale_ok, stale)
cg({ 'commit', '--allow-empty', '-qm', 'new action' })
local unchanged = cg({ 'rev-parse', 'HEAD' })
local handled, rejected, reason = task(checkout_root, function() return undo.execute(stale) end)
assert(handled and rejected == nil and reason:find('changed', 1, true))
assert(cg({ 'rev-parse', 'HEAD' }) == unchanged)

for _, path in ipairs(roots) do vim.fn.delete(path, 'rf') end
print('PASS: fixup attribution, split with descendants/WIP, rebase and checkout undo/redo, collection tab lifetime')
