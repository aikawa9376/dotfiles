local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local history = require('git.features.pr_history')
local suggestions = require('git.features.pr_suggestions')
-- Public REST excerpts from qmk/qmk_firmware#26413. Four obsolete anchors
-- and the final moved anchor reproduce the reported five-comment popup.
local fixture = vim.json.decode(table.concat(vim.fn.readfile(plugin .. '/tests/fixtures/pr_history_qmk.json'), '\n'))
local before = vim.deepcopy(fixture)
local ctx = { number = 26413 }
local threads = {}
for i = #fixture, 1, -1 do
  local comment = fixture[i]
  threads[#threads + 1] = { path = comment.path, line = i == #fixture and 11 or nil, side = 'RIGHT',
    comments = { comment }, resolved = true }
end
local comments, contexts = history.thread_history(ctx, threads)
assert(vim.deep_equal(comments, fixture), 'Thread history did not order comments by creation time')
local render_comments = vim.list_slice(comments)
render_comments[#render_comments + 1] = { id = 1, path = 'unrelated.lua',
  body = 'Ordinary quoted diff\n@@ -1 +1 @@\n-do not highlight\n+unrelated prose' }
local buf, lines, rows = history.buffer({}, render_comments, 'viewer', contexts)
local content = table.concat(lines, '\n')
local count, last = 0, 0
for at, line in ipairs(lines) do
  if line:find('PR #26413', 1, true) then
    count = count + 1
    assert(line:find('✅ resolved', 1, true))
    assert(at > last and lines[at + 1] == '')
    assert(lines[at + 2] == '@zvecr · ' .. fixture[count].created_at,
      'Position / resolved context was detached from its own author and timestamp')
    assert(rows[at] == fixture[count] and rows[at + 2] == fixture[count])
    last = at + 2
  end
end
assert(count == 5 and not lines[#lines]:match('^%s*$'))
assert(content:find('-        "force_nkro": true,', 1, true), 'Deletion-only suggestion did not show removed code')
assert(content:find('-        "mousekey": false,', 1, true), 'Second obsolete deletion lost its historical source')
assert(content:find('-        "LAYOUT": {', 1, true) and content:find('+        "LAYOUT_tkl_nofrow_ansi": {', 1, true))
assert(content:find('-                {"label": "Space", "matrix": [4, 6], "x": 3.75, "y": 4, "w": 7.25},', 1, true))
assert(content:find('+                {"label": "Space", "matrix": [4, 6], "x": 3.75, "y": 4, "w": 6.25},', 1, true))
assert(content:find('@@ -12,1 +12,6 @@\n-    },', 1, true), 'Moved anchor used current L11 instead of historical L12')
local colors = {}
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace('git_pr_history'), 0, -1, { details = true })) do
  colors[mark[4].hl_group] = (colors[mark[4].hl_group] or 0) + 1
end
assert(colors.GitPrPositive == 5)
assert(content:find('```suggestion\n', 1, true) and not content:find('```diff', 1, true),
  'Suggestion language was replaced with diff')
assert(vim.bo[buf].filetype == 'markdown')
local syntax = require('git.features.syntax_highlight')
local function marks()
  assert(vim.wait(10000, function() return not syntax.is_pending(buf) end, 1))
  return vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace('git_extension_syntax'), 0, -1, { details = true })
end
local unrelated
for row, line in ipairs(lines) do if line == 'Ordinary quoted diff' then unrelated = row end end
colors = {}
for _, mark in ipairs(marks()) do
  colors[mark[4].hl_group or ''] = true
  assert(mark[2] + 1 < unrelated, 'Shared highlighter decorated unrelated comment prose')
end
assert(colors.GitExtSyntaxDelete and colors.GitExtSyntaxAdd, 'Suggestion did not use the shared highlighter')
syntax.set_word_diff_style('delta')
colors = {}
for _, mark in ipairs(marks()) do colors[mark[4].hl_group or ''] = true end
assert(colors.GitExtDelete and colors.GitExtAdd and colors.GitExtAddText, 'Suggestion did not follow the shared diff style')
syntax.set_word_diff_style('treesitter')
assert(vim.deep_equal(fixture, before), 'Display rewrote the comment bodies or coordinates')
vim.api.nvim_buf_delete(buf, { force = true })
-- Reply IDs need not follow creation order. Context follows each comment,
-- including interleaved replies, while ordinary timeline input remains intact.
threads = {
  { path = 'first', resolved = true, comments = {
    { id = 900, created_at = '2026-01-01T00:00:00Z', body = 'root' },
    { id = 2, created_at = '2026-01-03T00:00:00Z', body = 'reply' },
  } },
  { path = 'second', resolved = false, comments = {
    { id = 3, created_at = '2026-01-02T00:00:00Z', body = 'middle' },
  } },
}
comments, contexts = history.thread_history(ctx, threads)
assert(comments[1].id == 900 and comments[2].id == 3 and comments[3].id == 2)
assert(contexts[comments[3]][1]:find('first (file / outdated) · ✅ resolved', 1, true))
buf, lines = history.buffer({}, { comments[3], comments[1] })
assert(table.concat(lines, '\n'):find('reply', 1, true) < table.concat(lines, '\n'):find('root', 1, true))
vim.api.nvim_buf_delete(buf, { force = true })
local function display(item) return table.concat(suggestions.display(item), '\n') end
local item = { body = 'Before\n```suggestion:-1+1\nnew\n```\nAfter', side = 'RIGHT', original_line = 3,
  diff_hunk = '@@ -1,4 +1,4 @@\n one\n two\n three\n four' }
assert(display(item) == 'Before\n```suggestion:-1+1\n@@ -2,3 +2,1 @@\n-two\n-three\n-four\n+new\n```\nAfter')
item.side, item.original_line, item.body = 'LEFT', 2, '```suggestion\nreplacement\n```'
item.diff_hunk = '@@ -1,3 +1,3 @@\n one\n-old\n+current\n three'
assert(display(item):find('-old\n+replacement', 1, true) and not display(item):find('-current', 1, true))
item.body = '```suggestion\n```\n\n```suggestion\nsecond\n```'
assert(display(item):find('-old\n```', 1, true) and display(item):find('-old\n+second', 1, true))
item.original_line = 99
assert(display(item):find('deletes selected code (original lines unavailable)', 1, true))
assert(display(item):find('```suggestion\nsecond\n```', 1, true), 'Missing source silently manufactured a removal')
item.original_line, item.body = 2, '````suggestion\n```\n````'
assert(display(item):find('````suggestion', 1, true) and display(item):find('+```', 1, true))
item.body = '```text\n```suggestion\nnot a suggestion\n```\n```'
assert(display(item) == item.body, 'An ordinary nested code block was transformed')
item.body, item.diff_hunk = '```suggestion\nx\n```', '@@ -1,3 +1,3 @@\r\n one\r\n-old\r\n+current\r\n three'
assert(display(item):find('-old\n+x', 1, true))
item.original_start_line, item.start_side = 1, 'RIGHT'
assert(display(item):find('original lines unavailable', 1, true), 'Mixed-side coordinates fabricated source lines')
local moved = vim.deepcopy(fixture[5]); moved.start_line = 11
assert(display(moved):find('@@ -12,1 +12,6 @@\n-    },', 1, true))
-- Exercise the actual header popup, focused comment actions, and reply context.
-- Its live worktree deliberately has unrelated content; the old code must
-- still come exclusively from the captured historical patch.
local f = require('helpers.pr_fixture').new()
f.comments, f.resolved = { vim.deepcopy(fixture) }, {}
for _, comment in ipairs(f.comments[1]) do
  comment.path = 'file name.txt'; f.resolved[comment.id] = true
end
local ui = require('helpers.pr_ui').new(f)
ui.open(); ui.key('gk', ui.row('M file name.txt'))
local popup = assert(vim.b[ui.buf].git_pr_preview)
assert(vim.api.nvim_get_current_buf() == ui.buf and not vim.bo[popup].modifiable)
lines = vim.api.nvim_buf_get_lines(popup, 0, -1, false)
local selected_row
for at, line in ipairs(lines) do if line == '-        "mousekey": false,' then selected_row = at end end
assert(selected_row, 'The real file-header preview did not render obsolete deletions')
local actions = require('git.features.pr_comment_actions')
local menu, selected = actions.menu, nil
actions.menu = function(_, comment) selected = comment end
ui.key('gk'); assert(vim.api.nvim_get_current_buf() == popup)
vim.api.nvim_win_set_cursor(0, { selected_row, 0 }); ui.key('gA')
actions.menu = menu
assert(selected.id == fixture[3].id and selected.body == fixture[3].body,
  'A generated deletion row selected another comment or changed its action payload')
assert(vim.api.nvim_get_current_buf() == ui.buf and not vim.api.nvim_buf_is_valid(popup))
local select = vim.ui.select
vim.ui.select = function(choices, _, callback) callback(choices[1]) end
ui.key('gc', ui.row('M file name.txt')); vim.ui.select = select
local input = vim.api.nvim_get_current_buf()
local context = assert(vim.b[input].git_pr_context)
lines = vim.api.nvim_buf_get_lines(context, 0, -1, false)
assert(lines[1]:find('✅ resolved', 1, true) and lines[3]:find(fixture[1].created_at, 1, true))
assert(table.concat(lines, '\n'):find('-        "force_nkro": true,', 1, true))
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(input, 0, -1, false), { '' }))
ui.close_draft(input)
vim.api.nvim_buf_delete(ui.buf, { force = true }); f.cleanup()
print('PASS: real QMK outdated/resolved history, interleaved context and chronological replies, historical suggestion removals/additions, ranges, missing source and action identity')
