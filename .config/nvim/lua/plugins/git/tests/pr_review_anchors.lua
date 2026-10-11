local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local ui = require('helpers.pr_ui').new(f)
local view = require('git.features.pr')
f.legacy_review_coordinates = true
local pending = { id = 88, node_id = 'REVIEW88', commit_id = f.head, state = 'PENDING', body = '',
  user = { login = f.viewer }, comments = {} }
f.reviews = { pending }
f.thread_anchors = {}
local function add(id, path, anchor)
  pending.comments[#pending.comments + 1] = { id = id, path = path, body = 'Draft ' .. id,
    user = { login = f.viewer }, commit_id = f.head }
  f.thread_anchors[id] = vim.tbl_extend('force', { path = path, isOutdated = false,
    subjectType = 'LINE', diffSide = 'RIGHT', line = 2, startLine = vim.NIL }, anchor or {})
end
add(601, 'file name.txt')
add(602, 'file name.txt', { diffSide = 'LEFT' })
add(603, 'file name.txt', { line = 3, startLine = 2 })
add(604, 'new.txt', { subjectType = 'FILE', line = vim.NIL })
add(605, 'file name.txt', { isOutdated = true })
ui.open(); ui.expand_files(); ui.wait(function() return pcall(ui.row, '+TWO') end)
local function badge(row, text)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(ui.buf, vim.api.nvim_create_namespace('git_pr_status'),
    { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    for _, chunk in ipairs(mark[4].virt_text or {}) do if chunk[1] == text then return true end end
  end
  return false
end
assert(badge(ui.row('+TWO'), ' 📝 2 [pending]'), 'Missing RIGHT/range drafts with all REST coordinates absent')
assert(badge(ui.row('-two'), ' 📝 1 [pending]'), 'GraphQL LEFT draft was put on the wrong side')
assert(badge(ui.row(' three'), ' 📝 1 [pending]'), 'GraphQL range start was lost')
assert(badge(ui.row('M file name.txt'), ' 📝 4 [pending]'))
assert(badge(ui.row('new.txt'), ' 📝 1 [pending]'))
assert(not badge(ui.row('+new'), ' 📝 1 [pending]'), 'File-level draft was guessed onto a diff line')
local model = view.model(ui.buf)
assert(model.thread_status.total == 3 and model.thread_status.unresolved == 3, 'Pending threads counted as published unresolved threads')
for _, comment in ipairs(model.review.pending.comments) do
  assert(comment.line == nil and comment.original_line == nil and comment.side == nil, 'Presentation hydration changed canonical review data')
end
for _, thread in ipairs(model.threads) do if thread.id == 605 then assert(thread.line == nil, 'Outdated thread guessed onto current code') end end
-- A GraphQL read from a different head must never supply diff coordinates.
f.thread_head = f.base
ui.refresh()
assert(not badge(ui.row('+TWO'), ' 📝 2 [pending]'))
assert(badge(ui.row('M file name.txt'), ' 📝 4 [pending]'))
f.thread_head = nil; f.thread_status_error = true; ui.refresh()
assert(view.model(ui.buf).thread_status_error and badge(ui.row('M file name.txt'), ' 📝 4 [pending]'))
f.thread_status_error = false; ui.refresh()
assert(badge(ui.row('+TWO'), ' 📝 2 [pending]'))
vim.api.nvim_buf_delete(ui.buf, { force = true }); f.cleanup()
print('PASS: GraphQL review anchors recover missing REST coordinates, retain LEFT/range/file/outdated scope and reject mixed heads')
