-- nvim --headless --clean -u NONE -l tests/syntax_source_context.lua
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.rtp:prepend(plugin)
vim.opt.rtp:append(vim.fn.stdpath('data') .. '/site')
vim.opt.rtp:prepend(vim.fn.stdpath('data') .. '/lazy/nvim-treesitter/runtime')
local syntax = require('git.features.syntax_highlight')
local renderer = require('git.features.status_renderer')
local models = require('git.features.commit_model')
local structural = require('git.features.syntax_word_diff')
local ns = vim.api.nvim_create_namespace('fugitive_extension_syntax')
local root = vim.fn.tempname() .. ' syntax context'
vim.fn.mkdir(root, 'p')
local function git(args)
  local result = vim.system(vim.list_extend({ 'git', '-C', root }, args), { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
local function write(path, lines) vim.fn.writefile(lines, root .. '/' .. path) end
local function json(changes)
  local lines = { '{' }
  for i = 1, 40 do
    lines[#lines + 1] = ('  "entry_%d": {"commit": "%s"}%s'):format(i, changes[i] or 'base', i == 40 and '' or ',')
  end
  lines[#lines + 1] = '}'
  return lines
end
local function lua(limit, arguments)
  local lines = { 'function First.group(', '  name,', '  ' .. limit, ')', '  local result = name' }
  for i = 1, 12 do lines[#lines + 1] = '  result = result .. "first_' .. i .. '"' end
  vim.list_extend(lines, { '  return result', 'end', '', 'function Later.group(' .. arguments .. ')' })
  for i = 1, 12 do lines[#lines + 1] = '  local part_' .. i .. ' = name' end
  vim.list_extend(lines, { '  return name', 'end' })
  return lines
end
git({ 'init', '-qb', 'main' })
git({ 'config', 'user.name', 'Test' }); git({ 'config', 'user.email', 'test@example.invalid' })
git({ 'config', 'commit.gpgsign', 'false' })
write('data file.json', json({})); write('code file.lua', lua('limit', 'name'))
git({ 'add', '.' }); git({ 'commit', '-qm', 'base' })
write('data file.json', json({ [4] = 'staged' })); write('code file.lua', lua('max_count', 'name'))
git({ 'add', '.' })
write('data file.json', json({ [4] = 'staged', [15] = 'working', [30] = 'another' }))
write('code file.lua', lua('max_count', 'name, options'))
local buffer = vim.api.nvim_create_buf(false, true)
vim.b[buffer].git_dir = root .. '/.git'
local function snapshot()
  local lines = assert(renderer.snapshot(buffer, root))
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  return lines
end
local lines = snapshot()
for row, line in ipairs(lines) do
  if line:match('^Unstaged changes') or line:match('^Staged changes') then assert(renderer.set_diff(buffer, row, true)) end
end
lines = snapshot()
local function settle(buf)
  syntax.refresh(buf)
  assert(vim.wait(15000, function() return not syntax.is_pending(buf) end, 1), 'full source colors did not finish')
end
local function check(buf)
  local patch = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  local seen, keywords, properties = {}, 0, 0
  for _, mark in ipairs(marks) do
    local group = mark[4].hl_group or ''
    if group:match('^@') then
      assert(patch[mark[2] + 1]:match('^[ +-]'), 'full-file capture painted omitted/header text')
      seen[mark[2]] = seen[mark[2]] or {}
      seen[mark[2]][group] = true
    end
    assert(not group:match('^FugitiveExtNovel'), 'default unexpectedly recolored changed text')
  end
  for row, line in ipairs(patch) do
    if line:match('^[ +-]function ') then
      assert(seen[row - 1] and seen[row - 1]['@keyword.function.lua'], 'multiline/mixed-context function lost syntax color: ' .. line)
      keywords = keywords + 1
    elseif line:match('^[ +-]  "entry_') then
      assert(seen[row - 1] and seen[row - 1]['@property.json'], 'JSON member lost property color: ' .. line)
      properties = properties + 1
    end
  end
  assert(keywords >= 2 and properties >= 6, 'fixture did not expose enough contextual fragments')
end
local system, parser, setmark, compare = vim.system, vim.treesitter.get_string_parser, vim.api.nvim_buf_set_extmark, structural.compare
local counts = { reads = 0, parses = 0, marks = 0, comparisons = 0 }
vim.system = function(argv, ...)
  if argv[1] == 'git' and argv[3] == 'show' then counts.reads = counts.reads + 1 end
  return system(argv, ...)
end
vim.treesitter.get_string_parser = function(...) counts.parses = counts.parses + 1; return parser(...) end
vim.api.nvim_buf_set_extmark = function(...) counts.marks = counts.marks + 1; return setmark(...) end
structural.compare = function(old, new, ...)
  counts.comparisons = counts.comparisons + 1
  assert(#old.lines > 30 and #new.lines > 30, 'Lua/JSON compared a contextless fragment')
  return compare(old, new, ...)
end
syntax.attach(buffer, { diff_source = function(hunk) return renderer.highlight_source(buffer, hunk.start_line) end })
assert(counts.reads == 0 and counts.parses == 0 and counts.comparisons == 0, 'full source analysis blocked cold attach')
settle(buffer); check(buffer)
assert(counts.reads == 6, 'multiple hunks reread files, or staged/unstaged sources were mixed: ' .. counts.reads)
assert(counts.comparisons == 4, 'Lua/JSON did not share comparisons across hunks: ' .. counts.comparisons)
local warm = vim.deepcopy(counts)
for _ = 1, 50 do syntax.refresh(buffer) end
assert(vim.deep_equal(counts, warm), 'unchanged full-source colors recomputed or repainted')
vim.system, vim.treesitter.get_string_parser, vim.api.nvim_buf_set_extmark = system, parser, setmark
structural.compare = compare
vim.api.nvim_buf_delete(buffer, { force = true }); renderer.cleanup(buffer)

-- Exercise the actual Commit attachment and renamed old-path lookup too.
git({ 'add', '.' }); git({ 'mv', 'code file.lua', 'renamed code.lua' }); git({ 'commit', '-qm', 'target' })
local tip = git({ 'rev-parse', 'HEAD' })
local model = assert(models.load(root, tip))
local rename
for _, entry in ipairs(model.entries) do if entry.path == 'renamed code.lua' then rename = entry end end
assert(rename and rename.old_path == 'code file.lua')
assert(models.highlight_source(model, rename).old.object == model.base .. ':code file.lua')
local commit = require('git.features.commit')
commit.setup(vim.api.nvim_create_augroup('SyntaxContextCommit', { clear = true }))
local view = assert(commit.open({ work_tree = root, revision = tip }))
for row, line in ipairs(vim.api.nvim_buf_get_lines(view, 0, -1, false)) do
  if commit.entry_at(view, row) then
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    local mapping = vim.fn.maparg('>', 'n', false, true)
    assert(mapping.callback); mapping.callback()
    break
  end
end
-- Expand the second entry after render shifted its row.
for row, line in ipairs(vim.api.nvim_buf_get_lines(view, 0, -1, false)) do
  local entry, info = commit.entry_at(view, row)
  if entry and info.header and entry.path == 'renamed code.lua' then
    vim.api.nvim_win_set_cursor(0, { row, 0 }); vim.fn.maparg('>', 'n', false, true).callback(); break
  end
end
settle(view); check(view)
vim.api.nvim_buf_delete(view, { force = true })

-- A killed read must not accept a reopened request or publish its late result.
do
  local loader = require('git.features.highlight_sources').new()
  local pending, cancelled, old_calls, new_calls = {}, 0, 0, 0
  vim.system = function(argv, options, callback)
    pending[#pending + 1] = callback
    return { kill = function() cancelled = cancelled + 1 end }
  end
  local active = true
  local spec = { root = root, path = 'renamed code.lua',
    old = { object = tip .. ':renamed code.lua' }, new = { text = '' } }
  loader.request(spec, function() return active end, function() old_calls = old_calls + 1 end)
  assert(vim.wait(1000, function() return #pending == 1 end, 1))
  active = false; loader.prune()
  assert(cancelled == 1)
  loader.request(spec, function() return true end, function(sources)
    assert(sources and sources.old[1] == 'function Reopened()')
    new_calls = new_calls + 1
  end)
  assert(vim.wait(1000, function() return #pending == 2 end, 1), 'reopening joined a killed read')
  pending[1]({ code = 0, stdout = 'function Stale()\nend\n' })
  pending[2]({ code = 0, stdout = 'function Reopened()\nend\n' })
  assert(vim.wait(1000, function() return new_calls == 1 end, 1))
  assert(old_calls == 0, 'closed source received its late result')
  loader.close(); vim.system = system
end
vim.fn.delete(root, 'rf')
print('PASS: real staged/unstaged/renamed Commit source context, multiline declarations, disjoint JSON hunks, shared async reads and warm caches')
