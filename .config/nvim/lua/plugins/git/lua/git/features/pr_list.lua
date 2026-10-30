-- Enrich already visible identities with small, sequential, read-only queries.
local M = {}
local github = require('git.features.github')
local async = require('git.features.async')
M.fields = 'number,title,headRefName,headRefOid,isDraft,url,author,createdAt'
local batch_size = 5
local function query(batch)
  local fields = {}
  for index, pr in ipairs(batch) do
    fields[#fields + 1] = ('p%d:pullRequest(number:%d){number url headRefOid reviewDecision mergeable mergeStateStatus '
      .. 'commits(last:1){nodes{commit{statusCheckRollup{contexts{checkRunCount statusContextCount '
      .. 'checkRunCountsByState{state count} statusContextCountsByState{state count}}}}}}}'):format(index, pr.number)
  end
  return 'query($owner:String!,$name:String!){repository(owner:$owner,name:$name){'
    .. table.concat(fields, ' ') .. '}}'
end
local function counts(pr)
  local nodes = pr.commits and pr.commits.nodes
  assert(type(nodes) == 'table', 'Missing PR check summary')
  local rollup = nodes[1] and nodes[1].commit and github.scalar(nodes[1].commit.statusCheckRollup)
  if not rollup then return { total = 0, failed = 0, pending = 0 } end
  local ctx = assert(rollup.contexts, 'Missing PR check counts')
  assert(type(ctx.checkRunCount) == 'number' and type(ctx.statusContextCount) == 'number',
    'Invalid PR check counts')
  local result = { total = ctx.checkRunCount + ctx.statusContextCount, failed = 0, pending = 0 }
  assert(type(ctx.checkRunCountsByState) == 'table' and type(ctx.statusContextCountsByState) == 'table',
    'Missing PR check states')
  for _, states in ipairs({ ctx.checkRunCountsByState, ctx.statusContextCountsByState }) do
    for _, state in ipairs(states) do
      assert(type(state.count) == 'number', 'Invalid PR check state count')
      if vim.tbl_contains({ 'FAILURE', 'ERROR', 'TIMED_OUT', 'CANCELLED', 'ACTION_REQUIRED', 'STARTUP_FAILURE', 'STALE' }, state.state) then
        result.failed = result.failed + state.count
      elseif not vim.tbl_contains({ 'SUCCESS', 'NEUTRAL', 'SKIPPED' }, state.state) then
        result.pending = result.pending + state.count
      end
    end
  end
  return result
end
function M.start(root, items, opts)
  opts = opts or {}
  local function current() return not opts.is_current or opts.is_current() end
  local function updated() if current() and opts.updated then opts.updated() end end
  return async.run(root, function()
    local groups, order, invalid = {}, {}, false
    for _, pr in ipairs(items) do
      local ctx = github.url_context(pr.url)
      if ctx and ctx.number == pr.number then
        local key = ctx.host .. '/' .. ctx.repo
        if not groups[key] then
          groups[key] = { ctx = vim.tbl_extend('force', ctx, { root = root }), items = {} }
          order[#order + 1] = key
        end
        pr.summary_state = 'loading'
        groups[key].items[#groups[key].items + 1] = pr
      else
        invalid = true
        pr.summary_state, pr.summary_error = 'unavailable', 'Invalid PR identity'
      end
    end
    if invalid then updated() end
    for _, key in ipairs(order) do
      local group = groups[key]
      local owner, name = group.ctx.repo:match('^([^/]+)/([^/]+)$')
      for first = 1, #group.items, batch_size do
        if not current() then return end
        local batch = vim.list_slice(group.items, first, first + batch_size - 1)
        local ok, response = pcall(github.api, group.ctx, 'graphql', {
          query = query(batch), variables = { owner = owner, name = name },
        }, nil, { timeout = 15000 })
        if not current() then return end
        local repository = ok and type(response) == 'table' and response.data
          and github.scalar(response.data.repository)
        for index, pr in ipairs(batch) do
          local node = type(repository) == 'table' and github.scalar(repository['p' .. index])
          local valid, value = pcall(function()
            assert(type(node) == 'table' and node.number == pr.number and node.url == pr.url,
              'Missing or changed PR summary')
            assert(not pr.headRefOid or pr.headRefOid == node.headRefOid,
              'PR changed while loading its summary; refresh')
            return counts(node)
          end)
          if valid then
            pr.ci_counts, pr.reviewDecision = value, node.reviewDecision
            pr.mergeable, pr.mergeStateStatus = node.mergeable, node.mergeStateStatus
            pr.summary_state, pr.summary_error = 'ready', nil
          else
            pr.summary_state = 'unavailable'
            pr.summary_error = not ok and tostring(response) or tostring(value)
          end
        end
        updated()
      end
    end
  end, function(ok, err)
    if not current() then return end
    if not ok then
      for _, pr in ipairs(items) do
        if pr.summary_state == 'loading' then
          pr.summary_state, pr.summary_error = 'unavailable', tostring(err)
        end
      end
      updated()
    end
    if opts.done then opts.done() end
  end)
end
return M
