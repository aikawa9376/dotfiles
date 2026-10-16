-- Run: nvim --headless --clean -u NONE -l .config/nvim/lua/plugins/rainbow-delimiters/tests/highlight.lua
-- Requires the installed rainbow-delimiters, nvim-treesitter and parsers.
local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
local data = vim.fn.stdpath('data')
vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(data .. '/site')
vim.opt.rtp:prepend(data .. '/lazy/nvim-treesitter/runtime')
vim.opt.rtp:prepend(data .. '/lazy/rainbow-delimiters.nvim')
local spec = dofile(root .. '/init.lua')
spec.config(spec, spec.opts)
-- Run the same regression against upstream with RAINBOW_BASELINE=1.
if vim.env.RAINBOW_BASELINE == '1' then
  vim.g.rainbow_delimiters = { strategy = { [''] = 'rainbow-delimiters.strategy.global' } }
end
vim.cmd('runtime plugin/rainbow-delimiters.lua')
local lib = require('rainbow-delimiters.lib')

local function settle(buf)
  vim.treesitter.get_parser(buf):parse(true)
  vim.wait(40, function() return false end, 5)
end

local function create(lines, ft)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft
  vim.treesitter.start(buf)
  if not lib.buffers[buf] then lib.attach(buf) end
  settle(buf)
  return buf
end

local function marks(buf)
  local result = {}
  for lang, ns in pairs(lib.nsids) do
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      local d = mark[4]
      result[#result + 1] = table.concat({ lang, mark[2], mark[3], d.end_row, d.end_col, d.hl_group }, ':')
    end
  end
  table.sort(result)
  return result
end

local checks = 0
local function check(buf, label)
  settle(buf)
  -- Compare with a newly highlighted buffer: coordinates, colors and counts
  -- must match, including multiple injections sharing a language namespace.
  local fresh = create(vim.api.nvim_buf_get_lines(buf, 0, -1, false), vim.bo[buf].filetype)
  local expected, actual = marks(fresh), marks(buf)
  vim.api.nvim_buf_delete(fresh, { force = true })
  assert(vim.deep_equal(expected, actual), label .. '\nexpected ' .. vim.inspect(expected) .. '\nactual ' .. vim.inspect(actual))
  checks = checks + 1
end

local fixture = {
  '# Test', '', 'Plain prose without punctuation here', '', '```lua',
  "require('git').setup({ files = {", "  ['README.md'] = { 'My project' },", '} })',
  '```', '', 'Plain words below the code', '', 'End',
  '', '```lua', 'local other = { nested = { 1, 2 } }', '```',
}
local shifted = vim.list_extend({ '# New heading', '', 'New prose', '', 'More prose', '' }, fixture)
local buf = create(fixture, 'markdown')
local parser = vim.treesitter.get_parser(buf)
local highlighter = vim.treesitter.highlighter.active[buf]
assert(#marks(buf) > 12, 'fixture must highlight both Lua blocks')
check(buf, 'initial')

-- Other decorations, other buffers and the shared parser survive cleanup.
local foreign = vim.api.nvim_create_namespace('rainbow-regression-foreign')
local foreign_id = vim.api.nvim_buf_set_extmark(buf, foreign, 0, 0, { end_col = 1, hl_group = 'ErrorMsg' })
local other = create({ 'local value = { nested = { 1 } }' }, 'lua')
local other_marks = marks(other)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, shifted)
check(buf, 'whole-buffer replacement')
assert(vim.api.nvim_buf_get_extmark_by_id(buf, foreign, foreign_id, {})[1], 'foreign mark removed')
assert(vim.deep_equal(other_marks, marks(other)), 'another buffer changed')
assert(vim.treesitter.get_parser(buf) == parser, 'shared parser replaced')
assert(vim.treesitter.highlighter.active[buf] == highlighter, 'syntax highlighter replaced')

-- Reload through the real file lifecycle, not a simulated callback.
local path = vim.fn.tempname() .. '.md'
vim.fn.writefile(fixture, path)
vim.cmd.edit(path)
local disk = vim.api.nvim_get_current_buf()
vim.bo[disk].filetype = 'markdown'
vim.treesitter.start(disk)
if not lib.buffers[disk] then lib.attach(disk) end
check(disk, 'file initial')
vim.fn.writefile(shifted, path)
vim.cmd.checktime()
check(disk, 'external checktime reload')
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(disk, 0, -1, false), shifted), 'checktime did not reload')
assert(not vim.bo[disk].modified, 'reload marked file modified')
vim.fn.writefile(fixture, path)
vim.cmd('edit!')
check(disk, 'edit reload')

-- Ordinary edits must keep the incremental path: the untouched second code
-- block retains its extmark IDs when the first block changes internally.
local function second_ids()
  return vim.api.nvim_buf_get_extmarks(disk, lib.nsids.lua, { 15, 0 }, { 15, -1 }, {})
end
local ids = second_ids()
assert(#ids > 0, 'second code block has no delimiters')
vim.api.nvim_buf_set_text(disk, 5, 9, 5, 12, { 'app' })
check(disk, 'normal code edit')
assert(vim.deep_equal(ids, second_ids()), 'ordinary edit unnecessarily repainted another injection')
vim.api.nvim_buf_set_lines(disk, 4, 4, false, { 'One line', 'Two lines' })
check(disk, 'insert before injection')
vim.api.nvim_buf_set_lines(disk, 4, 6, false, {})
check(disk, 'delete before injection')
vim.api.nvim_buf_set_lines(disk, 4, 5, false, { '```text' })
check(disk, 'injection becomes plain text; other Lua injection remains')
vim.api.nvim_buf_set_lines(disk, 4, 5, false, { '```lua' })
check(disk, 'injection returns')
vim.api.nvim_buf_set_lines(disk, 4, 9, false, {})
check(disk, 'remove one injection')
vim.api.nvim_buf_set_lines(disk, 9, 12, false, {})
check(disk, 'remove final injection')
assert(#marks(disk) == 0, 'removed injections left marks')

for ft, lines in pairs({
  lua = { 'local value = { nested = { 1, 2 } }' },
  json = { '{ "value": [1, { "nested": 2 }] }' },
}) do
  local code = create(lines, ft)
  assert(#marks(code) > 0, ft .. ' needs real delimiter marks')
  vim.api.nvim_buf_set_lines(code, 0, -1, false, vim.list_extend({ '', '' }, lines))
  check(code, ft .. ' full replacement')
  vim.api.nvim_buf_set_lines(code, 0, -1, false, { '' })
  check(code, ft .. ' empty replacement')
  vim.api.nvim_buf_delete(code, { force = true })
end

-- A queued repaint must never resurrect a detached/unloaded buffer.
local strategy = lib.buffers[other].strategy
strategy.on_reset(other, lib.buffers[other])
require('rainbow-delimiters').disable(other)
vim.wait(40, function() return false end, 5)
assert(#marks(other) == 0 and lib.buffers[other] == false, 'disabled buffer repainted')
vim.api.nvim_buf_set_lines(buf, 0, -1, false, fixture)
vim.api.nvim_buf_delete(buf, { force = true })
vim.wait(40, function() return false end, 5)
assert(not vim.api.nvim_buf_is_valid(buf), 'deleted buffer resurrected')

vim.api.nvim_buf_delete(disk, { force = true })
vim.api.nvim_buf_delete(other, { force = true })
vim.fn.delete(path)
print(('rainbow delimiters: %d rendering checks passed'):format(checks))
