local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local ui = require('helpers.pr_ui').new(f)
local view, async = require('git.features.pr'), require('git.features.async')
local status = require('git.features.pr_thread_status')
local function writes()
  local result = {}
  for _, call in ipairs(f.calls) do if vim.tbl_contains(call.argv, 'graphql') then
    local payload = vim.json.decode(call.opts.stdin)
    if payload.variables.input and payload.variables.input.threadId then result[#result + 1] = payload end
  end end
  return result
end
local function wait_request() ui.wait(function() return not async.busy(f.root) end) end
local function changed(fn)
  local old = view.model(ui.buf)
  fn()
  ui.wait(function() return view.model(ui.buf) ~= old and not async.busy(f.root) end)
end
local function rejected(substring)
  local count, notifications = #writes(), #f.notifications
  ui.key('gR', ui.row('+TWO')); wait_request()
  assert(#writes() == count, 'Rejected resolution wrote to GitHub')
  assert(table.concat(vim.list_slice(f.notifications, notifications + 1), '\n'):find(substring, 1, true), substring)
end
local function green_marker(row)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(ui.buf, vim.api.nvim_create_namespace('git_pr_status'),
    { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    for _, chunk in ipairs(mark[4].virt_text or {}) do
      if chunk[1] == ' ✅ 1' and chunk[2] == 'GitPrPositive' then return true end
    end
  end
  return false
end
ui.open(); ui.key('>', ui.row('M file name.txt'))
ui.wait(function() return pcall(ui.row, '+TWO') end)
local title = ui.row('PR title')
vim.api.nvim_buf_set_lines(ui.buf, title - 1, title, false, { 'Unsaved title' })
f.can_resolve = false
rejected('permission to resolve') -- permission is reread, not cached at open.
f.can_resolve = true
f.thread_anchors = { [101] = { id = 'REPLACED' } }
rejected('changed or disappeared')
f.thread_anchors = nil
f.thread_status_error = true
rejected('Thread status rejected')
f.thread_status_error = false
changed(function() ui.key('gR', ui.row('+TWO')) end)
assert(f.resolved[101] and #writes() == 1)
assert(writes()[1].query:find('resolveReviewThread', 1, true) and writes()[1].variables.input.threadId == 'THREAD101')
assert(ui.row('2 unresolved') and green_marker(ui.row('+TWO')) and green_marker(ui.row('M file name.txt')))
assert(ui.row('Unsaved title') and vim.bo[ui.buf].modified and f.pr.title == 'PR title', 'Resolution lost or published the metadata draft')
-- Preview status is explicit and colored; its own gR reopens the same thread.
ui.key('gk', ui.row('+TWO'))
local preview = assert(vim.b[ui.buf].git_pr_preview)
local lines = vim.api.nvim_buf_get_lines(preview, 0, -1, false)
assert(lines[1]:find('file name.txt:L2 (RIGHT) · ✅ resolved', 1, true) and lines[2] == '' and lines[3]:find('@reviewer', 1, true))
local colored = false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(preview, vim.api.nvim_create_namespace('git_pr_history'), 0, -1, { details = true })) do
  colored = colored or mark[4].hl_group == 'GitPrPositive'
end
assert(colored)
f.can_unresolve = false; rejected('permission to unresolve'); f.can_unresolve = true
-- Refreshing the source during rejection must not accidentally consume preview keys.
ui.key('gk', ui.row('+TWO'))
assert(vim.api.nvim_get_current_buf() == preview)
changed(function() ui.key('gR') end)
assert(not f.resolved[101] and #writes() == 2 and not vim.api.nvim_buf_is_valid(preview))
assert(writes()[2].query:find('unresolveReviewThread', 1, true) and ui.row('3 unresolved'))
-- Server failures leave the displayed state untouched and expose the real error.
f.resolve_error = true
local previous = view.model(ui.buf)
ui.key('gR', ui.row('+TWO')); wait_request()
assert(#writes() == 3 and view.model(ui.buf) == previous and not f.resolved[101])
assert(table.concat(f.notifications, '\n'):find('Resolution rejected', 1, true))
f.resolve_error = false
-- Another client already performed the intended resolution: no duplicate write.
f.resolved[101] = true
changed(function() ui.key('gR', ui.row('+TWO')) end)
assert(#writes() == 3 and view.model(ui.buf).threads[1].resolved)
-- Multiple conversations use a picker with current labels, never a bulk toggle.
local select = vim.ui.select
local selected
vim.ui.select = function(items, opts, callback)
  assert(#items == 2)
  assert(opts.format_item(items[1]):find('resolved', 1, true))
  selected = items[2].id; callback(items[2])
end
changed(function() ui.key('gR', ui.row('M file name.txt')) end)
assert(selected == 201 and f.resolved[201] and not f.resolved[301] and #writes() == 4)
vim.ui.select = select
changed(function()
  ui.source(); vim.api.nvim_win_set_cursor(0, { ui.row('+TWO'), 0 })
  ui.menu('gr'); ui.key('R')
end)
assert(not f.resolved[101] and f.resolved[201] and #writes() == 5, 'gr R did not reopen the selected source thread')
-- Draft-only threads cannot be resolved or accidentally submitted.
local count = #writes()
status.toggle(view.model(ui.buf).ctx, { { id = 901, pending = true, resolved = false } })
assert(#writes() == count and f.notifications[#f.notifications]:find('No published', 1, true))
-- A disappearing or unknown state is never guessed resolved.
f.thread_status_error = true
changed(function() view.refresh(ui.buf, true) end)
rejected('available resolution status')
assert(ui.row('unresolved: unavailable'))
vim.api.nvim_buf_delete(ui.buf, { force = true }); f.cleanup()
print('PASS: resolve/reopen, live permissions and identity, API failures, idempotence, single-thread picker, pending exclusion, green status, preview action and dirty metadata preservation')
