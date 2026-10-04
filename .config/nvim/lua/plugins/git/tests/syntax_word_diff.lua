-- nvim --headless --clean -u NONE -l tests/syntax_word_diff.lua
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.rtp:prepend(plugin)
vim.opt.rtp:append(vim.fn.stdpath('data') .. '/site')
vim.opt.rtp:prepend(vim.fn.stdpath('data') .. '/lazy/nvim-treesitter/runtime')
for _, lang in ipairs({ 'lua', 'json', 'javascript', 'python' }) do
  assert(pcall(vim.treesitter.language.inspect, lang), 'install the ' .. lang .. ' parser')
end
local syntax = require('git.features.syntax_highlight')
local tokens = require('git.features.syntax_word_diff')
local ns = vim.api.nvim_create_namespace('fugitive_extension_syntax')
local function open(name, before, after, context)
  local lines = { 'M ' .. name, '@@ -1 +1 @@' }
  for _, line in ipairs(context or {}) do lines[#lines + 1] = ' ' .. line end
  for _, line in ipairs(before) do lines[#lines + 1] = '-' .. line end
  for _, line in ipairs(after) do lines[#lines + 1] = '+' .. line end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  syntax.attach(buf)
  return buf
end
local function words(buf, side)
  local found = {}
  local group = side == 'old' and 'FugitiveExtDeleteText' or 'FugitiveExtAddText'
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if mark[4].hl_group == group then
      local line = vim.api.nvim_buf_get_lines(buf, mark[2], mark[2] + 1, false)[1]
      found[#found + 1] = line:sub(mark[3] + 1, mark[4].end_col)
    end
  end
  table.sort(found)
  return table.concat(found, '|')
end
local function expect(name, before, after, old, new)
  local buf = open(name, before, after)
  assert(words(buf, 'old') == old, name .. ' old: ' .. words(buf, 'old'))
  assert(words(buf, 'new') == new, name .. ' new: ' .. words(buf, 'new'))
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- Delta's textual path is the default; structural matching is opt-in.
assert(syntax.config.word_diff_style == 'delta', 'delta is no longer the default')
local compare = tokens.compare
tokens.compare = function() error('delta called structural word comparison') end
expect('default.lua', { 'return 1' }, { 'return 2' }, '1', '2')
tokens.compare = compare
-- EOF markers preserve physical rows without separating the old/new pair.
local eof = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(eof, 0, -1, false, {
  'M eof.lua', '@@ -1 +1 @@', '-return 1', '\\ No newline at end of file',
  '+return 2', '\\ No newline at end of file',
})
syntax.attach(eof)
assert(words(eof, 'old') == '1' and words(eof, 'new') == '2', 'EOF markers shifted word ranges')
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(eof, ns, 0, -1, { details = true })) do
  assert(mark[2] ~= 3 and mark[2] ~= 5, 'EOF marker received a source highlight')
end
vim.api.nvim_buf_delete(eof, { force = true })
for _, style in ipairs({ 'treesitter', 'github', 'diffs', 'delta' }) do
  assert(syntax.cycle_word_diff_style() == style, 'word-diff cycle missed ' .. style)
end
syntax.config.word_diff_style = 'treesitter'

-- Unpaired statements remain additions/deletions inside a mixed block.
local replaced = { '  flush_groups()', '', '  -- 3. Syntax Highlighting (Treesitter)' }
local replacement = vim.split([=[  local sources = {}
  if M.config.word_diff_style == 'treesitter' then
    for _, side in ipairs({ 'old', 'new' }) do sources[side] = syntax_word_diff.parse(code[side], hunk.lang) end
    Highlighter.apply_block_word_diffs(bufnr, ns, hunk, sources, maps, inverse)
  elseif M.config.word_diff_style == 'diffs' then
    Highlighter.apply_diffs_style_word_diffs(bufnr, ns, hunk)
  else
    -- Sequential GitHub pairing retains the existing textual word comparison.
    for _, group in ipairs(Utils.extract_change_groups(hunk.lines)) do
      local old, new, old_rows, new_rows = {}, {}, {}, {}
      for _, line in ipairs(group.del_lines) do
        old[#old + 1], old_rows[#old_rows + 1] = line.text, hunk.start_line + line.idx - 1
      end
      for _, line in ipairs(group.add_lines) do
        new[#new + 1], new_rows[#new_rows + 1] = line.text, hunk.start_line + line.idx - 1
      end
      Highlighter.apply_word_diffs(bufnr, ns, old, new, old_rows, new_rows)
    end
  end]=], '\n', { plain = true })
expect('replacement.lua', replaced, replacement, '', '')
expect('replacement_reverse.lua', replacement, replaced, '', '')
expect('mixed_replacement.lua', vim.list_extend({ 'keep(old_argument)' }, replaced),
  vim.list_extend({ 'keep(new_argument)' }, replacement), 'old_argument', 'new_argument')
expect('whole_line.lua', { 'old_call(old_argument)' }, { 'new_call(new_argument)' },
  'old_argument|old_call', 'new_argument|new_call')
expect('whole_identifier.lua', { 'very_long_old_function_name()' }, { 'very_long_new_function_name()' },
  'very_long_old_function_name', 'very_long_new_function_name')
expect('changed_argument.lua', { 'foo(', '  old_argument', ')' },
  { 'foo(', '  new_argument', ')' }, 'old_argument', 'new_argument')
expect('changed_split_argument.lua', { 'foo(old_argument)' },
  { 'foo(', '  new_argument', ')' }, 'old_argument', 'new_argument')
expect('inline_argument.lua', { 'foo(a, b)' }, { 'foo(a, b, c)' }, '', ', c')
expect('new_statement.lua', { 'foo(a)' }, { 'foo(b)', 'entirely_new(statement)' }, 'a', 'b')
expect('removed_statement.lua', { 'foo(a)', 'entirely_removed(statement)' }, { 'foo(b)' }, 'a', 'b')
expect('return.lua', { 'return 1' }, { 'return 2' }, '1', '2')
expect('new_nested.lua', { 'if flag then', '  foo(a)', 'end' },
  { 'if flag then', '  foo(b)', '  entirely_new(statement)', 'end' }, 'a', 'b')
expect('new_property.json', { '{"keep": "old"}' }, { '{', '"keep": "new",', '"added": "novel"', '}' }, 'old', ',|new')

-- Layout changes do not replace identifiers or punctuation that still exist.
expect('call.lua', { 'foo(a, b)' }, { 'foo(', '  a,', '  b,', '  c', ')' }, '', ',')
expect('join.lua', { 'foo(', '  a,', '  b,', '  c', ')' }, { 'foo(a, b)' }, ',', '')
expect('layout.lua', { 'foo(a, b)' }, { 'foo(', '  a,', '  b', ')' }, '', '')
expect('indent.lua', { 'foo(a, b)' }, { '  foo(a, b)' }, '', '')
expect('blank.lua', { '' }, { '  ' }, '', '')
expect('partial.lua', { 'function f()', '  foo(a, b)' }, { 'function f()', '  foo(', '    a,', '    b', '  )' }, '', '')
expect('attach.lua', { 'syntax_highlight.attach(b)', 'end' },
  { 'syntax_highlight.attach(b, { diff_source = function(hunk)',
    '  return status_renderer.highlight_source(b, hunk.start_line)', 'end })', 'end' }, '',
  ', { diff_source = function(hunk)|end }')
-- Changed operators are atomic syntax tokens; identifiers stay whole in UTF-8.
expect('operator.lua', { 'return a == b' }, { 'return a ~= b' }, '==', '~=')
expect('unicode.js', { 'const 日本語 = 1;' }, { 'const 日本人 = 1;' }, '日本語', '日本人')
expect('quoted.lua', { 'local s = "the old stale word"' }, { 'local s = "the new fresh word"' },
  'old stale', 'new fresh')
expect('comment.lua', { '-- the old stale word' }, { '-- the new fresh word' }, 'old stale', 'new fresh')
expect('literal_space.lua', { 'local s = "a b"' }, { 'local s = "a  b"' }, ' ', '  ')
-- Literal words must not become anchors for identifiers or property keys.
expect('roles.lua', { 'local value = "target"' }, { 'local target = "value"' },
  'target|value', 'target|value')
expect('json.json', { '{"item": "old", "keep": 1}' }, { '{', '  "item": "new",', '  "keep": 1', '}' }, 'old', 'new')
expect('key.json', { '{"old key": 1}' }, { '{"new key": 1}' }, 'old', 'new')
expect('roles.json', { '{"left": "right"}' }, { '{"right": "left"}' }, 'left|right', 'left|right')
expect('indent.py', { 'if flag:', '    first()', 'second()' },
  { 'if flag:', '    first()', '    second()' }, '', '    ')
expect('layout.py', { 'foo(a, b)' }, { 'foo(', '    a,', '    b', ')' }, '', '')
expect('compound.py', { 'if a is not b: pass' }, { 'if a is   not b: pass' }, '', '')
if pcall(vim.treesitter.language.inspect, 'yaml') then
  expect('indent.yml', { 'parent:', '  child: one', 'sibling: two' },
    { 'parent:', '  child: one', '  sibling: two' }, '', '  ')
  expect('flow.yml', { 'items: [one, two]' }, { 'items: [', '  one,', '  two', ']' }, '', '')
  expect('block.yml', { 'message: |', '  the old word' }, { 'message: |', '  the new word' }, 'old', 'new')
end
if pcall(vim.treesitter.language.inspect, 'markdown') then
  expect('reflow.md', { 'The old value stays.' }, { 'The new value', 'stays.' }, 'old', 'new')
end

-- Syntax captures are clipped to each row, across interleaved old/new lines.
local buf = open('multiline.lua', { 'local s = [[', 'old word', ']]' }, { 'local s = [[', 'new word', ']]' })
assert(words(buf, 'old') == 'old' and words(buf, 'new') == 'new')
local captured = {}
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
  if (mark[4].hl_group or ''):match('^@') then
    assert(mark[4].end_row == mark[2], 'syntax crossed an opposite-side row/header')
    if mark[4].hl_group == '@string.lua' then captured[mark[2]] = true end
  end
end
assert(captured[3] and captured[6], 'multiline content lost syntax color')
vim.api.nvim_buf_delete(buf, { force = true })

-- A shared context row may change its syntax role. Old string captures must
-- not override the new source's comment color on that row.
buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'M context.lua', '@@ -1,3 +1,2 @@',
  '-local s = [[', '+local s = ""', ' -- actual comment', '-]]' })
syntax.attach(buf)
local comment = false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
  if mark[2] == 4 then
    assert(mark[4].hl_group ~= '@string.lua', 'old source syntax leaked onto shared context')
    if mark[4].hl_group == '@comment.lua' then comment = true end
  end
end
assert(comment, 'shared context lost the new comment role')
vim.api.nvim_buf_delete(buf, { force = true })

-- Isolated additions/deletions and context separators remain ordinary lines.
for _, before_after in ipairs({ { {}, { 'local x = 1' } }, { { 'local x = 1' }, {} } }) do
  buf = open('pure.lua', before_after[1], before_after[2])
  assert(words(buf, 'old') == '' and words(buf, 'new') == '', 'one-sided file got word emphasis')
  vim.api.nvim_buf_delete(buf, { force = true })
end
buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'M groups.lua', '@@ -1,3 +1,4 @@', '-foo(a)', '+foo(b)',
  ' separator()', '+inserted()', ' last()' })
syntax.attach(buf)
assert(words(buf, 'old') == 'a' and words(buf, 'new') == 'b', 'context did not isolate addition-only group')
vim.api.nvim_buf_delete(buf, { force = true })

-- Existing textual fallback and other styles remain available.
expect('README.md', { 'The old value stays.' }, { 'The new value stays.' }, 'old', 'new')
local get_parser = vim.treesitter.get_string_parser
vim.treesitter.get_string_parser = function() error('parser unavailable') end
expect('missing.lua', { 'different(1)' }, { 'different(2)' }, '1', '2')
expect('missing_whole.lua', { 'parser_unavailable_before()' }, { 'parser_unavailable_after()' },
  '', '')
vim.treesitter.get_string_parser = get_parser
assert(not tokens.compare(tokens.parse({ '@@@' }, 'lua'), tokens.parse({ '???' }, 'lua'), { 1 }, { 1 }),
  'wholly erroneous fragments acquired structural roles')
assert(not tokens.compare(tokens.parse({ '-- valid context', '@@@' }, 'lua'),
  tokens.parse({ '-- valid context', '???' }, 'lua'), { 2 }, { 2 }),
  'valid context enabled structural comparison for an erroneous change group')
for _, style in ipairs({ 'delta', 'github', 'diffs' }) do
  syntax.config.word_diff_style = style
  expect('other.lua', { 'return 1' }, { 'return 2' }, '1', '2')
end
syntax.config.word_diff_style = 'treesitter'

-- Switching a loaded view replaces the actual word marks, not just the label.
buf = open('styles.lua', { 'foo(a, b)' }, { 'foo(', '  a,', '  b', ')' })
assert(words(buf, 'old') == '' and words(buf, 'new') == '')
syntax.config.word_diff_style = 'delta'
syntax.refresh_all()
assert(words(buf, 'old') ~= '' or words(buf, 'new') ~= '', 'delta did not restore line pairing')
assert(syntax.cycle_word_diff_style() == 'treesitter')
assert(words(buf, 'old') == '' and words(buf, 'new') == '', 'treesitter cycle did not repaint')
vim.api.nvim_buf_delete(buf, { force = true })

-- Syntax and token comparison share each parse. Cached redraws parse nothing.
local parses = 0
vim.treesitter.get_string_parser = function(...)
  parses = parses + 1
  return get_parser(...)
end
buf = open('cached.lua', { 'cached(unique_old)' }, { 'cached(', 'unique_new', ')' })
assert(parses == 2, 'syntax and word diff did not share parsing')
local start = vim.uv.hrtime()
for _ = 1, 50 do syntax.refresh(buf) end
assert(parses == 2, 'warm refresh reparsed unchanged fragments')
print(string.format('PERF: 50 cached repaints %.1f ms, no new parses', (vim.uv.hrtime() - start) / 1e6))
vim.treesitter.query.set('lua', 'highlights', '(identifier) @constant')
syntax.refresh(buf)
local changed_query = false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
  if mark[4].hl_group == '@constant.lua' then changed_query = true end
end
assert(changed_query and parses == 2, 'cached tree ignored query changes or reparsed unnecessarily')
vim.treesitter.query.set('lua', 'highlights', nil)
for i = 1, 17 do tokens.parse({ 'eviction_' .. i .. '()' }, 'lua') end
local before_eviction = parses
syntax.refresh(buf)
assert(parses == before_eviction + 2, 'bounded cache retained evicted sources')
vim.api.nvim_buf_delete(buf, { force = true })
vim.treesitter.get_string_parser = get_parser
print('PASS: block split/join/layout, syntax tokens, Unicode, literal roles, strings/comments, source byte mapping, syntax projection, fallbacks and caching')
