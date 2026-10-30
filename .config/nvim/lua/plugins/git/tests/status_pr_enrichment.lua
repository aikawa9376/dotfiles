-- A 75-PR repository remains usable while small summary requests settle.
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
vim.g.git_status_auto_fetch = false
package.loaded['git.features.status_watch'] = { subscribe = function() return function() end end }
package.loaded['git.features.worktree_watch'] = { subscribe = function() return function() end end }
package.loaded['git.features.status_probe'] = { new = function()
  return { check = function() end, stop = function() end }
end }
local system, executable = vim.system, vim.fn.executable
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
for _, args in ipairs({ { 'init', '-qb', 'main' },
  { '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '--allow-empty', '-qm', 'initial' } }) do
  local argv = { 'git', '-C', root }; vim.list_extend(argv, args)
  local result = system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end
local prs = {}
for number = 1, 75 do
  prs[number] = { number = number, title = 'Pull request ' .. number, headRefName = 'topic-' .. number,
    headRefOid = string.rep('a', 40), author = { login = 'author' },
    url = 'https://github.com/org/repo/pull/' .. number }
end
local lists, details, active, peak = {}, {}, 0, 0
vim.fn.executable = function(name) return name == 'gh' and 1 or executable(name) end
vim.system = function(argv, opts, done)
  if argv[1] ~= 'gh' then return system(argv, opts, done) end
  assert(opts.cwd == root)
  if argv[2] == 'pr' then
    lists[#lists + 1] = argv
    local fields = argv[vim.fn.index(argv, '--json') + 2]
    for _, field in ipairs({ 'statusCheckRollup', 'mergeable', 'reviewDecision', 'mergeStateStatus' }) do
      assert(not fields:find(field, 1, true), 'Initial list still requests expensive status fields')
    end
    assert(argv[vim.fn.index(argv, '--limit') + 2] == '100', 'Initial list dropped results')
    local result = vim.tbl_contains(argv, '--head') and {} or prs
    vim.schedule(function() done({ code = 0, stdout = vim.json.encode(result), stderr = '' }) end)
    return { kill = function() end }
  end
  assert(argv[2] == 'api' and vim.tbl_contains(argv, 'graphql'))
  assert(argv[vim.fn.index(argv, '--hostname') + 2] == 'github.com')
  assert(opts.timeout == 15000)
  local payload = vim.json.decode(opts.stdin)
  assert(payload.variables.owner == 'org' and payload.variables.name == 'repo')
  assert(not payload.query:find('contexts(first:', 1, true) and not payload.query:find('workflowRun', 1, true),
    'Summary fetched full CI details')
  local balance = 0
  for char in payload.query:gmatch('[{}]') do
    balance = balance + (char == '{' and 1 or -1); assert(balance >= 0)
  end
  assert(balance == 0, 'Unbalanced summary query')
  local job = { identities = {} }
  for alias, number in payload.query:gmatch('(p%d+):pullRequest%(number:(%d+)%)') do
    job.identities[#job.identities + 1] = { alias = alias, number = tonumber(number) }
  end
  assert(#job.identities > 0 and #job.identities <= 5, 'Summary query exceeded its batch size')
  active = active + 1; peak = math.max(peak, active)
  function job.reply(result)
    if not job.killed then active = active - 1 end
    done(result)
  end
  function job.kill() job.killed = true; active = active - 1 end
  details[#details + 1] = job
  return job
end
local status, loading = require('git.features.status'), require('git.features.loading')
status.setup(vim.api.nvim_create_augroup('StatusPrEnrichmentTest', { clear = true }))
local buf = assert(status.open({ work_tree = root, split = true }))
local function wait(fn) assert(vim.wait(5000, fn, 10), 'PR enrichment did not settle') end
local function text() return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end
local function row(number)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:match('^#' .. number .. ' ') then return i end
  end
end
local function item(number) return status.pull_request_at(buf, assert(row(number))) end
local function success(job, partial)
  local data = {}
  for _, identity in ipairs(job.identities) do
    local number = identity.number
    data[identity.alias] = { number = number, url = prs[number].url, headRefOid = prs[number].headRefOid,
      reviewDecision = 'APPROVED', mergeable = 'MERGEABLE', mergeStateStatus = 'CLEAN',
      commits = { nodes = { { commit = { statusCheckRollup = { contexts = {
        checkRunCount = 120, statusContextCount = 2,
        checkRunCountsByState = { { state = 'SUCCESS', count = 118 }, { state = 'FAILURE', count = 1 }, { state = 'QUEUED', count = 1 } },
        statusContextCountsByState = { { state = 'SUCCESS', count = 1 }, { state = 'PENDING', count = 1 } },
      } } } } } } }
  end
  if partial then data.p2 = vim.NIL end
  return { code = 0, stdout = vim.json.encode({ data = { repository = data },
    errors = partial and { { message = 'One PR unavailable', path = { 'repository', 'p2' } } } or nil }), stderr = '' }
end
wait(function() return #details == 1 and row(75) end)
assert(text():find('Pull requests (75) [all]', 1, true) and loading.busy(buf),
  'Full basic list was not published before summary requests completed')
assert(item(1).summary_state == 'loading' and item(75).summary_state == 'loading')
local header = row(1) - 1
vim.api.nvim_win_set_cursor(0, { header, 0 }); vim.cmd('normal! zo')
vim.api.nvim_win_set_cursor(0, { row(75), 0 })
for batch = 1, 15 do
  wait(function() return details[batch] ~= nil end)
  local result
  if batch == 2 then result = { code = 1, stdout = '<html>Bad gateway</html>', stderr = 'gh: HTTP 502: Bad Gateway' }
  elseif batch == 3 then result = { code = 0, stdout = '{broken JSON', stderr = '' }
  else result = success(details[batch], batch == 4) end
  details[batch].reply(result)
  if batch < 15 then wait(function() return #details == batch + 1 end) end
end
wait(function() return not loading.busy(buf) end)
assert(#lists == 2 and #details == 15 and peak == 1 and active == 0,
  'Summary reads overlapped or introduced per-PR requests')
assert(item(1).ci_counts.total == 122 and item(1).ci_counts.failed == 1 and item(1).ci_counts.pending == 2,
  'Aggregate CI counts were truncated or misclassified')
assert(require('git.features.github').summary(item(1)) == 'CI: ✗ 1/122 · Review: approved · mergeable')
assert(item(6).summary_state == 'unavailable' and item(6).summary_error:find('502', 1, true))
assert(item(11).summary_state == 'unavailable' and item(11).summary_error:find('Invalid JSON', 1, true))
assert(item(16).summary_state == 'ready' and item(17).summary_state == 'unavailable'
  and item(18).summary_state == 'ready', 'Partial GraphQL failure hid successful summaries')
assert(item(75).summary_state == 'ready' and not text():find('Pull requests: unavailable', 1, true),
  'An optional failure replaced the list or stopped later batches')
-- Repository/commit enrichment can insert sections above the PR list meanwhile.
header = row(1) - 1
assert(vim.api.nvim_win_get_cursor(0)[1] == row(75) and vim.fn.foldclosed(header) == -1,
  ('Summary updates moved the cursor or reset user folds: cursor=%d expected=%d folded=%d'):format(
    vim.api.nvim_win_get_cursor(0)[1], row(75), vim.fn.foldclosed(header)))
for number = 1, 75 do assert(row(number) == header + number, 'List identities/order changed during enrichment') end

-- A refresh cancels old reads, including their spinner, and ignores late replies.
vim.fn.maparg('R', 'n', false, true).callback()
wait(function() return #details == 16 end)
local obsolete = details[16]
vim.fn.maparg('R', 'n', false, true).callback()
wait(function() return #details == 17 end)
assert(obsolete.killed)
obsolete.reply(success(obsolete))
vim.wait(20, function() return false end)
assert(item(1).summary_state == 'loading', 'Old details overwrote a refreshed list')
-- A stale PR head must not receive status from another revision.
local changed = vim.json.decode(success(details[17]).stdout)
changed.data.repository.p1.headRefOid = string.rep('b', 40)
details[17].reply({ code = 0, stdout = vim.json.encode(changed), stderr = '' })
wait(function() return #details == 18 end)
assert(item(1).summary_state == 'unavailable' and item(2).summary_state == 'ready')
local closing = details[18]
vim.api.nvim_buf_delete(buf, { force = true })
assert(closing.killed and not loading.busy(buf))
closing.reply(success(closing))
vim.wait(20, function() return false end)
vim.system, vim.fn.executable = system, executable
vim.cmd('cd /tmp'); vim.fn.delete(root, 'rf')
print('PASS: 75 basic PRs publish before bounded aggregate reads, partial/502/JSON failures, cursor/folds and refresh/close guards')
