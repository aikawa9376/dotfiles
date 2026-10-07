-- nvim --headless --clean -u NONE -l tests/syntax_multi_open.lua
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.rtp:prepend(plugin)
vim.opt.rtp:append(vim.fn.stdpath('data') .. '/site')
vim.opt.rtp:prepend(vim.fn.stdpath('data') .. '/lazy/nvim-treesitter/runtime')
local syntax = require('git.features.syntax_highlight')
local structural = require('git.features.syntax_word_diff')
local ns = vim.api.nvim_create_namespace('fugitive_extension_syntax')
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local buf = vim.api.nvim_create_buf(false, true)
local counts = { parses = 0, comparisons = 0, captures = 0, inventories = 0, old_paints = 0, old_deletes = 0 }
local parser, compare = vim.treesitter.get_string_parser, structural.compare
local setmark, delmark, getmarks = vim.api.nvim_buf_set_extmark, vim.api.nvim_buf_del_extmark, vim.api.nvim_buf_get_extmarks
local query = vim.treesitter.query.get('lua', 'highlights')
local captures = query.iter_captures
local boundary, retained_ids, opening, completing = 0, {}, nil, false
vim.treesitter.get_string_parser = function(...) counts.parses = counts.parses + 1; return parser(...) end
structural.compare = function(...) counts.comparisons = counts.comparisons + 1; return compare(...) end
query.iter_captures = function(...) counts.captures = counts.captures + 1; return captures(...) end
vim.api.nvim_buf_set_extmark = function(buffer, namespace, row, col, opts)
  if buffer == buf and namespace == ns and row < boundary then counts.old_paints = counts.old_paints + 1 end
  return setmark(buffer, namespace, row, col, opts)
end
vim.api.nvim_buf_del_extmark = function(buffer, namespace, id)
  if buffer == buf and namespace == ns and retained_ids[id] then counts.old_deletes = counts.old_deletes + 1 end
  return delmark(buffer, namespace, id)
end
vim.api.nvim_buf_get_extmarks = function(buffer, namespace, ...)
  if buffer == buf and namespace == ns then counts.inventories = counts.inventories + 1 end
  return getmarks(buffer, namespace, ...)
end
local refresh = syntax.refresh
syntax.refresh = function(buffer, changes)
  completing = changes ~= nil
  local result = refresh(buffer, changes)
  completing = false
  return result
end
local specs = {}
syntax.attach(buf, { diff_source = function(hunk)
  assert(not completing or hunk.filename == opening, 'completion revisited an unrelated file source')
  return specs[hunk.filename]
end })
local durations = {}
-- Enough complete pairs to evict both the shared parse LRU and read session.
-- Thousands of retained syntax marks expose namespace-wide inventory growth.
for index = 1, 16 do
  opening = ('dense_%d.lua'):format(index)
  local old, new = {}, {}
  for line = 1, 450 do
    old[line] = ('local value_%d_%d = %d'):format(index, line, line)
    new[line] = ('local value_%d_%d = %d'):format(index, line, line == 450 and 9999 or line)
  end
  vim.fn.writefile(old, root .. '/old_' .. opening)
  vim.fn.writefile(new, root .. '/new_' .. opening)
  specs[opening] = { old = { path = root .. '/old_' .. opening }, new = { path = root .. '/new_' .. opening } }
  local patch = { 'M ' .. opening, '@@ -1,450 +1,450 @@' }
  for _, line in ipairs(old) do patch[#patch + 1] = '-' .. line end
  for _, line in ipairs(new) do patch[#patch + 1] = '+' .. line end
  boundary = index == 1 and 0 or vim.api.nvim_buf_line_count(buf)
  retained_ids = {}
  for _, mark in ipairs(getmarks(buf, ns, 0, -1, {})) do retained_ids[mark[1]] = true end
  local before, started = vim.deepcopy(counts), vim.uv.hrtime()
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, patch)
  syntax.refresh(buf)
  assert(vim.wait(30000, function() return not syntax.is_pending(buf) end, 1), 'new diff did not finish')
  durations[index] = (vim.uv.hrtime() - started) / 1e6
  assert(counts.parses - before.parses == 2, 'opening a file reparsed retained sources')
  assert(counts.comparisons - before.comparisons == 1, 'opening a file recomputed retained comparisons')
  assert(counts.captures - before.captures == 2, 'opening a file requeried retained syntax')
  assert(counts.inventories == before.inventories, 'opening a file read retained extmark details')
  assert(counts.old_paints == before.old_paints and counts.old_deletes == before.old_deletes,
    'opening a file repainted an already completed hunk')
end
vim.api.nvim_buf_delete(buf, { force = true })
vim.fn.delete(root, 'rf')
-- A recovery graph can serve several raw source pairs in the same buffer.
-- Keep every recipient, including when the last registered hunk closes.
local is_active = syntax.source_is_active
for _, close_last in ipairs({ false, true }) do
  local view = vim.api.nvim_create_buf(false, true)
  local owners, opposites, notification = { {}, {} }, { {}, {} }, nil
  local label = close_last and 'closed' or 'shared'
  local old = structural.parse({ 'run_' .. label .. '(before)' }, 'lua')
  local new = structural.parse({ 'run_' .. label .. '(after)' }, 'lua')
  syntax.source_is_active = function(buffer, source, opposite)
    if buffer ~= view then return is_active(buffer, source, opposite) end
    return source == owners[1] and opposite == opposites[1]
      or not close_last and source == owners[2] and opposite == opposites[2]
  end
  syntax.refresh = function(buffer, changes)
    if buffer == view then notification = changes; return end
    return refresh(buffer, changes)
  end
  for index = 1, 2 do
    local _, pending = structural.compare_async(old, new, view, owners[index], opposites[index])
    assert(pending, 'shared graph did not remain queued')
  end
  assert(vim.wait(10000, function() return notification ~= nil end, 1), 'shared graph lost a live recipient')
  assert(notification.sources[owners[1]][opposites[1]], 'first raw pair missed its targeted completion')
  assert(close_last and notification.sources[owners[2]] == nil
    or not close_last and notification.sources[owners[2]][opposites[2]], 'last raw pair notification was incorrect')
  assert(structural.version(owners[1], opposites[1]) == 1, 'shared result did not advance its owner version')
  vim.api.nvim_buf_delete(view, { force = true })
end
syntax.source_is_active, syntax.refresh = is_active, refresh
print(('PASS: 16 dense diffs, only new sources/comparisons/marks, targeted completion; first %.1f ms, last %.1f ms (diagnostic)')
  :format(durations[1], durations[#durations]))
