local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local ui = require('helpers.pr_ui').new(f)
local view, reads = require('git.features.pr'), require('git.features.pr_read_state')
dofile(plugin .. '/../../config/colorScheme.lua')
vim.api.nvim_exec_autocmds('ColorScheme', { pattern = 'git-test' })
assert(vim.api.nvim_get_hl(0, { name = 'GitPrCommentSelf' }).fg == tonumber('81a1c1', 16))
f.comments[1][#f.comments[1] + 1] = { id = 103, in_reply_to_id = 101, path = 'file name.txt', side = 'RIGHT',
  line = 2, body = 'My own reply\n\n  \n', user = { login = f.viewer } }
ui.open()
local function chunks(row)
  local result = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(ui.buf, vim.api.nvim_create_namespace('git_pr_status'),
    { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    for _, chunk in ipairs(mark[4].virt_text or {}) do result[chunk[1]] = chunk[2] end
  end
  return result
end
assert(chunks(ui.row('M file name.txt'))[' 💬 2'] and chunks(ui.row('M file name.txt'))[' 🆕'])
ui.key('o', ui.row('M file name.txt')); ui.wait(function() return pcall(ui.row, '+TWO') end)
assert(chunks(ui.row('+TWO'))[' 💬 2'], 'Expanded badge counted threads / own comments instead of unread replies')
assert(chunks(ui.row('-two'))[' 💬 1'])
assert(chunks(ui.row('M file name.txt'))[' 💬 3'] and not chunks(ui.row('M file name.txt'))[' 🆕'])
-- Reading repaints badges in place even after title edits shift the diff rows.
local title = ui.row('PR title')
vim.api.nvim_buf_set_lines(ui.buf, title - 1, title, false, { 'Edited title' })
vim.api.nvim_buf_set_lines(ui.buf, title + 1, title + 1, false, { 'More description' })
local before = vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false)
local calls = #f.calls
ui.key('gc', ui.row('+TWO'))
local input = vim.api.nvim_get_current_buf()
local history = assert(vim.b[input].git_pr_history)
assert(vim.bo[history].readonly and not vim.bo[history].modifiable)
assert(not pcall(vim.api.nvim_buf_set_lines, history, 0, 1, false, { 'tampered' }), 'Conversation history was editable')
assert(vim.deep_equal(before, vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false)) and vim.bo[ui.buf].modified)
assert(#f.calls == calls, 'Marking comments read triggered a remote request')
assert(chunks(ui.row('+TWO'))[' 💬 0'] and chunks(ui.row('M file name.txt'))[' 💬 1'])
local own, other, own_author = false, false, false
local history_lines = vim.api.nvim_buf_get_lines(history, 0, -1, false)
assert(history_lines[#history_lines] == 'My own reply', 'History includes trailing blank rows')
assert(f.comments[1][#f.comments[1]].body == 'My own reply\n\n  \n', 'Display trimming changed canonical comment text')
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(history, vim.api.nvim_create_namespace('git_pr_history'), 0, -1, { details = true })) do
  own = own or mark[4].hl_group == 'GitPrCommentSelf'
  other = other or mark[4].hl_group == 'GitPrCommentOther'
  if history_lines[mark[2] + 1]:find('@viewer', 1, true) == 1 and mark[4].priority == 160 then
    own_author = true
    assert(mark[4].hl_group == 'GitPrCommentSelf', 'Own author label overrides the readable self color')
  end
end
assert(own and other and own_author, 'Conversation history did not distinguish its authors')
ui.key('<Tab>'); assert(vim.api.nvim_get_current_buf() == history)
ui.key('<Tab>'); assert(vim.api.nvim_get_current_buf() == input)
ui.close_draft(input); assert(not vim.api.nvim_buf_is_valid(history))
ui.key('<', ui.row('M file name.txt'))
assert(chunks(ui.row('M file name.txt'))[' 💬 2'] and chunks(ui.row('M file name.txt'))[' 🆕'])
-- Reading the remaining LEFT thread clears the closed-file unread indicator.
local model = view.model(ui.buf)
local left = assert(model.threads[2])
for _, thread in ipairs(model.threads) do if thread.id == 201 then left = thread end end
reads.mark(model.ctx, f.viewer, left.comments)
assert(chunks(ui.row('M file name.txt'))[' 💬 2'] and not chunks(ui.row('M file name.txt'))[' 🆕'])
-- Receipts are durable and isolated by viewer / PR / host, and detect edits.
package.loaded['git.features.pr_read_state'] = nil
reads = require('git.features.pr_read_state')
assert(not reads.unread(model.ctx, f.viewer, model.threads)[101])
assert(reads.unread(model.ctx, 'another-viewer', model.threads)[101])
assert(reads.unread(vim.tbl_extend('force', model.ctx, { number = 8 }), f.viewer, model.threads)[101])
assert(reads.unread(vim.tbl_extend('force', model.ctx, { host = 'another.example' }), f.viewer, model.threads)[101])
local changed = vim.deepcopy(model.threads[1])
changed.comments[1].body = 'Edited after reading'
assert(reads.unread(model.ctx, f.viewer, { changed })[101])
changed = vim.deepcopy(model.threads[1]); changed.comments[1].updated_at = '2026-10-11T00:00:00Z'
assert(reads.unread(model.ctx, f.viewer, { changed })[101])
assert(next(reads.unread(model.ctx, nil, model.threads)) == nil, 'Unknown viewer produced guessed unread state')
local private = { id = 999, body = 'Private', pending = true, user = { login = 'another-viewer' } }
assert(not reads.unread(model.ctx, f.viewer, { { comments = { private } } })[999])
-- A new reply after refresh is unread while the previously seen bodies stay read.
vim.api.nvim_buf_set_lines(ui.buf, title - 1, title, false, { 'PR title' })
vim.api.nvim_buf_set_lines(ui.buf, title + 1, title + 2, false, {})
f.comments[1][#f.comments[1] + 1] = { id = 104, in_reply_to_id = 101, path = 'file name.txt', side = 'RIGHT',
  line = 2, body = 'A new response', user = { login = 'reviewer' } }
ui.refresh()
assert(chunks(ui.row('M file name.txt'))[' 🆕'])
ui.key('o', ui.row('M file name.txt')); ui.wait(function() return pcall(ui.row, '+TWO') end)
assert(chunks(ui.row('+TWO'))[' 💬 1'])
ui.key('gc', ui.row('+TWO')); input = vim.api.nvim_get_current_buf(); history = vim.b[input].git_pr_history
ui.body({ 'Reply after reading' }); ui.key('<Tab>'); ui.key('<C-s>')
ui.wait(function() return not vim.api.nvim_buf_is_valid(input) end); ui.loaded()
assert(not vim.api.nvim_buf_is_valid(history), 'Submitting from history left an orphan window')
ui.key('gc', ui.row('+TWO')); input = vim.api.nvim_get_current_buf(); history = vim.b[input].git_pr_history
local win = vim.api.nvim_get_current_win()
vim.api.nvim_win_close(win, true)
assert(not vim.api.nvim_buf_is_valid(history), 'Closing input left an orphan history window')
ui.close_draft(input)
vim.api.nvim_buf_delete(ui.buf, { force = true }); f.cleanup()
print('PASS: unread reply counts, collapsed indicators, read receipts, edited/new comments, draft preservation, immutable author-colored history and cleanup')
