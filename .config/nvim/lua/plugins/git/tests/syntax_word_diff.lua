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
local function settle(buf)
  assert(vim.wait(10000, function() return not syntax.is_pending(buf) end, 1), 'highlight preparation did not finish')
end
local function open(name, before, after, context, opts)
  local lines = { 'M ' .. name, ('@@ -%d +%d @@'):format(opts and opts.old_start or 1, opts and opts.new_start or 1) }
  for _, line in ipairs(context or {}) do lines[#lines + 1] = ' ' .. line end
  for _, line in ipairs(before) do lines[#lines + 1] = '-' .. line end
  for _, line in ipairs(after) do lines[#lines + 1] = '+' .. line end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  syntax.attach(buf, opts)
  settle(buf)
  return buf
end
local function words(buf, side, strong)
  local found = {}
  local group = side == 'old' and 'FugitiveExtDelete' or 'FugitiveExtAdd'
  if strong ~= false then group = group .. 'Text' end
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if mark[4].hl_group == group then
      local line = vim.api.nvim_buf_get_lines(buf, mark[2], mark[2] + 1, false)[1]
      found[#found + 1] = line:sub(mark[3] + 1, mark[4].end_col)
    end
  end
  table.sort(found)
  return table.concat(found, '|')
end
local function expect(name, before, after, old, new, strong)
  local buf = open(name, before, after)
  assert(words(buf, 'old', strong) == old, name .. ' old: ' .. words(buf, 'old', strong))
  assert(words(buf, 'new', strong) == new, name .. ' new: ' .. words(buf, 'new', strong))
  if strong == false then
    assert(words(buf, 'old') == '' and words(buf, 'new') == '', name .. ': text fallback acquired strong accents')
  end
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- Treesitter is selected for trying the structural renderer. The delta path
-- remains independent of structural comparison when explicitly selected.
assert(syntax.config.word_diff_style == 'treesitter', 'treesitter is no longer the default')
syntax.config.word_diff_style = 'delta'
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
settle(eof)
assert(words(eof, 'old') == '1' and words(eof, 'new') == '2', 'EOF markers shifted word ranges')
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(eof, ns, 0, -1, { details = true })) do
  assert(mark[2] ~= 3 and mark[2] ~= 5, 'EOF marker received a source highlight')
end
vim.api.nvim_buf_delete(eof, { force = true })
for _, style in ipairs({ 'treesitter', 'github', 'diffs', 'delta' }) do
  assert(syntax.cycle_word_diff_style() == style, 'word-diff cycle missed ' .. style)
end
syntax.config.word_diff_style = 'treesitter'

-- Structural backgrounds never extend into indentation or past EOL. Both
-- prefix overlays preserve the underlying Git patch for navigation/staging.
local buf = open('markers.lua', { '  return old_value' }, { '  return new_value' })
local prefix_count, backgrounds = 0, 0
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
  local details = mark[4]
  if details.virt_text then
    assert(details.virt_text[1][1] == '▏', 'treesitter lost its gutter marker')
    assert(details.virt_text[1][2] == (mark[2] == 2 and 'FugitiveExtDeletePrefix' or 'FugitiveExtAddPrefix'))
    prefix_count = prefix_count + 1
  elseif details.hl_group == 'FugitiveExtAdd' or details.hl_group == 'FugitiveExtDelete' then
    assert(not details.hl_eol and details.end_row == mark[2], 'structural background extended past its source span')
    local line = vim.api.nvim_buf_get_lines(buf, mark[2], mark[2] + 1, false)[1]
    assert(line:sub(mark[3] + 1, details.end_col):match('^%a+_value$'), 'unchanged code received a background')
    backgrounds = backgrounds + 1
  end
end
assert(prefix_count == 2 and backgrounds == 2)
assert(vim.api.nvim_buf_get_lines(buf, 2, 4, false)[1] == '-  return old_value', 'marker rewrote the actionable patch')
assert(vim.api.nvim_get_hl(0, { name = 'FugitiveExtAddPrefix', link = true }).link == 'GitSignsAdd')
assert(vim.api.nvim_get_hl(0, { name = 'FugitiveExtDeletePrefix', link = true }).link == 'GitSignsDelete')
vim.api.nvim_buf_delete(buf, { force = true })

-- Read actual surrounding source for incomplete hunk headers. It must supply
-- real captures, with no omitted source rows projected onto the patch.
for _, case in ipairs({
  { 'fragment.lua', 'function Utils.group(x)', 'function Utils.group(x, y)', '@keyword.function.lua', 1, 9 },
  { 'fragment.json', '  "first-key": {"commit": "old"},', '  "first-key": {"commit": "new"},', '@property.json', 3, 14 },
}) do
  local json = case[1]:match('json$') ~= nil
  local function full(line)
    return json and '{\n' .. line .. '\n  "following": {}\n}\n' or line .. '\nend\n'
  end
  buf = open(case[1], { case[2] }, { case[3] }, nil, {
    old_start = json and 2 or 1, new_start = json and 2 or 1,
    diff_source = function() return { old = { text = full(case[2]) }, new = { text = full(case[3]) } } end,
  })
  local seen = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if mark[4].hl_group == case[4] and mark[3] == case[5] and mark[4].end_col == case[6] then
      seen[mark[2]] = true
    end
    if (mark[4].hl_group or ''):match('^@') then
      assert(mark[2] == 2 or mark[2] == 3, 'omitted source escaped onto a patch/header row')
    end
  end
  assert(seen[2] and seen[3], case[1] .. ': incomplete fragment lost its leading syntax color')
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- Only detected changes receive native diff foregrounds. Switching back to
-- syntax colors reuses parses/comparisons and removes the extra color marks.
assert(syntax.config.changed_fg == 'syntax', 'diff foreground must be opt-in')
assert(syntax.toggle_changed_fg() == 'difft')
buf = open('changed_colors.lua', { 'function Colors.group(x)' }, { 'function Colors.group(x, y)' })
local colored = false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
  if mark[4].hl_group == 'FugitiveExtNovelAdd' then
    assert(mark[3] > #'function Colors.group(x', 'unchanged declaration got a diff foreground')
    colored = true
  end
end
assert(colored, 'detected addition has no native diff foreground')
local get_parser, compare_colors = vim.treesitter.get_string_parser, tokens.compare
vim.treesitter.get_string_parser = function() error('foreground switch reparsed source') end
tokens.compare = function() error('foreground switch recomputed comparison') end
assert(syntax.toggle_changed_fg() == 'syntax')
settle(buf)
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
  assert(not (mark[4].hl_group or ''):match('^FugitiveExtNovel'), 'syntax mode retained a native diff foreground')
end
vim.treesitter.get_string_parser, tokens.compare = get_parser, compare_colors
syntax.config.changed_fg = 'syntax'
vim.api.nvim_buf_delete(buf, { force = true })

-- Identical text can be a string in one place and code in another. Changing
-- just the source coordinates must invalidate captures, not the parsed tree.
local roles_code = 'local text = [[\nfunction Hidden()\n]]\nfunction Hidden()\n  return 1\nend\n'
buf = open('roles.lua', {}, { 'function Hidden()' }, nil, { new_start = 2,
  diff_source = function() return { old = { text = '' }, new = {
    text = roles_code,
  } } end,
})
local function role(group)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if mark[2] == 2 and mark[4].hl_group == group then return true end
  end
  return false
end
assert(role('@string.lua') and not role('@keyword.function.lua'), 'source context mistook a string for code')
vim.api.nvim_buf_set_lines(buf, 1, 2, false, { '@@ -0,0 +4 @@' })
syntax.refresh(buf); settle(buf)
assert(role('@keyword.function.lua') and not role('@string.lua'), 'identical hunk text reused the wrong source coordinates')
roles_code = 'local text = [[\nfunction Hidden()\n]]\n-- function Hidden()\n  return 1\n'
syntax.refresh(buf); settle(buf)
assert(not role('@comment.lua'), 'mismatched source text lent a stale patch its comment color')
vim.api.nvim_buf_delete(buf, { force = true })

-- Formatting-only changes have markers without colored syntax backgrounds.
buf = open('layout.lua', { 'foo(a, b)' }, { 'foo(', '  a,', '  b', ')' })
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
  assert(not (mark[4].hl_group or ''):match('^FugitiveExt[AD]'), 'layout-only edit acquired a background')
  assert(not (mark[4].hl_group or ''):match('^FugitiveExtNovel'), 'layout-only edit acquired a diff foreground')
end
vim.api.nvim_buf_delete(buf, { force = true })

-- Syntax captures are clipped to each row, across interleaved old/new lines.
buf = open('multiline.lua', { 'local s = [[', 'old word', ']]' }, { 'local s = [[', 'new word', ']]' })
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
settle(buf)
local comment = false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
  if mark[2] == 4 then
    assert(mark[4].hl_group ~= '@string.lua', 'old source syntax leaked onto shared context')
    if mark[4].hl_group == '@comment.lua' then comment = true end
  end
end
assert(comment, 'shared context lost the new comment role')
vim.api.nvim_buf_delete(buf, { force = true })

-- Isolated additions/deletions receive syntax backgrounds without word emphasis.
for _, before_after in ipairs({ { {}, { 'local x = 1' } }, { { 'local x = 1' }, {} } }) do
  buf = open('pure.lua', before_after[1], before_after[2])
  assert(words(buf, 'old') == '' and words(buf, 'new') == '', 'one-sided file got word emphasis')
  local painted = false
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if mark[4].hl_group == 'FugitiveExtAdd' or mark[4].hl_group == 'FugitiveExtDelete' then
      painted = true
      assert(mark[3] > 0 and not mark[4].hl_eol, 'one-sided edit colored its entire row')
    end
  end
  assert(painted, 'one-sided file has no syntax backgrounds')
  vim.api.nvim_buf_delete(buf, { force = true })
end
buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'M groups.lua', '@@ -1,3 +1,4 @@', '-foo(a)', '+foo(b)',
  ' separator()', '+inserted()', ' last()' })
syntax.attach(buf)
settle(buf)
local changed, context_bg = {}, false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
  if mark[4].hl_group == 'FugitiveExtAdd' or mark[4].hl_group == 'FugitiveExtDelete' then
    changed[mark[2]] = true
    context_bg = context_bg or mark[2] == 4 or mark[2] == 6
  end
end
assert(changed[2] and changed[3] and changed[5] and not context_bg, 'context/adjoining insertion projection failed')
vim.api.nvim_buf_delete(buf, { force = true })

-- Existing textual fallback and other styles remain available.
expect('README.md', { 'The old value stays.' }, { 'The new value stays.' }, 'old', 'new', false)
local get_parser = vim.treesitter.get_string_parser
vim.treesitter.get_string_parser = function() error('parser unavailable') end
expect('missing.lua', { 'different(1)' }, { 'different(2)' }, '1', '2', false)
expect('missing_whole.lua', { 'parser_unavailable_before()' }, { 'parser_unavailable_after()' },
  'parser_unavailable_before', 'parser_unavailable_after', false)
expect('missing_added.lua', {}, { 'added(1)' }, '', 'added(1)', false)
expect('missing_deleted.lua', { 'removed(1)' }, {}, 'removed(1)', '', false)
vim.treesitter.get_string_parser = get_parser
assert(not tokens.compare(tokens.parse({ '@@@' }, 'lua'), tokens.parse({ '???' }, 'lua')),
  'wholly erroneous fragments acquired structural roles')
assert(not tokens.compare(tokens.parse({ '-- valid context', '@@@' }, 'lua'),
  tokens.parse({ '-- valid context', '???' }, 'lua')),
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
settle(buf)
assert(words(buf, 'old') ~= '' or words(buf, 'new') ~= '', 'delta did not restore line pairing')
assert(syntax.cycle_word_diff_style() == 'treesitter')
settle(buf)
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
settle(buf)
local changed_query = false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
  if mark[4].hl_group == '@constant.lua' then changed_query = true end
end
assert(changed_query and parses == 2, 'cached tree ignored query changes or reparsed unnecessarily')
vim.treesitter.query.set('lua', 'highlights', nil)
-- Parser availability can change without an edit; retained hunks must still
-- switch to legacy syntax and restore their Tree-sitter colors on recovery.
local function has_syntax_marks()
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if (mark[4].hl_group or ''):match('^@') then return true end
  end
  return false
end
local inspect = vim.treesitter.language.inspect
vim.treesitter.language.inspect = function(lang)
  if lang == 'lua' then error('parser temporarily unavailable') end
  return inspect(lang)
end
syntax.refresh(buf)
settle(buf)
assert(not has_syntax_marks(), 'unchanged view retained unavailable parser colors')
vim.treesitter.language.inspect = inspect
syntax.refresh(buf)
settle(buf)
assert(has_syntax_marks() and parses == 2, 'parser recovery lost cached syntax or reparsed')
for i = 1, 17 do tokens.parse({ 'eviction_' .. i .. '()' }, 'lua') end
local before_eviction = parses
syntax.refresh(buf)
settle(buf)
assert(parses == before_eviction, 'an open view lost its resident parses after shared-cache eviction')
vim.api.nvim_buf_delete(buf, { force = true })
local evicted = tokens.parse({ 'shared_cache_eviction()' }, 'lua')
for i = 1, 17 do tokens.parse({ 'another_eviction_' .. i .. '()' }, 'lua') end
assert(tokens.parse({ 'shared_cache_eviction()' }, 'lua') ~= evicted, 'shared cache is no longer bounded')
vim.treesitter.get_string_parser = get_parser
print('PASS: token-only backgrounds, colored patch overlays, literal emphasis, syntax projection, fallbacks, switching and caching')
