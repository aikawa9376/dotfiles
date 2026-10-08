-- nvim --headless --clean -u NONE -l tests/syntax_full_file_context.lua
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.rtp:prepend(plugin)
vim.opt.rtp:append(vim.fn.stdpath('data') .. '/site')
vim.opt.rtp:prepend(vim.fn.stdpath('data') .. '/lazy/nvim-treesitter/runtime')
local syntax = require('git.features.syntax_highlight')
local structural = require('git.features.syntax_word_diff')
local ns = vim.api.nvim_create_namespace('git_extension_syntax')
local fixture = vim.json.decode(table.concat(vim.fn.readfile(plugin .. '/tests/fixtures/difftastic_word_diff.json'), '\n'))
local function settle(buf)
  assert(vim.wait(15000, function() return not syntax.is_pending(buf) end, 1), 'complete-file comparison did not finish')
end
local function mask(ranges, line)
  local result, previous = {}, nil
  for _, range in ipairs(ranges or {}) do
    for col = range[1], math.min(range[2], #line) do result[col] = true end
  end
  for col = 1, #line do
    if result[col] then
      if previous and line:sub(previous + 1, col - 1):match('^%s*$') then
        for gap = previous + 1, col - 1 do result[gap] = true end
      end
      previous = col
    end
  end
  return result
end
local function check(case, buf)
  local text_mode = case.language:match('^Text') ~= nil
  local patch = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local rows, positions, hunks = {}, {}, 0
  for row, line in ipairs(patch) do
    local old, new = line:match('^@@ %-(%d+)[^+]*%+(%d+)')
    if old then
      positions, hunks = { old = tonumber(old), new = tonumber(new) }, hunks + 1
    elseif line:match('^[ +-]') then
      for _, side in ipairs({ 'old', 'new' }) do
        if line:sub(1, 1) == ' ' or line:sub(1, 1) == (side == 'old' and '-' or '+') then
          if line:sub(1, 1) ~= ' ' then rows[row - 1] = { side = side, source = positions[side], line = line:sub(2), spans = {}, emphasis = {} } end
          positions[side] = positions[side] + 1
        end
      end
    end
  end
  local spinner = false
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local details, target = mark[4], rows[mark[2]]
    spinner = spinner or details.virt_text_pos == 'eol'
    if (details.hl_group or ''):match('^GitExtSyntax') then
      assert(target and not details.hl_eol and details.end_row == mark[2], 'background escaped displayed changed source bytes')
      local spans = details.hl_group:match('Text$') and target.emphasis or target.spans
      spans[#spans + 1] = { mark[3], details.end_col - 1 }
    end
  end
  for _, target in pairs(rows) do
    local expected = text_mode and case.emphasis or case.expected
    assert(vim.deep_equal(mask(target.spans, target.line), mask(expected[target.side][target.source], target.line)),
      case.name .. ' background differs from native at ' .. target.side .. ':' .. target.source .. ': ' .. target.line)
    local emphasis = text_mode and {} or case.emphasis[target.side][target.source]
    assert(vim.deep_equal(mask(target.emphasis, target.line), mask(emphasis, target.line)),
      case.name .. ' emphasis differs from native at ' .. target.side .. ':' .. target.source)
  end
  assert(not spinner, 'finished complete-file comparison kept the loading icon')
  return hunks
end
local counts = { parses = 0, compares = 0, fallbacks = 0, marks = 0 }
local parser, compare, fallback, setmark = vim.treesitter.get_string_parser, structural.compare, structural.text_fallback, vim.api.nvim_buf_set_extmark
vim.treesitter.get_string_parser = function(...) counts.parses = counts.parses + 1; return parser(...) end
structural.text_fallback = function(...) counts.fallbacks = counts.fallbacks + 1; return fallback(...) end
vim.api.nvim_buf_set_extmark = function(...) counts.marks = counts.marks + 1; return setmark(...) end
vim.system = function() error('complete-file renderer spawned an external command') end
local checked = 0
for _, case in ipairs(fixture.cases) do
  if not case.force_text then
    structural.compare = function(old, new, options)
      counts.compares = counts.compares + 1
      assert(vim.deep_equal(old.lines, case.before) and vim.deep_equal(new.lines, case.after),
        case.name .. ' compared an incomplete source pair')
      local stats = {}
      options.stats = stats
      local result = compare(old, new, options)
      if case.name == 'complete_highlight_rewrite.lua' then
        assert(stats.searches >= 8 and stats.largest_region <= 256,
          'nested edits merged into a whole-function graph: ' .. vim.inspect(stats))
      elseif case.name == 'complete_compare_body.lua' then
        assert(stats.searches <= 4 and stats.largest_region < 900 and stats.one_sided_regions >= 1,
          'shrinking discarded unchanged function anchors: ' .. vim.inspect(stats))
      elseif case.name == 'complete_pure_addition.lua' or case.name == 'complete_pure_deletion.lua' then
        assert((stats.searches or 0) == 0 and stats.one_sided_regions == 1,
          'one-sided syntax still searched for a counterpart: ' .. vim.inspect(stats))
      end
      return result
    end
    local lines = { 'M ' .. case.name }
    if case.patch then
      vim.list_extend(lines, case.patch)
    else
      lines[#lines + 1] = ('@@ -%d,%d +%d,%d @@'):format(#case.before == 0 and 0 or 1, #case.before, #case.after == 0 and 0 or 1, #case.after)
      for _, line in ipairs(case.before) do lines[#lines + 1] = '-' .. line end
      for _, line in ipairs(case.after) do lines[#lines + 1] = '+' .. line end
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local spec = { old = { text = table.concat(case.before, '\n') .. (#case.before > 0 and '\n' or '') },
      new = { text = table.concat(case.after, '\n') .. (#case.after > 0 and '\n' or '') } }
    local before = vim.deepcopy(counts)
    syntax.attach(buf, { diff_source = function() return spec end })
    assert(vim.deep_equal(counts.parses, before.parses) and counts.compares == before.compares,
      'cold complete-file attach blocked on analysis')
    settle(buf)
    local hunks = check(case, buf)
    assert(counts.compares == before.compares + 1, 'complete-file comparison was duplicated across hunks')
    if case.name == 'complete_pending_display.lua' then assert(hunks >= 3, 'reported diff did not exercise separate hunks') end
    local warm = vim.deepcopy(counts)
    for _ = 1, 50 do syntax.refresh(buf) end
    assert(vim.deep_equal(counts, warm), 'unchanged complete-file comparison recomputed or repainted')
    -- Losing the coloring query must retain complete-file correspondence and
    -- reuse its result, rather than falling back to contextless word matching.
    local get_query = vim.treesitter.query.get
    vim.treesitter.query.get = function() return nil end
    syntax.refresh(buf); settle(buf); check(case, buf)
    assert(counts.compares == warm.compares and counts.fallbacks == warm.fallbacks, 'query loss recomputed file comparison')
    vim.treesitter.query.get = get_query
    vim.api.nvim_buf_delete(buf, { force = true })
    checked = checked + 1
  end
end
assert(checked >= 140 and counts.fallbacks >= 2)
print(('PASS: %d native complete-file cases including the reported Lua patch, malformed JSON and Markdown; shared comparisons, warm caches, missing queries, no subprocesses'):format(checked))
