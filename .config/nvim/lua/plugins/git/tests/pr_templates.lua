local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local actions = require('git.features.github_actions')
local view = require('git.features.pr')
local ctx = { root = f.root, url = f.pr.url }
local opened, pending, choices, requests, response
local pushes, system = 0, vim.system
vim.system = function(argv, opts, callback)
  if argv[1] == 'git' and vim.tbl_contains(argv, 'push') then pushes = pushes + 1 end
  return system(argv, opts, callback)
end
local open, input, select = view.open, vim.ui.input, vim.ui.select
view.open = function(target) opened = target end
vim.ui.input = function(_, callback) callback('Template PR $(literal) `title`') end
vim.ui.select = function(items, opts, callback)
  assert(opts.prompt == 'PR template')
  assert(opts.format_item(items[1]) == items[1].filename)
  choices, pending = items, callback
end
f.api_response = function(path, _, payload, opts)
  if path ~= 'graphql' or not payload.query:find('pullRequestTemplates', 1, true) then return end
  requests = (requests or 0) + 1
  assert(payload.variables.owner == 'org' and payload.variables.name == 'repo')
  assert(opts.cwd == f.root and opts.env.GH_HOST == 'ghe.example.test', 'Template lookup lost the captured repository/host')
  if response then return response end
end
local function wait(predicate)
  assert(vim.wait(5000, predicate, 10), table.concat(f.notifications, '\n'))
end
local function create_count()
  local count, last = 0, nil
  for _, call in ipairs(f.calls) do
    if call.argv[2] == 'pr' and call.argv[3] == 'create' then count, last = count + 1, call end
  end
  return count, last
end
local function start(templates)
  f.pull_request_templates = templates
  opened, pending, choices = nil, nil, nil
  actions.create_quick(ctx)
end
local body = '## 概要\n\n<!-- Keep this comment -->\n- [ ] 確認 $(literal) `code`\n'
-- A published default template wins over both commit bodies and dirty local files.
vim.fn.mkdir(f.root .. '/.github', 'p')
vim.fn.writefile({ 'Wrong local template' }, f.root .. '/.github/pull_request_template.md')
start({ { filename = '.github/PULL_REQUEST_TEMPLATE.md', body = body } })
vim.cmd('cd /tmp')
wait(function() return opened ~= nil end)
local _, created = create_count()
assert(created.opts.stdin == body and vim.tbl_contains(created.argv, '--body-file') and vim.tbl_contains(created.argv, '-'))
assert(not vim.tbl_contains(created.argv, '--fill') and not pending, 'A single template must be automatic and replace --fill')
assert(vim.tbl_contains(created.argv, 'Template PR $(literal) `title`') and created.opts.cwd == f.root)
assert(opened.url == f.pr.url and pushes == 1 and requests == 1)

-- Empty templates still override autofill; no templates retain the old defaults.
start({ { filename = 'pull_request_template.md', body = '' } })
wait(function() return opened ~= nil end)
_, created = create_count()
assert(created.opts.stdin == '' and not vim.tbl_contains(created.argv, '--fill'))
start({})
wait(function() return opened ~= nil end)
_, created = create_count()
assert(vim.tbl_contains(created.argv, '--fill') and not vim.tbl_contains(created.argv, '--body-file'))
response = { data = { data = { repository = { pullRequestTemplates = vim.NIL } } } }
start({}); wait(function() return opened ~= nil end)
_, created = create_count()
assert(vim.tbl_contains(created.argv, '--fill'), 'A null template list should retain commit defaults')
response = nil

local multiple = { { filename = 'bug.md', body = 'Bug body' }, { filename = 'feature.md', body = 'Feature body\n' } }
local before_create, before_push = create_count(), pushes
start(multiple)
wait(function() return pending ~= nil end)
assert(create_count() == before_create and pushes == before_push, 'Publishing started before template selection')
pending(choices[2])
wait(function() return opened ~= nil end)
_, created = create_count()
assert(created.opts.stdin == multiple[2].body)
before_create, before_push = create_count(), pushes
start(multiple); wait(function() return pending ~= nil end)
pending(nil)
assert(create_count() == before_create and pushes == before_push and not opened, 'Canceling template selection published a PR')

-- Failed/partial template reads must not silently publish commit text instead.
for _, failure in ipairs({
  { code = 1, raw = '', stderr = 'Template access failed' },
  { data = { errors = { { message = 'Forbidden' } }, data = { repository = { pullRequestTemplates = {} } } } },
  { data = { data = { repository = vim.NIL } } },
}) do
  response = failure
  local notices = #f.notifications
  start({}); wait(function() return #f.notifications > notices end)
  assert(create_count() == before_create and pushes == before_push and not opened)
end
response = nil

-- A delayed picker must not publish a different branch or new HEAD.
for _, change in ipairs({ 'branch', 'head' }) do
  start(multiple); wait(function() return pending ~= nil end)
  if change == 'branch' then f.git({ 'checkout', '-qb', 'switched' })
  else f.git({ 'commit', '--allow-empty', '-qm', 'New HEAD during template selection' }) end
  local notices = #f.notifications
  pending(choices[1]); wait(function() return #f.notifications > notices end)
  assert(f.notifications[#f.notifications]:find('Branch or HEAD changed', 1, true))
  assert(create_count() == before_create and pushes == before_push and not opened)
  if change == 'branch' then f.git({ 'checkout', '-q', 'topic' }) end
end
view.open, vim.ui.input, vim.ui.select = open, input, select
f.cleanup()
print('PASS: published PR templates, exact stdin, empty/absent/multiple templates, cancellation, read failures and stale branch/HEAD')
