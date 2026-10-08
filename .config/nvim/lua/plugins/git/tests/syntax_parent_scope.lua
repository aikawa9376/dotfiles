-- nvim --headless --clean -u NONE -l tests/syntax_parent_scope.lua
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.rtp:prepend(plugin)
vim.opt.rtp:append(vim.fn.stdpath('data') .. '/site')
vim.opt.rtp:prepend(vim.fn.stdpath('data') .. '/lazy/nvim-treesitter/runtime')
local syntax = require('git.features.syntax_highlight')
local diff = require('git.features.syntax_word_diff')
local compare = diff.compare
local old, targets = {}, {}
for index = 1, 400 do
  old[#old + 1] = ('local function ParentScope_%d(value)'):format(index)
  for part = 1, 12 do old[#old + 1] = ('  local part_%d = value + %d'):format(part, part) end
  old[#old + 1] = '  return oldValue'
  targets[index] = #old
  old[#old + 1] = 'end'; old[#old + 1] = ''
end
vim.system = function() error('parent-scope comparison spawned an external command') end
local function run(indices)
  local new = vim.deepcopy(old)
  local patch = { 'M parent_scope.lua' }
  for _, index in ipairs(indices) do
    local row = targets[index]
    new[row] = '  return newValue'
    vim.list_extend(patch, { ('@@ -%d +%d @@'):format(row, row), '-  return oldValue', '+  return newValue' })
  end
  local left, right = diff.parse(old, 'lua'), diff.parse(new, 'lua')
  local start = vim.uv.hrtime()
  local reference = assert(compare(left, right))
  local full_ms = (vim.uv.hrtime() - start) / 1e6
  local calls, scoped_ms, selected = 0, 0, nil
  diff.compare = function(a, b, options)
    calls = calls + 1
    selected = a.nodes
    local began = vim.uv.hrtime()
    local result = compare(a, b, options)
    scoped_ms = (vim.uv.hrtime() - began) / 1e6
    assert(vim.deep_equal(result, reference), 'scoping changed full-tree source ranges')
    return result
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, patch)
  syntax.attach(buf, { diff_source = function()
    return { old = { text = table.concat(old, '\n') .. '\n' }, new = { text = table.concat(new, '\n') .. '\n' } }
  end })
  assert(vim.wait(15000, function() return not syntax.is_pending(buf) end, 1), 'parent comparison did not finish')
  assert(calls == 1 and selected, 'hunks did not share a scoped comparison')
  if #indices == 1 then
    assert(#selected == 1 and selected[1]:type() == 'function_declaration', 'comparison escaped its enclosing function')
    local sr, _, er = selected[1]:range()
    assert(er - sr < 16, 'single edit included unchanged functions')
  else
    assert(#selected > 1 and #selected < 400, 'separate edits did not expand into a shared region')
    local first = selected[1]:start()
    local last = selected[#selected]:end_()
    assert(first < targets[indices[1]] and last >= targets[indices[#indices]], 'shared region omitted an edit')
  end
  local ns, added = vim.api.nvim_create_namespace('git_extension_syntax'), 0
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if mark[4].hl_group == 'GitExtSyntaxAdd' then
      assert(mark[3] == 10 and mark[4].end_col == 18, 'parent scope lost original source columns')
      added = added + 1
    end
  end
  assert(added == #indices, 'parent scope lost a displayed edit')
  for _ = 1, 50 do syntax.refresh(buf) end
  assert(calls == 1, 'warm refresh repeated parent comparison')
  vim.api.nvim_buf_delete(buf, { force = true })
  return full_ms, scoped_ms
end
local full, scoped = run({ 200 })
run({ 180, 220 })
print(('PASS: %d lines / 400 functions: whole-tree %.1f ms, enclosing-function %.1f ms; identical ranges, shared disjoint edits, original coordinates, warm reuse'):format(#old, full, scoped))
