-- Run from dotfiles: nvim --headless --clean -u NONE -l
-- .config/nvim/lua/plugins/blink-extension/tests/cmdline_spec.lua
local root = vim.fn.getcwd() .. '/.config/nvim/lua/plugins/blink-extension'
local lazy_root = vim.fn.stdpath('data') .. '/lazy/'
vim.opt.rtp:append(lazy_root .. 'blink.lib')
vim.opt.rtp:append(lazy_root .. 'blink.cmp')
vim.opt.rtp:append(root)

local task = require('blink.lib.task')
local fs = require('blink.lib.fs')
local Help = require('blink_extension.completion.cmdline_help')
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. '/doc', 'p')
vim.fn.writefile({
  ':FixtureTagged\tfixture.txt\t/*:FixtureTagged*',
  ':FixturePlugin\tfixture.txt\t/*:FixturePlugin*',
  'fixture.stage_hunk()\tfixture.txt\t/*fixture.stage_hunk()*',
  ':FixturePlugin-nested-run\tfixture.txt\t/*:FixturePlugin-nested-run*',
}, tmp .. '/doc/tags')
vim.fn.writefile({
  'Tagged command                                     *:FixtureTagged*',
  'Exact plugin help body.',
  '',
  'Next command                                       *:FixtureNext*',
  'Must not appear in the previous excerpt.',
  '',
  'COMMANDS',
  'See also `:FixtureListed` for an example.',
  '- `:FixtureListedExtra` must not match FixtureListed.',
  '- `:FixtureListed [ARG]` creates a fixture.',
  '    Wrapped explanation for the listed command.',
  '- `:FixtureOther` is another command.',
  '- `:FixtureFromCallback` documents a loaded plugin command.',
  '',
  '*:FixturePlugin*',
  'Generic parent description.',
  '',
  '*fixture.stage_hunk()*',
  'Stage the selected hunk in the fixture.',
  '',
  '*:FixturePlugin-nested-run*',
  'Run the nested fixture operation.',
  '',
  'SUBCOMMANDS',
  ':FixturePlugin sync [plugins]     Synchronize fixture plugins.',
  '                                 Wrapped sync description.',
  ':FixturePlugin sync_more         A different command.',
  ':FixturePlugin files file_icons=false',
  'An incidental usage example should lose to a definition table.',
  '',
  '| Command | Description |',
  '| `files` | Find fixture files. |',
  '| `files_extra` | Must not appear for files. |',
}, tmp .. '/doc/fixture.txt')

local lazy_config = package.loaded['lazy.core.config']
package.loaded['lazy.core.config'] = {
  plugins = {
    fixture = {
      dir = tmp,
      _ = { handlers = { cmd = { FixtureTagged = true, FixtureListed = true, FixturePlugin = true } } },
    },
  },
}
local cases = 0
local function check(name, fn)
  fn()
  cases = cases + 1
  print('ok - ' .. name)
end
local function contains(text, part) return text and text:find(part, 1, true) ~= nil end
local function wait_for(fn) assert(vim.wait(5000, fn, 5), 'timed out') end

local reads, active, max_active = 0, 0, 0
local real_read = fs.read
fs.read = function(...)
  reads, active = reads + 1, active + 1
  max_active = math.max(max_active, active)
  return real_read(...):map(function(data)
    active = active - 1
    return data
  end):catch(function(err)
    active = active - 1
    return task.reject(err)
  end)
end
local help = Help.new()
check('builtin help uses its exact tag', function()
  local doc = help:get('write', 0):wait(5000)
  assert(contains(doc.value, 'Write the whole buffer'))
  assert(contains(doc.value, ':help :write'))
end)
check('unloaded plugin help and bounded excerpts', function()
  local doc = help:get('FixtureTagged', 0):wait(5000)
  assert(contains(doc.value, 'Exact plugin help body.'))
  assert(not contains(doc.value, 'Must not appear'))
  assert(not package.loaded.fixture)
end)
check('plugin command lists work without individual tags', function()
  local doc = help:get('FixtureListed', 0):wait(5000)
  assert(contains(doc.value, 'creates a fixture.'))
  assert(contains(doc.value, 'Wrapped explanation'))
  assert(not contains(doc.value, 'must not match'))
  assert(not contains(doc.value, 'another command'))
  assert(not contains(doc.value, 'See also'))
end)
check('loaded plugin commands can locate help through their callbacks', function()
  local callback = assert(loadstring('return function() end', '@' .. tmp .. '/lua/fixture.lua'))()
  vim.api.nvim_create_user_command('FixtureFromCallback', callback, {})
  local doc = help:get('FixtureFromCallback', 0):wait(5000)
  assert(contains(doc.value, 'documents a loaded plugin command'))
end)
check('cached and concurrent lookups share file reads', function()
  local before = reads
  task.all({ help:get('FixtureListed', 0), help:get('FixtureListed', 0), help:get('write', 0) }):wait(5000)
  assert(reads == before)
  assert(max_active <= 4)
end)
check('buffer-local descriptions take precedence and stay fresh', function()
  vim.api.nvim_create_user_command('FixtureDesc', function() end, { desc = 'Global description' })
  vim.api.nvim_buf_create_user_command(0, 'FixtureDesc', function() end, { desc = 'Local description' })
  assert(contains(help:get('FixtureDesc', 0):wait(5000).value, 'Local description'))
  vim.api.nvim_buf_del_user_command(0, 'FixtureDesc')
  assert(contains(help:get('FixtureDesc', 0):wait(5000).value, 'Global description'))
  assert(help:get('FixtureMissing', 0):wait(5000) == nil)
end)
fs.read = real_read

local list = require('blink.cmp.completion.list')
local sources = require('blink.cmp.sources.lib')
local Provider = require('blink.cmp.sources.lib.provider')
local provider = Provider.new('cmdline', {
  module = 'blink_extension.completion.cmdline', opts = { documentation_delay_ms = 30 },
})
sources.providers.cmdline = provider
local source = provider.module
local function context(line)
  local keyword = line:match('[%w_]*$')
  local bounds = { start_col = #line - #keyword + 1, length = #keyword }
  return {
    id = 123, mode = 'cmdwin', line = line,
    pos = { row = 0, col = #line }, bounds = bounds,
    get_bounds = function() return bounds end,
  }
end
local function completions(line)
  local response
  source:get_completions(context(line), function(result) response = result end)
  wait_for(function() return response ~= nil end)
  return response.items
end
check('native command completions and text edits are preserved', function()
  local items = completions('wri')
  for _, item in ipairs(items) do
    if item.label == 'write' then
      assert(item.data.command_documentation.command == 'write')
      assert(item.textEdit.newText == 'write')
      assert(item.textEdit.insert.start.character == 0)
      return
    end
  end
  error('write completion missing')
end)
check('filenames and command arguments receive no command documentation', function()
  for _, item in ipairs(completions('edit ' .. tmp .. '/doc/')) do
    assert(not (item.data and item.data.command_documentation))
  end
end)

local Context = require('blink_extension.completion.cmdline_context')
vim.api.nvim_create_user_command('FixturePlugin', function() end, {
  nargs = '*',
  range = true,
  complete = function(_, line)
    if line:find('nested ', 1, true) then return { 'run', 'stop' } end
    return { 'files', 'stage_hunk', 'sync', 'sync_more', 'nested', 'write', 'missing' }
  end,
})
local function argument_doc(line, label)
  local candidates = completions(line)
  for _, candidate in ipairs(candidates) do
    if candidate.label == label then
      local data = candidate.data and candidate.data.command_documentation
      assert(data, 'documentation context missing: ' .. line .. ' -> ' .. label)
      local query = Context.resolve(data)
      assert(query, 'query missing: ' .. line .. ' -> ' .. label)
      return help:get(query.command, data.bufnr, query):wait(5000), query, candidate
    end
  end
  local labels = vim.tbl_map(function(candidate) return candidate.label end, candidates)
  error('completion missing: ' .. line .. ' -> ' .. label .. ' (candidates: ' .. table.concat(labels, ', ') .. ')')
end
check('set options, short aliases, scopes, negation, inversion and values', function()
  for _, test in ipairs({
    { 'set nu', 'number', "'number'" },
    { 'setlocal rnu', 'relativenumber', "'relativenumber'" },
    { 'setglobal nonu', 'number', "'number'" },
    { 'set invnu', 'number', "'number'" },
    { 'set bg=d', 'dark', "'background'" },
    { 'set nu bg=d', 'dark', "'background'" },
  }) do
    local doc, query = argument_doc(test[1], test[2])
    assert(query.tags[1] == test[3], vim.inspect(query))
    assert(contains(doc.value, ':help ' .. test[3]), vim.inspect(doc))
    assert(contains(doc.value, 'Type:'))
  end
  for _, token in ipairs({ 'nonumber', 'invnu', 'invic' }) do
    local ctx = context('set ' .. token)
    local data = Context.item(Context.capture(ctx, '', 0), {
      label = token,
      textEdit = { newText = token, range = { start = { character = 4 }, ['end'] = { character = #ctx.line } } },
    })
    local query = Context.resolve(data)
    assert(query and query.tags[1] == (token == 'invic' and "'ignorecase'" or "'number'"))
  end
end)
check('help tags, autocmd events, highlight groups and Vim functions', function()
  for _, test in ipairs({
    { "help 'nu", "'number'", "'number'" },
    { 'autocmd BufE', 'BufEnter', 'BufEnter' },
    { 'doautocmd BufE', 'BufEnter', 'BufEnter' },
    { 'highlight Nor', 'Normal', 'hl-Normal' },
    { 'call ab', 'abs(', 'abs()' },
    { 'echo strl', 'strlen(', 'strlen()' },
  }) do
    local doc = argument_doc(test[1], test[2])
    assert(doc and contains(doc.value, ':help ' .. test[3]), vim.inspect(doc))
  end
end)
check('builtin subcommands use contextual help tags', function()
  for _, test in ipairs({
    { 'syntax k', 'keyword', ':syn-keyword' },
    { 'sign d', 'define', ':sign-define' },
    { 'command -na', 'nargs', ':command-nargs' },
  }) do
    local doc = argument_doc(test[1], test[2])
    assert(doc and contains(doc.value, ':help ' .. test[3]), vim.inspect(doc))
  end
end)
check('plugin subcommands resolve namespaced function and nested tags', function()
  local doc = argument_doc('FixturePlugin stage', 'stage_hunk')
  assert(doc and contains(doc.value, 'Stage the selected hunk'))
  doc = argument_doc('FixturePlugin nested r', 'run')
  assert(doc and contains(doc.value, 'Run the nested fixture operation'))
end)
check('untagged subcommands use exact command rows and table cells', function()
  local doc = argument_doc('FixturePlugin sy', 'sync')
  assert(doc and contains(doc.value, 'Synchronize fixture plugins'))
  assert(contains(doc.value, 'Wrapped sync description'))
  assert(not contains(doc.value, 'A different command'))
  doc = argument_doc('FixturePlugin fi', 'files')
  assert(doc and contains(doc.value, 'Find fixture files'))
  assert(not contains(doc.value, 'Must not appear for files'))
  assert(not contains(doc.value, 'incidental usage example'))
end)
check('unknown subcommands never fall back to unrelated commands or parent descriptions', function()
  assert(argument_doc('FixturePlugin wr', 'write') == nil)
  assert(argument_doc('FixturePlugin mi', 'missing') == nil)
end)
check('modifiers, ranges and chained commands keep argument context', function()
  local doc = argument_doc('silent FixturePlugin sy', 'sync')
  assert(doc and contains(doc.value, 'Synchronize fixture plugins'))
  doc = argument_doc('1FixturePlugin sy', 'sync')
  assert(doc and contains(doc.value, 'Synchronize fixture plugins'))
  doc = argument_doc('set number | set nu', 'number')
  assert(doc and contains(doc.value, ":help 'number'"))
end)

local function item(command)
  return {
    label = command, source_id = 'cmdline',
    data = { command_documentation = { command = command, bufnr = vim.api.nvim_get_current_buf() } },
  }
end
local a, b = item('FixtureTagged'), item('FixtureListed')
local function select(selected)
  list.context = context('Fixture')
  list.items, list.selected_item_idx = { a, b }, selected
  list.select_emitter:emit({ item = selected and list.items[selected], context = list.context })
end
check('rapid selection cancels obsolete provider tasks before I/O', function()
  local lookups = 0
  source.help = { get = function()
    lookups = lookups + 1
    return task.resolve({ kind = 'markdown', value = 'Fixture documentation' })
  end }
  select(1)
  local first = provider:resolve(list.context, a)
  select(2)
  local second = provider:resolve(list.context, b)
  assert(first.status == task.STATUS.CANCELLED)
  local result = second:wait(5000)
  assert(result.documentation.value == 'Fixture documentation')
  assert(lookups == 1)
end)
check('late reads cannot display stale documentation and revisits retry', function()
  source:reload()
  provider.resolve_cache = {}
  local finish, started
  source.help = { get = function()
    started = true
    return task.new(function(resolve) finish = resolve end)
  end }
  select(1)
  local first = provider:resolve(list.context, a)
  wait_for(function() return started end)
  local displayed = false
  first:map(function() displayed = true end)
  select(2)
  finish({ kind = 'markdown', value = 'Stale' })
  assert(first.status == task.STATUS.CANCELLED)
  assert(not displayed)
  source.help = help
  select(1)
  assert(contains(provider:resolve(list.context, a):wait(5000).documentation.value, 'Exact plugin help'))
end)
check('selection changes also cancel results already scheduled by Blink', function()
  source:reload()
  provider.resolve_cache = {}
  local finish
  source.help = { get = function()
    return task.new(function(resolve) finish = resolve end)
  end }
  select(1)
  local pending = provider:resolve(list.context, a)
  local displayed = false
  pending:map(function() displayed = true end)
  wait_for(function() return finish ~= nil end)
  finish({ kind = 'markdown', value = 'Already scheduled' })
  assert(pending.status == task.STATUS.RUNNING)
  select(2)
  assert(pending.status == task.STATUS.CANCELLED)
  vim.wait(20, function() return false end)
  assert(not displayed)
end)
check('prefetch without a selection does not start help I/O', function()
  source:reload()
  provider.resolve_cache = {}
  local lookups = 0
  source.help = { get = function() lookups = lookups + 1; return task.resolve() end }
  select(nil)
  local pending = provider:resolve(list.context, a)
  wait_for(function() return pending.status == task.STATUS.CANCELLED end)
  assert(lookups == 0)
end)
check('closing the menu cancels pending documentation', function()
  provider.resolve_cache = {}
  select(2)
  local pending = provider:resolve(list.context, b)
  list.context = nil
  list.hide_emitter:emit({})
  assert(pending.status == task.STATUS.CANCELLED)
  -- Blink hides the menu before accepting. Its new resolve must finish immediately.
  local accepted = provider:resolve(context('Fixture'), b)
  assert(accepted.status == task.STATUS.RUNNING) -- provider schedules the callback
  assert(accepted:wait(5000).label == 'FixtureListed')
  assert(not source.state.pending)
end)

source:reload()
package.loaded['lazy.core.config'] = lazy_config
vim.fn.delete(tmp, 'rf')
print(string.format('%d command documentation checks passed', cases))
