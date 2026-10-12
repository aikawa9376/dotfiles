local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local ui = require('helpers.pr_ui').new(f)
local view, state, async = require('git.features.pr'), require('git.features.pr_viewed_state'), require('git.features.async')
local ns = vim.api.nvim_create_namespace('git_pr_status')
f.viewed_pages = {
  { { path = 'added.txt', viewerViewedState = 'VIEWED' }, { path = 'deleted.txt', viewerViewedState = 'UNVIEWED' } },
  { { path = 'file name.txt', viewerViewedState = 'UNVIEWED' }, { path = 'new.txt', viewerViewedState = 'DISMISSED' } },
}
dofile(plugin .. '/../../config/colorScheme.lua'); vim.api.nvim_exec_autocmds('ColorScheme', { pattern = 'git-test' })
assert(vim.api.nvim_get_hl(0, { name = 'GitPrViewedFile' }).fg == tonumber('586e75', 16))
local function press(keys) vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'xt', false) end
local function entry(path)
  for _, file in ipairs(view.model(ui.buf).entries) do if file.path == path then return file end end
  error('Missing file: ' .. path)
end
local function grey(path)
  local row = ui.row(path)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(ui.buf, ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    if mark[4].hl_group == 'GitPrViewedFile' then
      assert(mark[3] == 2 and mark[4].end_col == #vim.api.nvim_buf_get_lines(ui.buf, row - 1, row, false)[1], 'Viewed grey includes status')
      assert(mark[4].virt_text[1][2] ~= 'GitPrViewedFile', 'Viewed grey includes the existing file icon')
      return true
    end
  end
  return false
end
ui.open()
assert(ui.row('Viewed 1/4') and grey('added.txt') and not grey('file name.txt'))
assert(entry('new.txt').viewed_state == 'DISMISSED')
local requests = #f.calls
vim.api.nvim_win_set_cursor(0, { 1, 0 }); press(']u')
assert(view.entry_at(ui.buf, vim.fn.line('.')).path == 'deleted.txt')
press('2]u'); assert(view.entry_at(ui.buf, vim.fn.line('.')).path == 'new.txt')
press('[u'); assert(view.entry_at(ui.buf, vim.fn.line('.')).path == 'file name.txt')
press('[u'); assert(view.entry_at(ui.buf, vim.fn.line('.')).path == 'deleted.txt')
local first = vim.fn.line('.'); press('[u'); assert(vim.fn.line('.') == first, 'Unviewed navigation wrapped')
assert(#f.calls == requests and not f.viewed_writes, 'Navigation performed remote writes/reads')
ui.key('<', ui.row('Changes (')); vim.api.nvim_win_set_cursor(0, { 1, 0 }); press(']u')
assert(view.entry_at(ui.buf, vim.fn.line('.')).path == 'deleted.txt')
local title = ui.row('PR title')
vim.api.nvim_buf_set_lines(ui.buf, title - 1, title, false, { 'Unsaved Viewed title' })
vim.api.nvim_buf_set_lines(ui.buf, title + 1, title + 1, false, { 'Unsaved body line' })
ui.key('>', ui.row('file name.txt')); ui.wait(function() return pcall(ui.row, '+TWO') end)
assert(not f.viewed_writes and not grey('file name.txt'), 'Opening a diff marked it Viewed')
ui.key('gF', ui.row('+TWO')); ui.key('gF')
ui.wait(function() return entry('file name.txt').viewed_state == 'VIEWED' and not async.busy(f.root) end)
assert(f.viewed_writes == 1 and ui.row('Viewed 2/4') and grey('file name.txt'), 'Repeated gF duplicated the mutation')
assert(ui.row('+TWO') and ui.row('Unsaved Viewed title') and ui.row('Unsaved body line') and vim.bo[ui.buf].modified)
assert(f.pr.title == 'PR title', 'Viewed update saved metadata')
-- Only filename marks use the grey group; diff highlights and comment badges
-- still have their original colors and content.
local path_row = ui.row('file name.txt')
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(ui.buf, ns, 0, -1, { details = true })) do
  if mark[4].hl_group == 'GitPrViewedFile' then assert(view.entry_at(ui.buf, mark[2] + 1)) end
end
assert(view.entry_at(ui.buf, path_row) and ui.row('+TWO'))
ui.key('gF', ui.row('file name.txt'))
ui.wait(function() return entry('file name.txt').viewed_state == 'UNVIEWED' and not async.busy(f.root) end)
assert(f.viewed_writes == 2 and not grey('file name.txt') and ui.row('Viewed 1/4'))
ui.key('gF', ui.row('new.txt')) -- dismissed files can be reviewed again.
ui.wait(function() return entry('new.txt').viewed_state == 'VIEWED' end)
assert(f.viewed_writes == 3)
-- Failed writes leave every last-confirmed status and draft intact.
f.viewed_mutation_error = true
ui.key('gF', ui.row('file name.txt')); ui.wait(function() return not async.busy(f.root) end)
assert(entry('file name.txt').viewed_state == 'UNVIEWED' and f.viewed_writes == 3)
assert(f.notifications[#f.notifications]:find('Viewed update rejected', 1, true))
f.viewed_mutation_error = false
-- A moved PR, viewer or file state is rechecked before mutation.
for field, value in pairs({ viewed_head = f.base, viewed_base = f.head, viewed_viewer = 'other-viewer' }) do
  f[field] = value
  ui.key('gF', ui.row('file name.txt')); ui.wait(function() return not async.busy(f.root) end)
  assert(f.viewed_writes == 3, 'Stale target was marked Viewed: ' .. field)
  f[field] = nil
end
-- Refresh syncs browser/Octo changes, including invalidation after new changes.
f.viewed_pages[2][1].viewerViewedState = 'DISMISSED'
view.refresh(ui.buf, false, true); ui.loaded()
assert(entry('file name.txt').viewed_state == 'DISMISSED' and not grey('file name.txt'))
f.viewed_error = true
view.refresh(ui.buf, false, true); ui.loaded()
assert(view.model(ui.buf).viewed_error and ui.row('Viewed unavailable') and not grey('added.txt'), 'Failed reads retained old viewed state')
ui.key('gF', ui.row('file name.txt')); press(']u'); assert(f.viewed_writes == 3)
assert(ui.row('Unsaved Viewed title') and ui.row('Unsaved body line') and ui.row('+TWO'))
f.viewed_error = false
view.refresh(ui.buf, false, true); ui.loaded()
-- A mutation can finish after the originating view closes without reopening it.
f.delay = 30
ui.key('gF', ui.row('file name.txt')); local closing = ui.buf
vim.api.nvim_buf_delete(closing, { force = true })
ui.wait(function() return not async.busy(f.root) end)
assert(f.viewed_writes == 4 and not vim.api.nvim_buf_is_valid(closing))
ui.open(); assert(entry('file name.txt').viewed_state == 'VIEWED')
-- Malformed pagination is isolated from otherwise usable PR diffs.
f.viewed_page_info = { hasNextPage = true, endCursor = '1' }
view.refresh(ui.buf, false, true); ui.loaded()
assert(view.model(ui.buf).viewed_error:find('invalid file', 1, true) and #view.model(ui.buf).entries == 4)
vim.api.nvim_buf_delete(ui.buf, { force = true }); f.cleanup()
print('PASS: paginated Viewed synchronization, filename-only grey, progress, navigation, explicit toggles, drafts, invalidation, failed reads/writes, stale targets and closed-view safety')
