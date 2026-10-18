local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.issue_fixture').new()
local options = require('git.features.issue_options')
local model, view = require('git.features.issue_model'), require('git.features.issue')
local function same(actual, expected) assert(vim.deep_equal(actual, expected), vim.inspect(actual)) end
same(options.parse('', false), { state = 'open', limit = 50 })
local filters, selector = options.parse('--state=all --limit 20 --label "help wanted" --label bug --assignee @me', true)
same(filters, { state = 'all', limit = 20, labels = 'help wanted,bug', assignee = '@me' }); assert(not selector)
same(options.parse('-s closed -L 100 -l help\\ wanted -a bob', false),
  { state = 'closed', limit = 100, labels = 'help wanted', assignee = 'bob' })
local _, number = options.parse('7', true); assert(number == '7')
local _, url = options.parse(f.ctx.url, true); assert(url == f.ctx.url)
for _, args in ipairs({ '--state merged', '--limit 0', '--limit -2', '--limit 1.5', '--limit inf', '--limit nan',
  '--limit nope', '--state', '--state --limit 20', '--limit=', '--unknown open', '--label "unclosed', '7 --state open' }) do
  assert(not pcall(options.parse, args, true), 'Accepted invalid flags: ' .. args)
end
assert(not pcall(options.parse, '7', false))
local function complete(text)
  local result = vim.fn.getcompletion(text, 'cmdline'); return result
end
require('git.utils').set_buf_work_tree(0, f.root)
view.setup()
same(complete('GitIssueList --st'), { '--state' })
same(complete('GitIssue --state '), { 'open', 'closed', 'all' })
same(complete('GitIssueList --state cl'), { 'closed' })
same(complete('GitIssueList --state=cl'), { '--state=closed' })
same(complete('GitIssueList --limit 2'), { '20', '200' })
same(complete('GitIssueList --assignee @'), { '@me' })
same(complete('GitIssueList --state open --li'), { '--limit' })
assert(#f.calls == 0, 'Command completion performed remote/local Git IO')
-- A large repository is bounded before opening its picker, with no body reads.
f.list_items = {}
for index = 1, 1000 do f.list_items[index] = { number = index, title = 'Issue ' .. index,
  url = f.ctx.url:gsub('/7$', '/' .. index) } end
local list = f.run(function() return model.list(f.ctx) end)
assert(#list == 50 and #f.calls == 1, 'Default listing fetched the whole repository')
local function argument(argv, flag)
  for index, value in ipairs(argv) do if value == flag then return argv[index + 1] end end
end
local call = f.calls[#f.calls]
assert(call[2] == 'issue' and call[3] == 'list' and argument(call, '--state') == 'open' and argument(call, '--limit') == '50')
assert(argument(call, '--json') == 'number,title,url' and argument(call, '--repo') == 'ghe.example.test/org/repo')
assert(not vim.tbl_contains(call, '--paginate'), 'List still requests unbounded pagination')
local select, selection = vim.ui.select, nil
vim.ui.select = function(items, opts, callback) selection = { items = items, opts = opts, callback = callback } end
vim.cmd('GitIssueList --state all --limit 20 --label "help wanted" --assignee @me')
f.wait(function() return selection ~= nil end)
assert(#selection.items == 24 and selection.opts.prompt:find('all · limit 20', 1, true))
call = f.calls[#f.calls]
assert(argument(call, '--state') == 'all' and argument(call, '--limit') == '20'
  and argument(call, '--label') == 'help wanted' and argument(call, '--assignee') == '@me')
-- Changing state and labels from the picker retains the cap and other filters.
local previous = selection
selection.callback(selection.items[1]); f.wait(function() return selection ~= previous end)
call = f.calls[#f.calls]
assert(argument(call, '--state') == 'open' and argument(call, '--limit') == '20' and argument(call, '--assignee') == '@me')
selection = nil
vim.cmd('GitIssue --state closed --limit=10')
f.wait(function() return selection ~= nil end)
assert(#selection.items == 14 and selection.opts.prompt:find('closed · limit 10', 1, true))
local calls = #f.calls
vim.cmd('GitIssueList --state typo')
vim.cmd('GitIssue --limit 0')
assert(#f.calls == calls and f.notifications[#f.notifications].message:find('positive integer', 1, true), 'Invalid command reached GitHub')
-- Flags never change number/URL detail opening.
local opened, original = nil, view.open
view.open = function(ctx) opened = ctx end
vim.cmd('GitIssue 7'); assert(opened.number == 7 and opened.url == nil)
vim.cmd('GitIssue ' .. f.ctx.url); assert(opened.url == f.ctx.url and opened.number == nil)
view.open, vim.ui.select = original, select
f.cleanup()
print('PASS: bounded Issue listing, server filters, local command/value completion, quoted/equals flags, invalid inputs, picker filter retention and unchanged detail selectors')
