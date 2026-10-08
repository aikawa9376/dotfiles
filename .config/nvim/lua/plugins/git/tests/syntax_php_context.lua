-- nvim --headless --clean -u NONE -l tests/syntax_php_context.lua
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.rtp:prepend(plugin)
vim.opt.rtp:append(vim.fn.stdpath('data') .. '/site')
vim.opt.rtp:prepend(vim.fn.stdpath('data') .. '/lazy/nvim-treesitter/runtime')
local syntax = require('git.features.syntax_highlight')
local structural = require('git.features.syntax_word_diff')
local renderer = require('git.features.status_renderer')
local ns = vim.api.nvim_create_namespace('git_extension_syntax')
local fixture = vim.json.decode(table.concat(vim.fn.readfile(plugin .. '/tests/fixtures/difftastic_word_diff.json'), '\n'))
local case
for _, value in ipairs(fixture.cases) do if value.name == 'php_full_context.php' then case = value end end
assert(case)
local root = vim.fn.tempname() .. ' php context'
vim.fn.mkdir(root, 'p')
local function git(args)
  local result = vim.system(vim.list_extend({ 'git', '-C', root }, args), { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
local function write(lines) vim.fn.writefile(lines, root .. '/invoice.php') end
local function settle(buf)
  syntax.refresh(buf)
  assert(vim.wait(15000, function() return not syntax.is_pending(buf) end, 1), 'PHP comparison did not finish')
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
local function check(buf)
  local hunks, hunk = {}, nil
  for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local old, new = line:match('^@@ %-(%d+)[^+]*%+(%d+)')
    if old then
      hunk = { old_start = tonumber(old), new_start = tonumber(new), start_line = row, lines = {} }
      hunks[#hunks + 1] = hunk
    elseif hunk and line:match('^[ +-]') then
      hunk.lines[#hunk.lines + 1] = line
    else
      hunk = nil
    end
  end
  local marks, rows = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true }), {}
  for _, mark in ipairs(marks) do
    local details = mark[4]
    if details.hl_group == 'GitExtSyntaxAdd' or details.hl_group == 'GitExtSyntaxDelete'
      or details.hl_group == 'GitExtSyntaxAddText' or details.hl_group == 'GitExtSyntaxDeleteText' then
      assert(not details.hl_eol and details.end_row == mark[2], 'PHP retained whole-line background')
      rows[mark[2]] = rows[mark[2]] or {}
      rows[mark[2]][#rows[mark[2]] + 1] = { mark[3], details.end_col - 1 }
    end
  end
  local changed, tagless, method, html = 0, 0, false, false
  for _, hunk in ipairs(hunks) do
    local positions = { old = hunk.old_start, new = hunk.new_start }
    local has_tag = false
    for index, raw in ipairs(hunk.lines) do
      local prefix, line = raw:sub(1, 1), raw:sub(2)
      if line == '<?php' then has_tag = true end
      for _, side in ipairs({ 'old', 'new' }) do
        if prefix == ' ' or prefix == (side == 'old' and '-' or '+') then
          if prefix ~= ' ' then
            local row = hunk.start_line + index - 1
            assert(vim.deep_equal(mask(rows[row], line), mask(case.expected[side][positions[side]], line)),
              'PHP spans differ from native at ' .. raw .. ': ' .. vim.inspect(rows[row]))
            changed = changed + 1
            method = method or line:find('public function', 1, true) ~= nil
            html = html or line:find('echo render', 1, true) ~= nil
          end
          positions[side] = positions[side] + 1
        end
      end
    end
    if not has_tag then tagless = tagless + 1 end
  end
  assert(changed >= 8 and tagless >= 3 and method and html, 'fixture did not exercise tagless/class/HTML fragments')
end

git({ 'init', '-qb', 'main' })
git({ 'config', 'user.name', 'Test' }); git({ 'config', 'user.email', 'test@example.invalid' })
git({ 'config', 'commit.gpgsign', 'false' })
write(case.before); git({ 'add', '.' }); git({ 'commit', '-qm', 'base' })
local staged = {}
for i, line in ipairs(case.before) do staged[i] = line:gsub('calculateOld', 'calculateNew') end
write(staged); git({ 'add', '.' }); write(case.after)
local buffer = vim.api.nvim_create_buf(false, true)
vim.b[buffer].git_dir = root .. '/.git'
local function snapshot()
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, assert(renderer.snapshot(buffer, root)))
end
snapshot()
for row, line in ipairs(vim.api.nvim_buf_get_lines(buffer, 0, -1, false)) do
  if line:match('^Unstaged changes') or line:match('^Staged changes') then assert(renderer.set_diff(buffer, row, true)) end
end
snapshot()
local system, compare, parser, setmark = vim.system, structural.compare, vim.treesitter.get_string_parser, vim.api.nvim_buf_set_extmark
local counts = { reads = 0, comparisons = 0, parses = 0, marks = 0 }
vim.system = function(argv, ...)
  assert(argv[1] ~= 'difft', 'PHP renderer invoked difft')
  if argv[1] == 'git' and argv[3] == 'show' then counts.reads = counts.reads + 1 end
  return system(argv, ...)
end
structural.compare = function(old, new, ...)
  counts.comparisons = counts.comparisons + 1
  assert(#old.lines > 50 and old.lines[1] == '<?php', 'PHP compared a contextless fragment')
  return compare(old, new, ...)
end
vim.treesitter.get_string_parser = function(...) counts.parses = counts.parses + 1; return parser(...) end
vim.api.nvim_buf_set_extmark = function(...) counts.marks = counts.marks + 1; return setmark(...) end
syntax.attach(buffer, { diff_source = function(hunk) return renderer.highlight_source(buffer, hunk.start_line) end })
assert(counts.reads == 0 and counts.parses == 0 and counts.comparisons == 0, 'PHP cold attach blocked on analysis')
settle(buffer); check(buffer)
assert(counts.comparisons == 2, 'PHP did not share complete-file comparisons across hunks: ' .. counts.comparisons)
assert(counts.reads == 3, 'PHP reread complete files across hunks: ' .. counts.reads)
local warm = vim.deepcopy(counts)
for _ = 1, 50 do syntax.refresh(buffer) end
assert(vim.deep_equal(counts, warm), 'unchanged PHP views recomputed or repainted')
vim.system, structural.compare, vim.treesitter.get_string_parser, vim.api.nvim_buf_set_extmark = system, compare, parser, setmark
vim.api.nvim_buf_delete(buffer, { force = true }); renderer.cleanup(buffer)

-- The Commit view uses the same complete-file comparison after a rename.
git({ 'add', '.' }); git({ 'mv', 'invoice.php', 'renamed invoice.php' }); git({ 'commit', '-qm', 'target' })
local commit = require('git.features.commit')
commit.setup(vim.api.nvim_create_augroup('PhpContextCommit', { clear = true }))
local view = assert(commit.open({ work_tree = root, revision = git({ 'rev-parse', 'HEAD' }) }))
for row in ipairs(vim.api.nvim_buf_get_lines(view, 0, -1, false)) do
  local entry, info = commit.entry_at(view, row)
  if entry and info.header then
    vim.api.nvim_win_set_cursor(0, { row, 0 }); vim.fn.maparg('>', 'n', false, true).callback(); break
  end
end
settle(view); check(view)
vim.api.nvim_buf_delete(view, { force = true })

-- Metadata failure, stale files and broken enclosing syntax must use muted
-- words rather than interpreting a tagless PHP fragment as one HTML atom.
local before, after = '$result = calculateOldTotal($price);', '$result = calculateNewTotal($price);'
local function inline(spec)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    'M fragment.php', '@@ -2 +2 @@', '-' .. before, '+' .. after,
  })
  syntax.attach(buf, spec and { diff_source = function() return spec end } or nil)
  return buf
end
local function check_inline(buf)
  for _, row in ipairs({ 2, 3 }) do
    local ranges = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, -1 }, { details = true })) do
      if mark[4].hl_group == 'GitExtSyntaxAdd' or mark[4].hl_group == 'GitExtSyntaxDelete' then
        ranges[#ranges + 1] = { mark[3], mark[4].end_col - 1 }
      end
      assert(mark[4].hl_group ~= 'GitExtSyntaxAddText' and mark[4].hl_group ~= 'GitExtSyntaxDeleteText')
    end
    assert(vim.deep_equal(mask(ranges, row == 2 and before or after), mask({ { 11, 27 } }, before)),
      'tagless PHP lost the changed identifier: ' .. vim.inspect(ranges))
  end
end
local specs = {
  false,
  { root = root, path = 'fragment.php', old = { text = '<?php\n' .. before .. '\nclass Broken {' },
    new = { text = '<?php\n' .. after .. '\nclass Broken {' } },
  { root = root, path = 'fragment.php', old = { text = '<?php\n$unrelated = stale();' },
    new = { text = '<?php\n' .. after } },
}
for _, spec in ipairs(specs) do
  local buf = inline(spec or nil)
  settle(buf); check_inline(buf); vim.api.nvim_buf_delete(buf, { force = true })
end

-- Structural comparison must work independently of the syntax color query.
local get_query = vim.treesitter.query.get
vim.treesitter.query.get = function(lang, ...)
  if lang == 'php' then return nil end
  return get_query(lang, ...)
end
local spec = { root = root, path = 'fragment.php',
  old = { text = '<?php\n' .. before }, new = { text = '<?php\n' .. after } }
local buf = inline(spec)
settle(buf); check_inline(buf)
vim.api.nvim_buf_delete(buf, { force = true })
vim.treesitter.query.get = get_query

-- The same displayed bytes can move from PHP code to HTML through changes
-- outside the hunk. A source-key change must invalidate its background plan.
spec = { root = root, path = 'fragment.php',
  old = { text = '<?php\n' .. before }, new = { text = '<?php\n' .. after } }
buf = inline(spec)
settle(buf); check_inline(buf)
spec.old.text = '<section>\n' .. before .. '\n<?php ?>\n</section>'
spec.new.text = '<section>\n' .. after .. '\n<?php ?>\n</section>'
settle(buf)
local html_case
for _, value in ipairs(fixture.cases) do if value.name == 'php_html_text_context.php' then html_case = value end end
assert(html_case)
for _, side in ipairs({ 'old', 'new' }) do
  local row, spans, emphasis = side == 'old' and 2 or 3, {}, {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, -1 }, { details = true })) do
    if mark[4].hl_group == 'GitExtSyntaxAdd' or mark[4].hl_group == 'GitExtSyntaxDelete' then
      spans[#spans + 1] = { mark[3], mark[4].end_col - 1 }
    elseif mark[4].hl_group == 'GitExtSyntaxAddText' or mark[4].hl_group == 'GitExtSyntaxDeleteText' then
      emphasis[#emphasis + 1] = { mark[3], mark[4].end_col - 1 }
    end
  end
  assert(vim.deep_equal(mask(spans, before), mask(html_case.expected[side][2], before)),
    'PHP background retained the previous file context: ' .. vim.inspect(spans))
  assert(vim.deep_equal(mask(emphasis, before), mask(html_case.emphasis[side][2], before)),
    'PHP HTML text lost native word emphasis: ' .. vim.inspect(emphasis))
end
vim.api.nvim_buf_delete(buf, { force = true })

-- Closing the first view during a suspended whole-file graph must preserve
-- the shared comparison needed by the other view.
local started, completed, held = 0, 0, true
structural.compare = function(old, new, options)
  started = started + 1
  while held do coroutine.yield() end
  local result = compare(old, new, options)
  completed = completed + 1
  return result
end
spec = { root = root, path = 'shared.php',
  old = { text = '<?php\n' .. before .. '\n// Shared source lifetime' },
  new = { text = '<?php\n' .. after .. '\n// Shared source lifetime' } }
syntax.config.changed_fg = 'difft'
local fallback, text_calls = structural.text_fallback, 0
structural.text_fallback = function(...)
  text_calls = text_calls + 1
  return fallback(...)
end
local first, second = inline(spec), inline(spec)
assert(vim.wait(5000, function() return started == 1 end, 1), 'shared PHP graph did not start')
for _, buffer in ipairs({ first, second }) do
  assert(vim.wait(1000, function()
    local has_syntax, has_spinner = false, false
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buffer, ns, 0, -1, { details = true })) do
      local group = mark[4].hl_group or ''
      assert(not group:match('^GitExtSyntax') and not group:match('^GitExtNovel'),
        'pending PHP comparison painted provisional diff spans')
      has_syntax = has_syntax or group:match('^@') ~= nil
      has_spinner = has_spinner or mark[4].virt_text_pos == 'eol'
    end
    return has_syntax and has_spinner
  end, 1), 'pending PHP comparison lost syntax colors or its loading icon')
end
assert(text_calls == 0, 'pending PHP comparison computed a provisional text fallback')
vim.api.nvim_buf_delete(first, { force = true })
held = false
settle(second); check_inline(second)
assert(started == 1 and completed == 1, 'closing one PHP view canceled or duplicated shared work')
vim.api.nvim_buf_delete(second, { force = true })
structural.compare = compare
structural.text_fallback = fallback
syntax.config.changed_fg = 'syntax'
vim.fn.delete(root, 'rf')
print('PASS: native PHP spans in real staged/unstaged/renamed Commit views, tagless methods, embedded HTML, shared async comparison and warm caches')
