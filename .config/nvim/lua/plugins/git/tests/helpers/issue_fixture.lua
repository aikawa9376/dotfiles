-- Fail closed: native Issue tests may only use gh repo/api/issue list, never Git or PR IO.
local M = {}
function M.new()
  local f = { root = vim.fn.tempname(), calls = {}, writes = {}, notifications = {}, delay = 2, viewer = 'viewer',
    issue = { number = 7, title = 'Issue title', body = 'Description\nSecond line', state = 'open', state_reason = vim.NIL,
      html_url = 'https://ghe.example.test/org/repo/issues/7', user = { login = 'author' },
      updated_at = '2026-10-18T00:00:00Z', labels = { { name = 'bug' } }, assignees = { { login = 'alice' } } },
    permissions = { viewerCanUpdate = true, viewerCanClose = true, viewerCanReopen = true, viewerCanLabel = true, viewerCanAssign = true },
    comments = { { id = 10, node_id = 'IC_10', body = 'Own reply', user = { login = 'viewer' },
      created_at = '2026-10-18T01:00:00Z', updated_at = '2026-10-18T01:00:00Z', reactions = { ['+1'] = 2 },
      issue_url = 'https://ghe.example.test/api/v3/repos/org/repo/issues/7',
      html_url = 'https://ghe.example.test/org/repo/issues/7#issuecomment-10' },
      { id = 11, node_id = 'IC_11', body = 'Conversation (99)\nM fake.lua\nCommits (8)', user = { login = 'other' },
        created_at = '2026-10-18T02:00:00Z', updated_at = '2026-10-18T02:00:00Z',
        issue_url = 'https://ghe.example.test/api/v3/repos/org/repo/issues/7' } },
    timeline = {
      { __typename = 'IssueComment', id = 'IC_10', url = 'https://ghe.example.test/org/repo/issues/7#issuecomment-10' },
      { __typename = 'LabeledEvent', id = 'EV_1', createdAt = '2026-10-18T01:30:00Z', actor = vim.NIL, label = { name = 'bug' } },
      { __typename = 'IssueComment', id = 'IC_11' },
    }, reactions = { { id = 31, content = '+1', user = { login = 'viewer' } }, { id = 32, content = '+1', user = { login = 'other' } } } }
  vim.fn.mkdir(f.root, 'p')
  f.ctx = { root = f.root, host = 'ghe.example.test', repo = 'org/repo', number = 7,
    url = f.issue.html_url, resource_kind = 'issue' }
  local system, notify = vim.system, vim.notify
  vim.notify = function(message, level) f.notifications[#f.notifications + 1] = { message = tostring(message), level = level } end
  local function response(argv, opts)
    assert(argv[1] == 'gh', 'Unexpected local Git/fetch/diff request: ' .. table.concat(argv, ' '))
    f.calls[#f.calls + 1] = vim.deepcopy(argv)
    if argv[2] == 'repo' then return { url = 'https://ghe.example.test/org/repo', nameWithOwner = 'org/repo' } end
    if argv[2] == 'issue' and argv[3] == 'list' then
      local limit
      for index, arg in ipairs(argv) do if arg == '--limit' then limit = tonumber(argv[index + 1]) end end
      assert(limit and limit > 0, 'Issue listing must have a finite limit')
      local items = f.list_items or { { number = f.issue.number, title = f.issue.title, url = f.issue.html_url },
        { number = 8, title = 'Defensive PR exclusion', pull_request = {} } }
      return vim.list_slice(items, 1, limit)
    end
    assert(argv[2] == 'api', 'Unexpected PR command: ' .. table.concat(argv, ' '))
    local path, method, payload
    for index, arg in ipairs(argv) do
      if arg:match('^repos/') or arg == 'user' or arg == 'graphql' then path = arg end
      if arg == '--method' then method = argv[index + 1] end
    end
    if opts.stdin then payload = vim.json.decode(opts.stdin) end
    method = method or (payload and 'POST' or 'GET')
    local call = { path = path, method = method, payload = payload }
    if method ~= 'GET' and path ~= 'graphql' then f.writes[#f.writes + 1] = call end
    if f.before then f.before(call) end
    if f.fail == path then error('fixture read/write failure: ' .. path) end
    if path == 'user' then return { login = f.viewer } end
    if path == 'graphql' then
      if payload.query:find('viewerCanUpdate', 1, true) then
        return { data = { repository = { issue = vim.tbl_extend('force', { id = 'I_7', number = 7, url = f.issue.html_url,
          title = f.issue.title, body = f.issue.body == vim.NIL and '' or f.issue.body, state = f.issue.state:upper(),
          stateReason = type(f.issue.state_reason) == 'string' and f.issue.state_reason:upper() or vim.NIL,
          updatedAt = f.issue.updated_at }, f.permissions) } } }
      end
      local cursor = payload.variables.cursor
      if f.timeline_fail_cursor and cursor == f.timeline_fail_cursor then error('timeline page failed') end
      local page = f.pages and f.pages[cursor == vim.NIL and 'first' or cursor or 'first']
      return { errors = f.timeline_errors, data = { repository = { issue = { number = 7,
        timelineItems = page or { nodes = f.timeline, pageInfo = { hasNextPage = false, endCursor = vim.NIL } } } } } }
    end
    local base = 'repos/org/repo'
    if path == base .. '/issues/7' then
      if method == 'PATCH' then
        for key, value in pairs(payload) do f.issue[key] = value end
        if payload.state == 'open' then f.issue.state_reason = 'reopened' end
      end
      return f.issue
    end
    if path == base .. '/issues' and method == 'POST' then
      return { number = 55, title = payload.title, body = payload.body, html_url = 'https://ghe.example.test/org/repo/issues/55' }
    end
    if path == base .. '/labels?per_page=100' then return { { { name = 'bug' }, { name = 'help wanted' } } } end
    if path == base .. '/assignees?per_page=100' then return { { { login = 'alice' }, { login = 'bob' } } } end
    if path == base .. '/issues/7/comments?per_page=100' then return f.comment_pages or { f.comments } end
    if path == base .. '/issues/7/comments' and method == 'POST' then
      local item = { id = 99, node_id = 'IC_99', body = payload.body, user = { login = f.viewer }, created_at = '2026-10-18T03:00:00Z' }
      f.comments[#f.comments + 1] = item; return item
    end
    if path == base .. '/issues/7/labels' then
      for _, label in ipairs(payload.labels) do f.issue.labels[#f.issue.labels + 1] = { name = label } end
      return f.issue.labels
    end
    if path:match('/issues/7/labels/') then
      local label = vim.uri_decode(path:match('/labels/(.*)$'))
      f.issue.labels = vim.tbl_filter(function(item) return item.name ~= label end, f.issue.labels)
      return nil
    end
    if path == base .. '/issues/7/assignees' then
      if method == 'POST' then f.issue.assignees[#f.issue.assignees + 1] = { login = payload.assignees[1] }
      else f.issue.assignees = vim.tbl_filter(function(item) return item.login ~= payload.assignees[1] end, f.issue.assignees) end
      return f.issue
    end
    local id = path:match('/issues/comments/(%d+)')
    if id then
      if path:find('/reactions', 1, true) then
        if method == 'GET' then return { f.reactions } end
        if method == 'DELETE' then
          local reaction_id = tonumber(path:match('/(%d+)$'))
          f.reactions = vim.tbl_filter(function(item) return item.id ~= reaction_id end, f.reactions); return nil
        end
        f.reactions[#f.reactions + 1] = { id = 33, content = payload.content, user = { login = f.viewer } }; return {}
      end
      for _, item in ipairs(f.comments) do if item.id == tonumber(id) then
        if method == 'PATCH' then item.body = payload.body end
        if method == 'DELETE' then f.deleted = item.id end
        return item
      end end
    end
    error('Unhandled Issue endpoint: ' .. tostring(path))
  end
  vim.system = function(argv, opts, callback)
    local ok, value = pcall(response, argv, opts or {})
    local result = { code = ok and 0 or 1, stdout = ok and (value and vim.json.encode(value) or '') or '', stderr = ok and '' or tostring(value) }
    local handle = { wait = function() return result end, kill = function() end }
    if callback then vim.defer_fn(function() callback(result) end, f.delay) end
    return handle
  end
  function f.wait(fn) assert(vim.wait(3000, fn, 2), 'Issue test timed out: ' .. vim.inspect(f.notifications)) end
  function f.run(fn, failure)
    local done, result, passed
    assert(require('git.features.async').run(f.root, fn, function(ok, value) passed, result, done = ok, value, true end))
    f.wait(function() return done end)
    if failure then assert(not passed and tostring(result):find(failure, 1, true), tostring(result))
    else assert(passed, tostring(result)) end
    return result
  end
  function f.cleanup()
    vim.system, vim.notify = system, notify
    vim.fn.delete(f.root, 'rf')
  end
  return f
end
return M
