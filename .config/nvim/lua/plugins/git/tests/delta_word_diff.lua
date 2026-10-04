-- nvim --headless --clean -u NONE -l tests/delta_word_diff.lua
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.rtp:prepend(plugin)
local delta = require('git.features.delta_word_diff')
local fixture = vim.json.decode(table.concat(vim.fn.readfile(plugin .. '/tests/fixtures/delta_word_diff.json'), '\n'))
local failures = {}
for _, case in ipairs(fixture.cases) do
  local actual = delta.compare(case.before, case.after)
  for _, side in ipairs({ 'old', 'new' }) do
    for row, expected in ipairs(case.expected[side]) do
      local ranges = actual[side][row] or {}
      if not vim.deep_equal(ranges, expected) then
        failures[#failures + 1] = case.name .. ' ' .. side .. ' ' .. row
          .. '\n  expected ' .. vim.inspect(expected) .. '\n  actual   ' .. vim.inspect(ranges)
      end
    end
  end
end
if #failures > 0 then
  for i = 1, math.min(#failures, 20) do print(failures[i]) end
  error(#failures .. ' oracle differences')
end
-- Unchanged comparisons reuse results; no external command is involved.
local before, after = { 'foo(old)' }, { 'foo(new)' }
local cached = delta.compare(before, after)
local start = vim.uv.hrtime()
for _ = 1, 1000 do assert(delta.compare(before, after) == cached) end
print(string.format('PASS: %d cases match %s byte spans; 1000 cached comparisons %.1f ms',
  #fixture.cases, fixture.oracle, (vim.uv.hrtime() - start) / 1e6))
