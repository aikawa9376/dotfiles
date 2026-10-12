local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local data = vim.fn.stdpath('data')
vim.opt.rtp:prepend(data .. '/lazy/render-markdown.nvim')
vim.opt.rtp:prepend(data .. '/lazy/nvim-treesitter/runtime')
vim.opt.rtp:prepend(data .. '/site')
local renderer = require('render-markdown')
local spec = dofile(plugin .. '/../render_markdown.lua')
renderer.setup(vim.tbl_deep_extend('force', spec.opts, { debounce = 0, render_modes = true,
  completions = { lsp = { enabled = false }, blink = { enabled = false } } }))
vim.cmd('runtime plugin/render-markdown.lua')
vim.o.columns, vim.o.lines = 150, 60
local f = require('helpers.pr_fixture').new()
local ui = require('helpers.pr_ui').new(f)
local view, markdown = require('git.features.pr'), require('git.features.pr_markdown')
f.pr.title = '# Editable title stays raw'
f.pr.body = '**Editable description**\n[Description link](https://example.test/description)'
f.discussion = {
  { id = 1, user = { login = 'reviewer' }, created_at = '2026-10-12T01:00:00Z',
    body = '# Heading\n\n**Bold** and [a link](https://example.test)\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n```lua\nlocal value = 1\n```' },
  { id = 2, user = { login = f.viewer }, created_at = '2026-10-12T01:00:01Z',
    body = '# Own heading\n\n> Quoted text\n\n[a link](https://example.test/own)' },
  { id = 3, user = { login = 'reviewer' }, created_at = '2026-10-12T01:00:02Z', body = '```lua\nunterminated fence' },
  { id = 4, user = { login = 'reviewer' }, created_at = '2026-10-12T01:00:03Z', body = '# Independent heading' },
}
local ns = vim.api.nvim_create_namespace('render-markdown.nvim')
local function marks() return vim.api.nvim_buf_get_extmarks(ui.buf, ns, 0, -1, { details = true }) end
local function settle() vim.wait(120, function() return false end, 5) end
local function bounded(count)
  local ranges = vim.b[ui.buf].git_pr_markdown_ranges
  assert(#ranges == (count or 5), 'Markdown did not retain independent description/comment bodies')
  for _, mark in ipairs(marks()) do
    local last = mark[4].end_row or mark[2]
    if mark[4].end_col == 0 and last > mark[2] then last = last - 1 end
    local inside = false
    for _, range in ipairs(ranges) do inside = inside or (mark[2] >= range[1] and last < range[2]) end
    assert(inside, 'Markdown leaked outside a description/comment body: ' .. vim.inspect(mark))
  end
end
ui.open()
assert(markdown.active(ui.buf) and vim.bo[ui.buf].filetype == 'gitpr' and vim.bo[ui.buf].syntax == 'git',
  vim.inspect({ active = markdown.active(ui.buf), ft = vim.bo[ui.buf].filetype, syntax = vim.bo[ui.buf].syntax }))
settle(); assert(#marks() > 0, 'Description did not render with Conversation collapsed'); bounded(1)
assert(vim.b[ui.buf].git_pr_markdown_ranges[1][1] == ui.row('**Editable description**') - 1,
  'Markdown includes editable title or instruction heading')
ui.key('>', ui.row('Conversation ('))
vim.api.nvim_win_set_height(0, 40)
renderer.render({ buf = ui.buf }); settle()
assert(#marks() > 0, 'The actual renderer did not produce Conversation marks')
bounded()
local heading, code, link, table_mark = false, false, false, false
for _, mark in ipairs(marks()) do
  local opts = vim.inspect(mark[4])
  heading = heading or opts:find('RenderMarkdownH1', 1, true)
  code = code or opts:find('RenderMarkdownCode', 1, true)
  link = link or opts:find('RenderMarkdownLink', 1, true)
  table_mark = table_mark or opts:find('RenderMarkdownTable', 1, true)
end
assert(heading and code and link and table_mark, 'Heading/code/link/table rendering is missing')
assert(vim.bo[ui.buf].syntax == 'git' and not vim.bo[ui.buf].modified)
assert(vim.api.nvim_buf_get_lines(ui.buf, ui.row('**Bold**') - 1, ui.row('**Bold**'), false)[1]:find('**Bold**', 1, true))
-- Native Git Vim syntax must survive renderer refreshes, not merely retain the
-- syntax option's name after its compiled groups have been cleared.
vim.api.nvim_buf_call(ui.buf, function() vim.cmd([[syntax match GitPrNativeSentinel /file name\.txt/]]) end)
local function native_syntax()
  local row = ui.row('M file name.txt')
  return vim.fn.synIDattr(vim.fn.synID(row, 3, 1), 'name')
end
assert(native_syntax() == 'GitPrNativeSentinel')
-- The unclosed code fence in one comment cannot swallow the next author's
-- comment: every body is its own LanguageTree region.
local parser = vim.treesitter.get_parser(ui.buf)
parser:parse(true)
assert(vim.tbl_count(parser:trees()) == 5, 'Description/comments were combined into one Markdown document')
-- Growing an editable description moves all body regions while retaining raw
-- text, body routing, native diff syntax and the title's own highlight.
local title = ui.row('# Editable title stays raw')
vim.api.nvim_buf_set_lines(ui.buf, title + 1, title + 1, false, { 'More description text', 'Another line' })
settle(); bounded()
assert(native_syntax() == 'GitPrNativeSentinel', 'Markdown cleared compiled native diff syntax')
assert(ui.row('# Editable title stays raw') and ui.row('**Editable description**') and vim.bo[ui.buf].modified)
assert(view.conversation_at(ui.buf, ui.row('local value = 1')).key == 'comment:1')
ui.key('<', 1); settle(); bounded()
ui.key('>', 1); settle(); bounded()
ui.key('<', ui.row('Conversation (')); settle()
bounded(1)
vim.api.nvim_win_set_cursor(0, { ui.row('**Editable description**'), 0 })
renderer.render({ buf = ui.buf }); settle()
assert(#marks() > 0, 'Closing Conversation also removed description rendering')
ui.key('>', ui.row('Conversation (')); settle(); assert(#marks() > 0); bounded()
local original = vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false)
renderer.disable(); settle(); assert(#marks() == 0, 'Global Markdown toggle did not disable PR rendering')
renderer.enable(); settle(); assert(#marks() > 0); bounded()
assert(vim.deep_equal(original, vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false)), 'Rendering changed the stored conversation/metadata text')
-- Markdown decorations cannot become part of saved metadata. An empty or
-- unterminated editable description must never parse the surrounding panel.
vim.cmd('write'); ui.loaded()
assert(f.pr.title == '# Editable title stays raw' and f.pr.body ==
  'More description text\nAnother line\n**Editable description**\n[Description link](https://example.test/description)')
assert(not vim.bo[ui.buf].modified)
ui.key('<', ui.row('Conversation ('))
local first = ui.row('# Editable title stays raw') + 1
local last = vim.b[ui.buf].git_pr_markdown_ranges[1][2]
vim.api.nvim_buf_set_lines(ui.buf, first, last, false, {})
settle(); bounded(0); assert(#marks() == 0, 'Empty description rendered other sections')
vim.api.nvim_buf_set_lines(ui.buf, first, first, false, { '```lua', 'local description = 1' })
settle(); bounded(1)
ui.key('>', ui.row('Conversation (')); settle(); bounded()
parser:parse(true)
assert(vim.tbl_count(parser:trees()) == 5, 'Description fence swallowed Conversation')
-- Closing with queued renderer work cannot repaint a deleted PR buffer.
renderer.render({ buf = ui.buf })
local closed = ui.buf
vim.api.nvim_buf_delete(closed, { force = true }); settle()
assert(not vim.api.nvim_buf_is_valid(closed))
-- A PR replacement restores the renderer's local conceal settings rather than
-- leaking them into an ordinary source editing window.
ui.open(); local source = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(source)
assert(vim.wo.conceallevel == vim.go.conceallevel and vim.wo.concealcursor == vim.go.concealcursor)
vim.api.nvim_buf_delete(ui.buf, { force = true })
f.cleanup()
print('PASS: actual optional render-markdown, isolated description/comments, headings/tables/links/code, raw title and save, draft shifts/empty/fences/folds, global toggle and closed-view cleanup')
