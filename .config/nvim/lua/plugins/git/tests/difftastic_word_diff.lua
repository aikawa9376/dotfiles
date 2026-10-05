-- nvim --headless --clean -u NONE -l tests/difftastic_word_diff.lua
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.rtp:prepend(plugin)
vim.opt.rtp:append(vim.fn.stdpath('data') .. '/site')
vim.opt.rtp:prepend(vim.fn.stdpath('data') .. '/lazy/nvim-treesitter/runtime')
local structural = require('git.features.syntax_word_diff')
local fixture = vim.json.decode(table.concat(vim.fn.readfile(plugin .. '/tests/fixtures/difftastic_word_diff.json'), '\n'))

-- Normalize the view's deliberate whitespace bridges, clipping native EOF
-- positions to real bytes. Unchanged non-whitespace may never be bridged.
local function mask(ranges, line)
  local bytes = {}
  for _, range in ipairs(ranges or {}) do
    for col = range[1], math.min(range[2], #line) do bytes[col] = true end
  end
  local previous
  for col = 1, #line do
    if bytes[col] then
      if previous and line:sub(previous + 1, col - 1):match('^%s*$') then
        for gap = previous + 1, col - 1 do bytes[gap] = true end
      end
      previous = col
    end
  end
  return bytes
end
local failures, compared, fallback, rendered, recovered = {}, 0, 0, 0, 0
local syntax = require('git.features.syntax_highlight')
local function settle(buf)
  assert(vim.wait(60000, function() return not syntax.is_pending(buf) end, 1), 'highlight preparation did not finish')
end
local ns = vim.api.nvim_create_namespace('fugitive_extension_syntax')
local buffers = {}
local function check(case, actual, projection)
  for _, side in ipairs({ 'old', 'new' }) do
    local lines = side == 'old' and case.before or case.after
    for row, line in ipairs(lines) do
      if not projection or projection[side][row] then
        for _, level in ipairs({ 'expected', 'emphasis' }) do
          local spans = level == 'expected' and actual[side] or actual.emphasis[side]
          if not vim.deep_equal(mask(spans[row], line), mask(case[level][side][row], line)) then
            failures[#failures + 1] = case.name .. ' ' .. side .. ' row ' .. row .. ' ' .. level
              .. (projection and ' rendered' or '')
              .. '\n  expected ' .. vim.inspect(case[level][side][row])
              .. '\n  actual   ' .. vim.inspect(spans[row] or {})
          end
        end
      end
    end
  end
end
local function rendered_spans(buf, projection)
  local actual = { old = {}, new = {}, emphasis = { old = {}, new = {} } }
  local lookup = {}
  for _, side in ipairs({ 'old', 'new' }) do
    for row, displayed in ipairs(projection[side]) do if displayed then lookup[displayed - 1] = { side, row } end end
  end
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local target, details = lookup[mark[2]], mark[4]
    if target then
      if details.virt_text then assert(details.virt_text[1][1] == '▏') end
      local side, row = unpack(target)
      local groups = side == 'old' and { 'FugitiveExtSyntaxDelete', 'FugitiveExtSyntaxDeleteText' }
        or { 'FugitiveExtSyntaxAdd', 'FugitiveExtSyntaxAddText' }
      for level, group in ipairs(groups) do
        if details.hl_group == group then
          assert(not details.hl_eol and details.end_row == mark[2], 'whole-line background survived')
          local ranges = level == 1 and actual[side] or actual.emphasis[side]
          ranges[row] = ranges[row] or {}
          ranges[row][#ranges[row] + 1] = { mark[3], details.end_col - 1 }
          -- Strong accents also count as changed bytes when the text
          -- recovery path deliberately omits its whole-line base.
          if level == 2 then
            actual[side][row] = actual[side][row] or {}
            actual[side][row][#actual[side][row] + 1] = { mark[3], details.end_col - 1 }
          end
        end
      end
    end
  end
  return actual
end
local system = vim.system
vim.system = function() error('structural diff spawned an external command') end
for _, case in ipairs(fixture.cases) do
  local ft = vim.filetype.match({ filename = case.name })
  local lang = vim.treesitter.language.get_lang(ft)
  assert(lang and pcall(vim.treesitter.language.inspect, lang), 'install the ' .. tostring(lang) .. ' parser')
  local old, new = structural.parse(case.before, lang), structural.parse(case.after, lang)
  local actual = structural.compare(old, new)
  if case.force_text or case.language == 'Text' or case.language:find('parse errors', 1, true) then
    if not case.force_text then assert(not actual, case.name .. ': reference parse-error fallback was lost') end
    actual = structural.text_compare(case.before, case.after)
    fallback = fallback + 1
  elseif not actual then
    failures[#failures + 1] = case.name .. ': structural comparison fell back'
  else
    compared = compared + 1
    assert(structural.compare(old, new) == actual, 'comparison cache lost identity')
  end
  if actual then check(case, actual) end
  if case.force_text or case.language == 'Text' or case.language:find('parse errors', 1, true) then
    -- Native correspondence is preserved, while the view intentionally
    -- demotes text-mode NovelWord accents (including word-limit fallback).
    local expected = {
      name = case.name .. ' recovered', before = case.before, after = case.after,
      expected = case.emphasis, emphasis = { old = {}, new = {} },
    }
    local projection, patch = { old = {}, new = {} }, { 'M ' .. case.name, '@@ -1 +1 @@' }
    for _, side in ipairs({ 'old', 'new' }) do
      for row, line in ipairs(side == 'old' and case.before or case.after) do
        patch[#patch + 1] = (side == 'old' and '-' or '+') .. line
        projection[side][row] = #patch
      end
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, patch)
    local compare_async = structural.compare_async
    if case.language ~= 'Text' or lang ~= 'markdown' then
      structural.compare_async = function() return nil, false end
    end
    syntax.attach(buf)
    settle(buf)
    check(expected, rendered_spans(buf, projection), projection)
    syntax.refresh(buf)
    settle(buf)
    check(expected, rendered_spans(buf, projection), projection)
    structural.compare_async = compare_async
    vim.api.nvim_buf_delete(buf, { force = true })
    recovered = recovered + 1
  end
  if case.render_patch then
    local buf = buffers[case.render_patch]
    if not buf then
      buf = vim.api.nvim_create_buf(false, true)
      buffers[case.render_patch] = buf
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, fixture.patches[case.render_patch])
      syntax.attach(buf)
    settle(buf)
    end
    local rendered_case = case
    if case.language == 'Text' then
      rendered_case = vim.tbl_extend('force', case, { expected = case.emphasis, emphasis = { old = {}, new = {} } })
    end
    check(rendered_case, rendered_spans(buf, case.projection), case.projection)
    local get_parser, parses = vim.treesitter.get_string_parser, 0
    vim.treesitter.get_string_parser = function(...)
      parses = parses + 1
      return get_parser(...)
    end
    syntax.refresh(buf)
    settle(buf)
    vim.treesitter.get_string_parser = get_parser
    assert(parses == 0, case.name .. ': recovered fragments evicted full hunk or reparsed on refresh')
    check(rendered_case, rendered_spans(buf, case.projection), case.projection)
    rendered = rendered + 1
  end
end
for _, buf in pairs(buffers) do vim.api.nvim_buf_delete(buf, { force = true }) end
vim.system = system
for i = 1, math.min(#failures, 15) do print(failures[i]) end
assert(#failures == 0, #failures .. ' oracle differences')
print(string.format('PASS: %d structural and %d text cases match %s; %d actual patch and %d muted text projections, cold/cached; no subprocesses',
  compared, fallback, fixture.oracle, rendered, recovered))
