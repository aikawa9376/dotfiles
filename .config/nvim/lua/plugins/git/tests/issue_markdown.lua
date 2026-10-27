local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local data = vim.fn.stdpath('data')
local namespace = vim.env.GIT_MARKDOWN_RENDERER or 'render-markdown'
vim.g.markdown_renderer = namespace
vim.opt.rtp:prepend(vim.env.GIT_MARKDOWN_RTP or (data .. '/lazy/' .. namespace .. '.nvim'))
vim.opt.rtp:prepend(data .. '/lazy/nvim-treesitter/runtime')
vim.opt.rtp:prepend(data .. '/site')
local renderer = require(namespace)
local spec = dofile(plugin .. (namespace == 'inkstone' and '/../inkstone.lua' or '/../render_markdown.lua'))
renderer.setup(vim.tbl_deep_extend('force', spec.opts, { debounce = 0, render_modes = true,
  completions = { lsp = { enabled = false }, blink = { enabled = false } } }))
vim.cmd('runtime plugin/' .. namespace .. '.lua')
vim.o.columns, vim.o.lines = 150, 60
local f = require('helpers.issue_fixture').new()
f.issue.title = '# Raw title'
f.issue.body = '# Body heading\n\n| A | B |\n| --- | --- |\n| x | y |\n\n```lua\nlocal value = 1\n```'
f.comments[1].body = '```lua\nunterminated fence'
f.comments[2].body = '# Independent comment\n\n[a link](https://example.test)'
local view, markdown = require('git.features.issue'), require('git.features.pr_markdown')
local buf = view.open(f.ctx)
f.wait(function() return view.model(buf) ~= nil end)
local ns = vim.api.nvim_create_namespace(namespace .. '.nvim')
local function settle() renderer.render({ buf = buf }); vim.wait(100, function() return false end, 2) end
local function bounded(count)
  local ranges = vim.b[buf].git_pr_markdown_ranges
  assert(#ranges == count, 'Issue bodies lost independent ranges')
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local last, inside = mark[4].end_row or mark[2], false
    if mark[4].end_col == 0 and last > mark[2] then last = last - 1 end
    for _, range in ipairs(ranges) do inside = inside or (mark[2] >= range[1] and last < range[2]) end
    assert(inside, 'Issue Markdown decoration escaped its body')
  end
end
settle(); assert(markdown.active(buf)); bounded(3)
local parser = vim.treesitter.get_parser(buf); parser:parse(true)
assert(vim.tbl_count(parser:trees()) == 3, 'Unclosed comment fence swallowed the next comment')
local marks = vim.inspect(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true }))
local prefix = namespace == 'inkstone' and 'Inkstone' or 'RenderMarkdown'
assert(marks:find(prefix .. 'H1', 1, true) and marks:find(prefix .. 'Code', 1, true)
  and marks:find(prefix .. 'Table', 1, true) and marks:find(prefix .. 'Link', 1, true), 'Missing real renderer decorations')
local function row(text)
  for index, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do if line == text then return index end end
  error('Missing ' .. text)
end
assert(vim.b[buf].git_pr_markdown_ranges[1][1] == row('# Body heading') - 1)
vim.api.nvim_buf_set_lines(buf, row('# Body heading'), row('# Body heading'), false, { 'Draft growth', '' })
settle(); bounded(3)
assert(view.conversation_at(buf, row('# Independent comment')).id == 11)
vim.api.nvim_win_set_cursor(0, { row('# Body heading'), 0 })
local heading
for index, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do if line:find('Conversation (', 1, true) then heading = index end end
vim.api.nvim_win_set_cursor(0, { heading, 0 })
vim.fn.maparg('<', 'n', false, true).callback()
settle(); bounded(1); assert(vim.bo[buf].modified)
view.write(buf); f.wait(function() return not vim.bo[buf].modified end)
assert(f.issue.body:find('Draft growth', 1, true) and not f.issue.body:find('Conversation (', 1, true))
vim.api.nvim_buf_delete(buf, { force = true }); f.cleanup()
print('PASS: real Issue Markdown heading/table/link/code rendering, separate fenced bodies, draft offsets, collapsed conversation and raw metadata-only save')
