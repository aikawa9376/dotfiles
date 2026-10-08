-- nvim --headless --clean -u NONE -l tests/syntax_prefetch.lua
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.rtp:prepend(plugin)
vim.opt.rtp:append(vim.fn.stdpath('data') .. '/site')
vim.opt.rtp:prepend(vim.fn.stdpath('data') .. '/lazy/nvim-treesitter/runtime')
local syntax = require('git.features.syntax_highlight')
local structural = require('git.features.syntax_word_diff')
local native = require('git.features.syntax_native')
assert(native.command(), 'build the release worker first')
native.config.min_nodes = 0
local counts = { reads = 0, parses = 0, comparisons = 0, finished = 0 }
local open, parse, compare = vim.uv.fs_open, vim.treesitter.get_string_parser, structural.compare
vim.uv.fs_open = function(...) counts.reads = counts.reads + 1; return open(...) end
vim.treesitter.get_string_parser = function(...) counts.parses = counts.parses + 1; return parse(...) end
structural.compare = function(...)
  counts.comparisons = counts.comparisons + 1
  local result = compare(...)
  counts.finished = counts.finished + 1
  return result
end
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local candidates, specs, before, after = {}, {}, {}, {}
for index = 1, 12 do
  local name = 'prefetch_' .. index .. '.lua'
  before[index] = { 'function Prefetch_' .. index .. '(value)', '  return value + 1', 'end' }
  after[index] = { 'function Prefetch_' .. index .. '(value)', '  return value + 2', 'end' }
  local spec = { old = { path = root .. '/old_' .. name }, new = { path = root .. '/new_' .. name } }
  vim.fn.writefile(before[index], spec.old.path); vim.fn.writefile(after[index], spec.new.path)
  specs[name] = spec
  candidates[#candidates + 1] = { filename = name, spec = spec }
end
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'M prefetch_1.lua' })
local ns = vim.api.nvim_create_namespace('git_extension_syntax')
syntax.attach(buf, { diff_source = function(hunk) return specs[hunk.filename] end,
  prefetch = function() return candidates end })
assert(counts.reads == 0 and counts.parses == 0 and counts.comparisons == 0, 'collapsed attach started work inline')
assert(vim.wait(15000, function() return counts.finished == 8 end, 1), 'closed file comparisons were not prepared')
assert(counts.reads == 16 and counts.parses == 16 and counts.comparisons == 8, 'prefetch exceeded eight pairs or duplicated work')
assert(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) == 0 and not syntax.is_pending(buf), 'closed files acquired highlights/spinners')
-- Evict the shared parse LRU; resident warm pairs must still be reusable.
for index = 1, 20 do structural.parse({ 'EvictPrefetch_' .. index .. '()' }, 'lua') end
local saved = vim.deepcopy(counts)
local function patch(index)
  local lines = { 'M prefetch_' .. index .. '.lua', '@@ -1,3 +1,3 @@' }
  for _, line in ipairs(before[index]) do lines[#lines + 1] = '-' .. line end
  for _, line in ipairs(after[index]) do lines[#lines + 1] = '+' .. line end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  syntax.refresh(buf)
  assert(vim.wait(10000, function() return not syntax.is_pending(buf) end, 1), 'warm opening did not finish')
end
local started = vim.uv.hrtime()
patch(1)
assert(vim.deep_equal(saved, counts), 'opening a prefetched file repeated reads/parses/comparison after LRU eviction')
local warm_ms = (vim.uv.hrtime() - started) / 1e6
-- A changed worktree fingerprint cannot reuse the old prepared comparison.
after[1][2] = '  return value + 333'
vim.fn.writefile(after[1], specs['prefetch_1.lua'].new.path)
patch(1)
assert(counts.comparisons == saved.comparisons + 1, 'stale prefetched comparison was reused')
-- Retire all candidates, then ensure unload prevents any late publication.
candidates = {}
syntax.refresh(buf)
vim.api.nvim_buf_delete(buf, { force = true })
assert(vim.wait(1000, function() return native.stats.started == native.stats.completed + native.stats.cancelled + native.stats.failed end, 1),
  'closed view kept a worker alive')
vim.fn.delete(root, 'rf')
-- Open a file while its speculative worker is still pending: join/promote
-- that graph, rather than starting another read, parse or comparison.
local system, held = vim.system, nil
vim.system = function(command, options, callback)
  if command[1] == native.command() then
    return system(command, options, function(result) held = { callback = callback, result = result } end)
  end
  return system(command, options, callback)
end
local function speculative(name)
  local old = { 'function ' .. name .. '(value)', '  return value + 41', 'end' }
  local new = { 'function ' .. name .. '(value)', '  return value + 42', 'end' }
  local spec = { old = { text = table.concat(old, '\n') }, new = { text = table.concat(new, '\n') } }
  local view = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(view, 0, -1, false, { 'M ' .. name .. '.lua' })
  syntax.attach(view, { diff_source = function() return spec end,
    prefetch = function() return { { filename = name .. '.lua', spec = spec } } end })
  assert(vim.wait(10000, function() return held ~= nil end, 1), 'speculative worker did not start')
  return view, old, new
end
local view, old, new = speculative('SharedPrefetch')
local left, right = structural.parse(old, 'lua'), structural.parse(new, 'lua')
local started_counts = vim.deepcopy(counts)
local lines = { 'M SharedPrefetch.lua', '@@ -1,3 +1,3 @@' }
for _, line in ipairs(old) do lines[#lines + 1] = '-' .. line end
for _, line in ipairs(new) do lines[#lines + 1] = '+' .. line end
vim.api.nvim_buf_set_lines(view, 0, -1, false, lines)
syntax.refresh(view)
assert(vim.wait(10000, function() return left.full_jobs[right] and left.full_jobs[right].background == false end, 1),
  'opening did not join/promote its speculative graph')
assert(vim.deep_equal(counts, started_counts), 'opening duplicated the in-flight speculative work')
held.callback(held.result); held = nil
assert(vim.wait(10000, function() return not syntax.is_pending(view) end, 1), 'joined worker did not paint the opened file')
vim.api.nvim_buf_delete(view, { force = true })
local cancelled = native.stats.cancelled
view = speculative('CancelledPrefetch')
vim.api.nvim_buf_delete(view, { force = true })
assert(vim.wait(10000, function() return native.stats.cancelled > cancelled end, 1), 'unload kept speculative worker ownership')
held.callback(held.result) -- late native output must be inert after unload
vim.system = system
print(('PASS: eight bounded closed-file pairs; warm opening %.1f ms without IO/parsing/search, LRU retention, stale-file invalidation and unload'):format(warm_ms))
