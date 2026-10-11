local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local ui = require('helpers.pr_ui').new(f)
-- Match the configured save shortcut, including its unchanged-buffer behavior.
vim.g.mapleader = ' '
vim.keymap.set('n', '<Leader>w', '<cmd>update<CR>')
local view = require('git.features.pr')
local pending = { id = 88, node_id = 'REVIEW88', commit_id = f.head, state = 'PENDING', body = '',
  user = { login = f.viewer }, comments = {} }
local function add(id, fields)
  local c = vim.tbl_extend('force', { id = id, body = 'Draft ' .. id, user = { login = f.viewer },
    path = 'file name.txt', line = vim.NIL, start_line = vim.NIL, original_line = 2, side = 'RIGHT',
    commit_id = f.head, original_commit_id = f.head, subject_type = 'line' }, fields or {})
  pending.comments[#pending.comments + 1] = c
  return c
end
add(601)
add(602, { original_line = 3, original_start_line = 2 })
add(603, { path = 'new.txt', subject_type = 'file', original_line = vim.NIL })
add(604, { side = 'LEFT' })
add(605, { in_reply_to_id = 101, line = 2 })
add(606, { path = 'added.txt', in_reply_to_id = 999999, original_line = 1 })
add(607, { original_commit_id = f.base })
add(608, { path = 'absent.lua', original_commit_id = f.base })
f.reviews = { pending }
-- Some servers also include the viewer's private comments in the public endpoint.
f.comments[2][#f.comments[2] + 1] = vim.deepcopy(pending.comments[1])
ui.open()
ui.key('>', ui.row('Changes (')); ui.wait(function() return pcall(ui.row, '+TWO') end)
local function marks(row)
  local chunks = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(ui.buf, vim.api.nvim_create_namespace('git_pr_status'),
    { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    vim.list_extend(chunks, mark[4].virt_text or {})
  end
  return chunks
end
local function badge(row, value, group)
  for _, chunk in ipairs(marks(row)) do
    if chunk[1] == value and chunk[2] == group then return true end
  end
  error('Missing badge ' .. value .. ' on row ' .. row .. ': ' .. vim.inspect(marks(row)))
end
badge(ui.row('+TWO'), ' 💬 2', 'DiagnosticInfo')
badge(ui.row('+TWO'), ' 📝 3 [pending]', 'DiagnosticWarn')
badge(ui.row('-two'), ' 💬 1', 'DiagnosticInfo')
badge(ui.row('-two'), ' 📝 1 [pending]', 'DiagnosticWarn')
badge(ui.row(' three'), ' 📝 1 [pending]', 'DiagnosticWarn')
badge(ui.row('M file name.txt'), ' 📝 5 [pending]', 'DiagnosticWarn')
badge(ui.row('new.txt'), ' 📝 1 [pending]', 'DiagnosticWarn')
badge(ui.row('+new'), ' 📝 1 [pending]', 'DiagnosticWarn')
badge(ui.row('Review threads ('), ' 📝 8 [pending]', 'DiagnosticWarn')
local model = view.model(ui.buf)
local indexed = {}
for _, thread in ipairs(model.threads) do assert(not indexed[thread.id], 'Duplicate private thread'); indexed[thread.id] = thread end
assert(indexed[601].line == 2 and indexed[602].start_line == 2 and indexed[602].line == 3)
assert(indexed[603].line == nil and indexed[607].line == nil, 'A file / stale anchor was guessed onto the current diff')
assert(indexed[606] and indexed[606].pending and indexed[606].line == 1, 'Private orphan reply was hidden')
assert(model.review.pending.comments[1].line == vim.NIL, 'Presentation fallback mutated canonical draft coordinates')
local selected
vim.ui.select = function(items, opts, callback)
  for _, item in ipairs(items) do
    if item.id == 601 then
      assert(opts.format_item(item):find('📝 [pending]', 1, true)); selected = item; callback(item); return
    end
  end
  error('Private comment missing from thread picker')
end
ui.key('gc', ui.row('+TWO'))
assert(selected and vim.bo.filetype == 'markdown')
local buf = vim.api.nvim_get_current_buf()
assert(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'):find('Draft 601', 1, true))
ui.close_draft(buf)
-- Private drafts remain visible when only the public-comment endpoint fails.
f.api_before = function(path, method) return method == 'GET' and path == 'repos/org/repo/pulls/7/comments' end
ui.refresh()
assert(view.model(ui.buf).comments_error and #view.model(ui.buf).threads == 8)
badge(ui.row('M file name.txt'), ' 📝 5 [pending]', 'DiagnosticWarn')
badge(ui.row('Review threads ('), ' 📝 8 [pending]', 'DiagnosticWarn')
f.api_before = nil; ui.refresh()
-- Existing private comments submit without writing an extra review summary.
ui.menu('gr'); ui.key('m')
buf = vim.api.nvim_get_current_buf()
assert(table.concat(vim.api.nvim_buf_get_lines(vim.b[buf].git_pr_context, 0, -1, false), '\n'):find('summary optional', 1, true))
assert(not vim.bo[buf].modified)
local calls = #f.calls
vim.api.nvim_feedkeys(' w', 'xt', false)
assert(#f.calls == calls and pending.state == 'PENDING', 'The configured save shortcut was overridden')
assert(vim.fn.maparg(' w', 'n', false, true).buffer == 0, 'Composer changed the global save shortcut')
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-s>', true, false, true), 'xt', false)
ui.wait(function() return not vim.api.nvim_buf_is_valid(buf) end); ui.loaded()
assert(pending.state == 'COMMENTED' and pending.body == '' and #pending.comments == 8)
for _, chunk in ipairs(marks(ui.row('M file name.txt'))) do
  assert(not chunk[1]:find('[pending]', 1, true), 'Submitted review kept private badges')
end
-- Approval also supports an empty summary and no inline comments.
ui.menu('gr'); ui.key('a'); buf = vim.api.nvim_get_current_buf()
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('i<C-s>', true, false, true), 'xt', false)
ui.wait(function() return not vim.api.nvim_buf_is_valid(buf) end); ui.loaded()
assert(f.last_event == 'APPROVE' and f.reviews[#f.reviews].body == '')
vim.api.nvim_buf_delete(ui.buf, { force = true }); f.cleanup()
print('PR public/private bubbles, null-line drafts, LEFT/range/file/orphan anchors and summary-free submission passed')
