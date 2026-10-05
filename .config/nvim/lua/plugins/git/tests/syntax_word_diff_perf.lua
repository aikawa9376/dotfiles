-- nvim --headless --clean -u NONE -l tests/syntax_word_diff_perf.lua
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.rtp:prepend(plugin)
vim.opt.rtp:append(vim.fn.stdpath('data') .. '/site')
vim.opt.rtp:prepend(vim.fn.stdpath('data') .. '/lazy/nvim-treesitter/runtime')
local syntax = require('git.features.syntax_highlight')
local tokens = require('git.features.syntax_word_diff')
local ns = vim.api.nvim_create_namespace('fugitive_extension_syntax')
local function settle(buf)
  assert(vim.wait(10000, function() return not syntax.is_pending(buf) end, 1), 'highlight preparation did not finish')
end
local counts = { parses = 0, comparisons = 0, captures = 0, marks = 0 }
local parser, compare, setmark = vim.treesitter.get_string_parser, tokens.compare, vim.api.nvim_buf_set_extmark
local query = vim.treesitter.query.get('lua', 'highlights')
local captures = query.iter_captures
vim.treesitter.get_string_parser = function(...) counts.parses = counts.parses + 1; return parser(...) end
tokens.compare = function(...) counts.comparisons = counts.comparisons + 1; return compare(...) end
query.iter_captures = function(...) counts.captures = counts.captures + 1; return captures(...) end
vim.api.nvim_buf_set_extmark = function(...) counts.marks = counts.marks + 1; return setmark(...) end
local function append(lines, i)
  vim.list_extend(lines, { 'M cached_' .. i .. '.lua', '@@ -1 +1 @@',
    '-run(old_' .. i .. ')', '+run(new_' .. i .. ')' })
end
local lines = {}
for i = 1, 36 do append(lines, i) end
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
local cold_start = vim.uv.hrtime()
syntax.attach(buf)
assert(counts.parses == 0 and counts.comparisons == 0 and counts.captures == 0, 'cold attach blocked on parsing/comparison/captures')
local loading = 0
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
  if mark[4].virt_text_pos == 'eol' then loading = loading + 1 end
end
assert(loading == 36, 'cold hunks did not indicate deferred loading')
print(string.format('PERF: 36 cold hunks displayed in %.1f ms, no parsing/comparison/captures before return',
  (vim.uv.hrtime() - cold_start) / 1e6))
settle(buf)
assert(counts.parses == 72 and counts.comparisons == 36 and counts.captures == 72)
local initial = vim.deepcopy(counts)
local started = vim.uv.hrtime()
for _ = 1, 50 do syntax.refresh(buf) end
assert(vim.deep_equal(initial, counts), 'unchanged open hunks were recalculated or repainted')
print(string.format('PERF: 36 open hunks, 50 refreshes %.1f ms; zero parses/comparisons/captures/marks',
  (vim.uv.hrtime() - started) / 1e6))
local extra = {}; append(extra, 37)
vim.api.nvim_buf_set_lines(buf, -1, -1, false, extra)
syntax.refresh(buf)
settle(buf)
assert(counts.parses == initial.parses + 2 and counts.comparisons == initial.comparisons + 1
  and counts.captures == initial.captures + 2, 'opening one more hunk recalculated earlier hunks')
local after_append = vim.deepcopy(counts)
vim.api.nvim_buf_set_lines(buf, 3, 4, false, { '+run(changed_first)' })
syntax.refresh(buf)
settle(buf)
assert(counts.parses <= after_append.parses + 2 and counts.comparisons == after_append.comparisons + 1
  and counts.captures == after_append.captures + 2, 'editing one hunk recalculated other hunks')
local after_edit = vim.deepcopy(counts)
vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'Head: main', '' })
syntax.refresh(buf)
settle(buf)
assert(vim.deep_equal(after_edit, counts), 'shifting intact hunks recalculated or repainted them')
local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)
syntax.refresh(buf)
settle(buf)
assert(counts.parses == after_edit.parses and counts.comparisons == after_edit.comparisons
  and counts.captures == after_edit.captures, 'buffer reconstruction discarded hunk results')
local markers = 0
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
  if mark[4].virt_text then
    local line = all_lines[mark[2] + 1]
    assert(line:match('^[+-]') and mark[4].virt_text[1][1] == '▏', 'cached overlay moved off its raw patch row')
    markers = markers + 1
  end
end
assert(markers == 74, 'reconstruction duplicated/lost marker plans')
local views = {}
for i = 38, 55 do
  local patch = {}; append(patch, i)
  local view = vim.api.nvim_create_buf(false, true); views[#views + 1] = view
  vim.api.nvim_buf_set_lines(view, 0, -1, false, patch); syntax.attach(view)
end
-- Several files can share the same old source (including empty files). One
-- comparison finishing must not invalidate unrelated source pairs.
for i = 1, 8 do
  for _, before in ipairs({ '', '-shared_old()' }) do
    local patch = { 'M shared_' .. i .. '_' .. #before .. '.lua', '@@ -1 +1 @@' }
    if before ~= '' then patch[#patch + 1] = before end
    patch[#patch + 1] = '+shared_new_' .. i .. '()'
    local view = vim.api.nvim_create_buf(false, true); views[#views + 1] = view
    vim.api.nvim_buf_set_lines(view, 0, -1, false, patch); syntax.attach(view)
  end
end
for _, view in ipairs(views) do settle(view) end
local after_views = vim.deepcopy(counts)
syntax.refresh_all()
assert(vim.deep_equal(after_views, counts), 'shared-cache pressure recalculated open views')
for _, view in ipairs(views) do vim.api.nvim_buf_delete(view, { force = true }) end
vim.api.nvim_buf_delete(buf, { force = true })
vim.treesitter.get_string_parser, tokens.compare, query.iter_captures, vim.api.nvim_buf_set_extmark = parser, compare, captures, setmark

-- Dense painting must yield too: async parsing followed by one giant extmark
-- batch would still stall the editor. Force a yield at each painter checkpoint
-- and observe an editor callback before all color marks have been published.
do
  local real_time, simulated = vim.uv.hrtime, 0
  vim.uv.hrtime = function()
    if debug.getinfo(2, 'S').source:find('/features/highlight_jobs.lua', 1, true) then
      simulated = simulated + 4e6; return simulated
    end
    return real_time()
  end
  local painted, heartbeat = 0, nil
  vim.api.nvim_buf_set_extmark = function(buffer, namespace, row, col, options)
    if (options.hl_group or ''):match('^@') or options.hl_group == 'FugitiveExtAdd' then
      painted = painted + 1
      if painted == 1 then vim.schedule(function() heartbeat = painted end) end
    end
    return setmark(buffer, namespace, row, col, options)
  end
  local dense = { 'M dense.lua', '@@ -0,0 +1,300 @@' }
  for i = 1, 300 do dense[#dense + 1] = '+local paint_' .. i .. ' = ' .. i end
  local dense_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(dense_buf, 0, -1, false, dense)
  syntax.attach(dense_buf)
  assert(painted == 0, 'cold dense hunk generated colors before returning')
  settle(dense_buf)
  assert(heartbeat and heartbeat < painted, 'dense painting did not allow editor callbacks between batches')
  vim.api.nvim_buf_delete(dense_buf, { force = true })
  vim.api.nvim_buf_set_extmark, vim.uv.hrtime = setmark, real_time
end

-- Closing a cold hunk before the queue starts must skip parsing altogether.
do
  local calls = 0
  vim.treesitter.get_string_parser = function(...) calls = calls + 1; return parser(...) end
  local cold = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(cold, 0, -1, false, { 'M cold.lua', '@@ -1 +1 @@', '-cold_before()', '+cold_after()' })
  syntax.attach(cold)
  vim.api.nvim_buf_set_lines(cold, 0, -1, false, { 'M cold.lua' })
  syntax.refresh(cold)
  vim.wait(50, function() return false end, 1)
  assert(calls == 0 and not syntax.is_pending(cold), 'closed cold hunk still parsed')
  assert(#vim.api.nvim_buf_get_extmarks(cold, ns, 0, -1, {}) == 0, 'cold result painted a closed hunk')
  vim.api.nvim_buf_delete(cold, { force = true })
  vim.treesitter.get_string_parser = parser
end

-- A recovery parse belongs to its source pair, not just the view that started
-- it. Hold completed-declaration parses, join from a second view, then close
-- the initiating view before releasing the results.
do
  local parse_async, pending = tokens.parse_async, {}
  tokens.parse_async = function(lines, lang, valid, callback, cancelled)
    if #lines == 2 and lines[2] == 'end' and lines[1]:find('SharedRecovery', 1, true) then
      pending[#pending + 1] = { lines = lines, lang = lang, valid = valid, callback = callback, cancelled = cancelled }
    else parse_async(lines, lang, valid, callback, cancelled) end
  end
  local patch = { 'M shared_recovery.lua', '@@ -1,2 +1,2 @@', ' -- SharedRecovery context',
    '-function SharedRecovery.group(x)', '+function SharedRecovery.group(x, y)' }
  local function view()
    local buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, patch)
    syntax.attach(buffer)
    return buffer
  end
  local first = view()
  assert(vim.wait(10000, function() return #pending == 2 end, 1), 'declaration recovery did not start')
  -- While recovery is held, animation must update just its existing icon,
  -- without refreshing hunks, parsing, comparing, querying or repainting code.
  vim.wait(100, function() return false end, 1)
  local function icon(buffer)
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buffer, ns, 0, -1, { details = true })) do
      if mark[4].virt_text_pos == 'eol' then return mark[1], mark[4].virt_text[1][1] end
    end
  end
  local icon_id, frame = icon(first)
  assert(icon_id and not frame:find('読み込み', 1, true), 'pending hunk has no loading icon')
  local work, animation = 0, 0
  local refresh = syntax.refresh
  syntax.refresh = function(...) work = work + 1; return refresh(...) end
  vim.treesitter.get_string_parser = function(...) work = work + 1; return parser(...) end
  tokens.compare = function(...) work = work + 1; return compare(...) end
  query.iter_captures = function(...) work = work + 1; return captures(...) end
  vim.api.nvim_buf_set_extmark = function(buffer, namespace, row, col, options)
    assert(buffer == first and options.virt_text_pos == 'eol' and options.id == icon_id,
      'loading animation repainted code or replaced its mark')
    animation = animation + 1
    return setmark(buffer, namespace, row, col, options)
  end
  assert(vim.wait(300, function() local _, current = icon(first); return current ~= frame end, 1),
    'loading icon did not animate')
  assert(animation > 0 and work == 0, 'loading animation restarted highlight work')
  syntax.refresh = refresh
  vim.treesitter.get_string_parser, tokens.compare, query.iter_captures, vim.api.nvim_buf_set_extmark =
    parser, compare, captures, setmark
  local second = view()
  local old = tokens.parse({ '-- SharedRecovery context', 'function SharedRecovery.group(x)' }, 'lua')
  local new = tokens.parse({ '-- SharedRecovery context', 'function SharedRecovery.group(x, y)' }, 'lua')
  local key = vim.mpack.encode({ { old.lines[2] }, { new.lines[2] } })
  assert(vim.wait(10000, function()
    return old.recoveries[new].fragments[key].waiters[second] == true
  end, 1), 'second view did not join recovery')
  vim.api.nvim_buf_delete(first, { force = true })
  tokens.parse_async = parse_async
  for _, request in ipairs(pending) do
    assert(request.valid(), 'closing the first view canceled the second view recovery')
    parse_async(request.lines, request.lang, request.valid, request.callback, request.cancelled)
  end
  settle(second)
  local added = false
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(second, ns, 0, -1, { details = true })) do
    if mark[4].hl_group == 'FugitiveExtAdd' then
      local line = patch[mark[2] + 1]
      if line:sub(mark[3] + 1, mark[4].end_col):find('y', 1, true) then added = true end
    end
  end
  assert(added, 'shared recovery did not paint its final added parameter')
  assert(not icon(second), 'finished hunk kept its loading icon')
  vim.api.nvim_buf_delete(second, { force = true })
  local idle_marks = 0
  vim.api.nvim_buf_set_extmark = function(...) idle_marks = idle_marks + 1; return setmark(...) end
  vim.wait(150, function() return false end, 1)
  vim.api.nvim_buf_set_extmark = setmark
  assert(idle_marks == 0, 'loading animation kept painting after all views finished')
end

-- Simulate >100 ms elapsed while forcing cooperative suspension. This must
-- resume the same job, not abandon structural comparison or duplicate it.
local fixture = vim.json.decode(table.concat(vim.fn.readfile(plugin .. '/tests/fixtures/difftastic_word_diff.json'), '\n'))
local case
for _, candidate in ipairs(fixture.cases) do if candidate.name == 'long_anchored_file.lua' then case = candidate end end
assert(case)
local now, simulated = vim.uv.hrtime, 0
local function simulate_elapsed()
  if debug.getinfo(2, 'S').source:find('/features/syntax_word_diff.lua', 1, true) then
    simulated = simulated + 10e6
    return simulated
  end
  return now()
end
vim.uv.hrtime = simulate_elapsed
local long_lines = { 'M cooperative.lua', '@@ -1,100 +1,100 @@' }
for _, line in ipairs(case.before) do long_lines[#long_lines + 1] = '-' .. line end
for _, line in ipairs(case.after) do long_lines[#long_lines + 1] = '+' .. line end
local long_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(long_buf, 0, -1, false, long_lines)
syntax.attach(long_buf)
local old, new = tokens.parse(case.before, 'lua'), tokens.parse(case.after, 'lua')
assert(vim.wait(10000, function() return old.jobs and old.jobs[new] ~= nil end, 1), 'comparison did not start')
local job = old.jobs[new]
for _ = 1, 5 do syntax.refresh(long_buf) end
assert(old.jobs[new] == job, 'refresh started duplicate comparisons')
assert(vim.wait(10000, function() return old.comparison ~= nil end, 1), 'cooperative comparison never finished')
vim.uv.hrtime = now
assert(simulated > 100e6 and old.comparison.result ~= false, 'elapsed time abandoned structural comparison')
assert(vim.deep_equal(old.comparison.result, compare(old, new)), 'cooperative result lost correspondence')
assert(vim.wait(1000, function()
  if syntax.is_pending(long_buf) then return false end
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(long_buf, ns, 0, -1, { details = true })) do
    if mark[4].hl_group == 'FugitiveExtAdd' then return false end
  end
  return true
end, 1), 'finished structure did not replace provisional plus backgrounds')
vim.api.nvim_buf_delete(long_buf, { force = true })

-- Closing an in-flight hunk cancels it even if the status buffer stays open.
vim.uv.hrtime = simulate_elapsed
local cancel_lines = vim.deepcopy(long_lines)
for i, line in ipairs(cancel_lines) do cancel_lines[i] = line:gsub('anchor_', 'cancel_anchor_') end
local cancel_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(cancel_buf, 0, -1, false, cancel_lines)
syntax.attach(cancel_buf)
local cancel_old = {}; for _, line in ipairs(case.before) do cancel_old[#cancel_old + 1] = line:gsub('anchor_', 'cancel_anchor_') end
local source = tokens.parse(cancel_old, 'lua')
assert(vim.wait(10000, function() return next(source.jobs or {}) ~= nil end, 1), 'cancel comparison did not start')
vim.api.nvim_buf_set_lines(cancel_buf, 0, -1, false, { 'M cooperative.lua' })
syntax.refresh(cancel_buf)
assert(vim.wait(1000, function() return next(source.jobs) == nil end, 1), 'closed hunk kept computing')
assert(not source.comparison, 'cancellation cached a partial/failed correspondence')
vim.uv.hrtime = now
vim.api.nvim_buf_delete(cancel_buf, { force = true })
print('PASS: resident hunk/view caches, incremental edits, shifted/rebuilt patch rows, cooperative completion and cancellation')
