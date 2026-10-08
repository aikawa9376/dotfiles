-- nvim --headless --clean -u NONE -l tests/syntax_native.lua (rustc builds a missing worker).
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.rtp:prepend(plugin)
vim.opt.rtp:append(vim.fn.stdpath('data') .. '/site')
vim.opt.rtp:prepend(vim.fn.stdpath('data') .. '/lazy/nvim-treesitter/runtime')
local structural = require('git.features.syntax_word_diff')
local native = require('git.features.syntax_native')
assert(vim.wait(120000, function() return native.command() ~= nil end, 10),
  'Rust worker unavailable; install rustc or set syntax_native.config.command')
native.config.min_nodes = 0
local fixtures = vim.json.decode(table.concat(vim.fn.readfile(plugin .. '/tests/fixtures/difftastic_word_diff.json'), '\n'))
-- Exercise the exact full-file scoping pass without adding a production API for tests.
local scope_pair
for index = 1, 100 do
  local name, value = debug.getupvalue(structural.compare_async, index)
  if not name then break end
  if name == 'scope_pair' then scope_pair = value; break end
end
assert(scope_pair, 'full-file comparison no longer exposes its scoping upvalue')
local function private(source)
  if source then return { code = source.code, lines = source.lines, offsets = source.offsets, lang = source.lang, tree = source.tree } end
end
local function pair(old, new, full, checkpoint)
  local left, right = private(old), private(new)
  if full and left and right and left.lang ~= 'markdown' and left.lang ~= 'markdown_inline'
    and not left.tree:root():has_error() and not right.tree:root():has_error() then
    scope_pair(left, right, checkpoint or function() end)
  end
  return left, right
end
local function compare(old, new, full)
  local done, value, deadline = false, nil, 0
  local thread = coroutine.create(function()
    local function checkpoint() if vim.uv.hrtime() > deadline then coroutine.yield() end end
    local left, right = pair(old, new, full, checkpoint)
    return structural.compare(left, right, { native = function() return true end,
      checkpoint = checkpoint })
  end)
  local function step()
    deadline = vim.uv.hrtime() + 3e6
    local ok, result = coroutine.resume(thread)
    assert(ok, result)
    if coroutine.status(thread) == 'dead' then value, done = result, true
    elseif type(result) == 'table' and result.wait then result.wait(function() vim.schedule(step) end)
    else vim.schedule(step) end
  end
  step()
  assert(vim.wait(30000, function() return done end, 1), 'native comparison did not finish')
  return value
end
local cases = 0
for _, case in ipairs(fixtures.cases) do
  local lang = vim.treesitter.language.get_lang(vim.filetype.match({ filename = case.name }))
  local old, new = structural.parse(case.before, lang), structural.parse(case.after, lang)
  local expected = structural.compare(private(old), private(new))
  assert(vim.deep_equal(compare(old, new), expected), case.name .. ': Rust changed Lua spans/emphasis/tie order')
  local left, right = pair(old, new, true)
  expected = structural.compare(left, right)
  assert(vim.deep_equal(compare(old, new, true), expected), case.name .. ': Rust changed scoped source coordinates')
  cases = cases + 1
end
assert(native.stats.started > 100 and native.stats.failed == 0, 'oracle comparisons silently used Lua fallback')
local old = structural.parse({ 'run(old)' }, 'lua')
local new = structural.parse({ 'run(new)' }, 'lua')
local expected = structural.compare(private(old), private(new))
for _, command in ipairs({ '/does/not/exist/git-syntax-search', '/bin/false', '/bin/echo' }) do
  native.config.command = command
  assert(vim.deep_equal(compare(old, new), expected), 'worker failure changed fallback spans')
end
native.config.command = nil
local syntax = require('git.features.syntax_highlight')
local system, killed = vim.system, 0
vim.system = function(command, opts, callback)
  if command[1] == native.command() then
    return { kill = function()
      killed = killed + 1
      vim.schedule(function() callback({ code = 143, stdout = '' }) end)
    end }
  end
  return system(command, opts, callback)
end
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'M held.lua', '@@ -1 +1 @@', '-run(old_held)', '+run(new_held)' })
syntax.attach(buf)
local started = native.stats.started
assert(vim.wait(10000, function() return native.stats.started > started end, 1), 'UI did not start its native worker')
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'M held.lua' })
syntax.refresh(buf)
assert(vim.wait(10000, function() return killed > 0 end, 1), 'closed hunk kept its native worker alive')
assert(not syntax.is_pending(buf), 'closed hunk retained pending native comparison')
assert(#vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace('git_extension_syntax'), 0, -1, {}) == 0,
  'native completion painted a closed hunk')
vim.api.nvim_buf_delete(buf, { force = true })
vim.system = system
print(('PASS: %d raw/scoped exact Lua/Rust cases, %d worker requests, helper fallback and UI cancellation'):format(cases, native.stats.started))
