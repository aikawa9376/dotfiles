local source = debug.getinfo(1, 'S').source:gsub('^@', '')
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
vim.opt.rtp:prepend(root)
package.path = root .. '/?.lua;' .. package.path
local output = assert(vim.env.LAZYAGENT_BENCH_OUT, 'set LAZYAGENT_BENCH_OUT')
local fixture = require('tests.acp.footer_animation_spec')
local hidden = {}
for i = 1, 500 do hidden[i] = vim.api.nvim_create_buf(false, true) end
local result = { frames = 200, hidden_buffers = #hidden }
local before
if vim.env.LAZYAGENT_FOOTER_BASELINE then
  vim.api.nvim_set_hl(0, 'LazyAgentACPFooterMeta', { fg = 0x778899 })
  before, result.before = fixture.exercise(assert(loadfile(vim.env.LAZYAGENT_FOOTER_BASELINE))(), false, result.frames)
end
vim.api.nvim_set_hl(0, 'LazyAgentACPFooterMeta', { fg = 0x778899 })
local after
after, result.after = fixture.exercise(require('lazyagent.acp.view_footer'), false, result.frames)
if before then
  assert(vim.deep_equal(before, after), 'before/after footer frames differ')
  result.frames_equal = true
end
for _, buf in ipairs(hidden) do vim.api.nvim_buf_delete(buf, { force = true }) end
vim.fn.writefile({ vim.json.encode(result) }, output)
