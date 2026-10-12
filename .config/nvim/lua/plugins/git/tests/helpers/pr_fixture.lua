local M = {}
function M.new()
  local f = { root = vim.fn.tempname(), calls = {}, notifications = {}, delay = 2,
    viewer = 'viewer', reviews = {}, discussion = {}, next_id = 401 }
  vim.fn.mkdir(f.root, 'p')
  local system = vim.system
  function f.git(args, root)
    local argv = { 'git', '-C', root or f.root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid' }
    vim.list_extend(argv, args)
    local result = system(argv, { text = true }):wait()
    assert(result.code == 0, result.stderr)
    return vim.trim(result.stdout or '')
  end
  f.git({ 'init', '-qb', 'main' })
  vim.fn.writefile({ 'one', 'two', 'three' }, f.root .. '/file name.txt')
  vim.fn.writefile({ 'rename this' }, f.root .. '/old.txt')
  vim.fn.writefile({ 'delete this' }, f.root .. '/deleted.txt')
  f.git({ 'add', '.' }); f.git({ 'commit', '-qm', 'base' })
  f.base = f.git({ 'rev-parse', 'HEAD' })
  f.git({ 'checkout', '-qb', 'topic' })
  vim.fn.writefile({ 'one', 'TWO', 'three', 'four' }, f.root .. '/file name.txt')
  vim.fn.writefile({ 'new' }, f.root .. '/added.txt')
  f.git({ 'mv', 'old.txt', 'new.txt' }); f.git({ 'rm', 'deleted.txt' })
  f.git({ 'add', '.' }); f.git({ 'commit', '-qm', 'topic' })
  f.head = f.git({ 'rev-parse', 'HEAD' })
  f.git({ 'update-ref', 'refs/pull/7/head', f.head })
  f.git({ 'checkout', '-q', 'main' })
  vim.fn.writefile({ 'base moved' }, f.root .. '/base-only.txt')
  f.git({ 'add', '.' }); f.git({ 'commit', '-qm', 'base advanced' })
  f.base_head = f.git({ 'rev-parse', 'HEAD' })
  f.git({ 'checkout', '-q', 'topic' })
  f.git({ 'remote', 'add', 'origin', f.root })
  vim.fn.writefile({ 'uncommitted' }, f.root .. '/dirty.txt')
  f.pr = { number = 7, title = 'PR title', body = 'Description\nSecond line', url = 'https://ghe.example.test/org/repo/pull/7',
    state = 'OPEN', isDraft = false, baseRefName = 'main', baseRefOid = f.base_head,
    headRefName = 'topic', headRefOid = f.head, reviewDecision = 'REVIEW_REQUIRED', mergeable = 'MERGEABLE', mergeStateStatus = 'BLOCKED',
    author = { login = 'author' }, additions = 3, deletions = 2, changedFiles = 4,
    createdAt = '2026-10-09T00:00:00Z', updatedAt = '2026-10-10T00:00:00Z', statusCheckRollup = {
      { name = 'test', status = 'COMPLETED', conclusion = 'FAILURE', detailsUrl = 'https://ghe.example.test/org/repo/actions/runs/11/job/12' },
      { context = 'external', state = 'PENDING', targetUrl = 'https://ci.example.test/build/1' },
    } }
  f.comments = { {
    { id = 101, path = 'file name.txt', side = 'RIGHT', line = 2, body = 'Please explain', user = { login = 'reviewer' }, html_url = f.pr.url .. '#discussion_r101' },
    { id = 102, in_reply_to_id = 101, path = 'file name.txt', side = 'RIGHT', line = 2, body = 'Existing reply', user = { login = 'author' } },
    { id = 201, path = 'file name.txt', side = 'LEFT', line = 2, body = 'Removed line', user = { login = 'reviewer' } },
  }, {
    { id = 301, path = 'new.txt', side = 'RIGHT', line = vim.NIL, body = 'Outdated', user = { login = 'reviewer' } },
  } }
  f.original_system, f.original_notify = vim.system, vim.notify
  vim.notify = function(message) f.notifications[#f.notifications + 1] = tostring(message) end
  vim.system = function(argv, opts, callback)
    if argv[1] ~= 'gh' then return system(argv, opts, callback) end
    f.calls[#f.calls + 1] = { argv = vim.deepcopy(argv), opts = vim.deepcopy(opts) }
    local data, raw, error_code, error_stderr
    if argv[2] == 'repo' then data = { nameWithOwner = 'org/repo', url = 'https://ghe.example.test/org/repo', defaultBranchRef = { name = 'main' } }
    elseif argv[2] == 'pr' and argv[3] == 'view' then
      -- Real gh rejects --repo without a number/URL/branch selector.
      if vim.tbl_contains(argv, '--repo') and (not argv[4] or argv[4]:sub(1, 1) == '-') then
        error_code = 1; raw = ''
      else data = vim.deepcopy(f.pr) end
    elseif argv[2] == 'pr' and argv[3] == 'list' then data = { f.pr }
    elseif argv[2] == 'pr' and argv[3] == 'create' then raw = f.pr.url .. '\n'
    elseif argv[2] == 'run' then data = f.runs or { { databaseId = 11, name = 'Tests', status = 'completed', conclusion = 'failure', url = 'https://ghe.example.test/org/repo/actions/runs/11', headBranch = 'topic' } }
    elseif argv[2] == 'api' then
      local path, method
      for i, arg in ipairs(argv) do
        if arg == 'user' or arg == 'graphql' or arg:match('^repos/') then path = arg:gsub('%?.*$', '') end
        if arg == '--method' then method = argv[i + 1] end
      end
      method = method or 'GET'
      local payload = opts.stdin and vim.json.decode(opts.stdin)
      if payload and method == 'GET' then method = 'POST' end
      local reject = f.api_before and f.api_before(path, method, payload)
      local id = path and tonumber(path:match('/reviews/(%d+)'))
      local review
      for _, item in ipairs(f.reviews) do if item.id == id then review = item end end
      local function new_comment(input)
        local comment = { id = f.next_id, node_id = 'COMMENT' .. f.next_id, body = input.body, path = input.path,
          line = input.line or vim.NIL, start_line = input.start_line or input.startLine or vim.NIL, side = input.side,
          original_line = input.line or vim.NIL, original_start_line = input.start_line or input.startLine or vim.NIL,
          commit_id = review and review.commit_id or input.commit_id,
          original_commit_id = review and review.commit_id or input.commit_id,
          subject_type = (input.subject_type or input.subjectType or (input.line and 'line' or 'file')):lower(),
          user = { login = f.viewer }, html_url = f.pr.url .. '#discussion_r' .. f.next_id }
        f.next_id = f.next_id + 1
        return comment
      end
      if reject then error_code = 1; raw = ''
      elseif path == 'user' then
        if f.review_read_error then error_code = 1; raw = '' else data = { login = f.viewer } end
      elseif path == 'repos/org/repo/pulls/7' and method == 'PATCH' then
        if f.write_error then error_code = 1; raw = ''
        else f.pr.title, f.pr.body = payload.title, payload.body; data = f.pr end
      elseif method ~= 'GET' and f.comment_error then error_code = 1; raw = ''
      elseif path == 'repos/org/repo/pulls/7/reviews' then
        if method == 'GET' then data = { vim.deepcopy(f.reviews) }
        else
          data = { id = f.next_id, node_id = 'REVIEW' .. f.next_id, commit_id = payload.commit_id,
            state = ({ APPROVE = 'APPROVED', REQUEST_CHANGES = 'CHANGES_REQUESTED', COMMENT = 'COMMENTED' })[payload.event] or 'PENDING',
            body = payload.body or '', comments = {}, user = { login = f.viewer } }
          f.next_id = f.next_id + 1
          f.reviews[#f.reviews + 1] = data
          if payload.event then f.last_event = payload.event end
        end
      elseif path == 'repos/org/repo/issues/7/comments' and method == 'GET' then
        if f.discussion_error then error_code = 1; raw = ''; error_stderr = 'Discussion read failed'
        else data = vim.deepcopy(f.discussion_pages or { f.discussion }) end
      elseif id and method == 'DELETE' then
        data = review
        f.reviews = vim.tbl_filter(function(item) return item.id ~= id end, f.reviews)
      elseif id and method == 'PUT' then review.body = payload.body; data = review
      elseif id and path:match('/events$') then
        review.state, review.body = ({ APPROVE = 'APPROVED', REQUEST_CHANGES = 'CHANGES_REQUESTED', COMMENT = 'COMMENTED' })[payload.event], payload.body
        f.last_event = payload.event
        for _, comment in ipairs(review.comments) do f.comments[1][#f.comments[1] + 1] = vim.deepcopy(comment) end
        data = review
      elseif id and path:match('/comments$') then
        local comments = vim.deepcopy(review.comments)
        if f.legacy_review_coordinates then
          for _, comment in ipairs(comments) do
            for _, field in ipairs({ 'line', 'start_line', 'original_line', 'original_start_line', 'side', 'start_side', 'subject_type' }) do
              comment[field] = nil
            end
          end
        end
        data = { comments }
      elseif path == 'graphql' then
        if payload.query:find('viewerViewedState', 1, true) then
          if f.viewed_error then data = { errors = { { message = 'Viewed status rejected' } } }
          else
            local nodes = {}
            local paths = f.git({ 'diff', '--name-only', '-z', f.pr.baseRefOid .. '...' .. f.pr.headRefOid })
            for _, file in ipairs(vim.split(paths, '\0', { plain = true, trimempty = true })) do
              nodes[#nodes + 1] = { path = file, viewerViewedState = (f.viewed_states or {})[file] or 'UNVIEWED' }
            end
            local pages = f.viewed_pages or { nodes }
            local page = payload.variables.cursor and tonumber(payload.variables.cursor) or 1
            data = { data = { viewer = { login = f.viewed_viewer or f.viewer }, repository = { pullRequest = {
              id = f.viewed_id or 'PR7', headRefOid = f.viewed_head or f.pr.headRefOid, baseRefOid = f.viewed_base or f.pr.baseRefOid,
              files = { nodes = pages[page], pageInfo = f.viewed_page_info or { hasNextPage = page < #pages, endCursor = tostring(page + 1) } },
            } } } }
          end
        elseif payload.variables.input and payload.variables.input.pullRequestId then
          if f.viewed_mutation_error then data = { errors = { { message = 'Viewed update rejected' } } }
          else
            local input = payload.variables.input
            assert(input.pullRequestId == (f.viewed_id or 'PR7'), 'Invalid Viewed PR ID')
            local action = payload.query:find('unmarkFileAsViewed', 1, true) and 'unmarkFileAsViewed' or 'markFileAsViewed'
            f.viewed_states = f.viewed_states or {}
            f.viewed_states[input.path] = action == 'markFileAsViewed' and 'VIEWED' or 'UNVIEWED'
            for _, page in ipairs(f.viewed_pages or {}) do for _, file in ipairs(page) do
              if file.path == input.path then file.viewerViewedState = f.viewed_states[input.path] end
            end end
            f.viewed_writes = (f.viewed_writes or 0) + 1
            data = { data = { [action] = { pullRequest = { id = input.pullRequestId,
              headRefOid = f.viewed_head or f.pr.headRefOid, baseRefOid = f.viewed_base or f.pr.baseRefOid } } } }
          end
        elseif not payload.variables.input then
          if f.thread_status_error then data = { errors = { { message = 'Thread status rejected' } } }
          else
            local nodes, indexed = {}, {}
            local scalar = require('git.features.github').scalar
            local function add_thread(comment, state)
              if not comment.in_reply_to_id or comment.in_reply_to_id == vim.NIL then
                if indexed[comment.id] then return end
                indexed[comment.id] = true
                local anchor = (f.thread_anchors or {})[comment.id] or {}
                local revision = scalar(comment.original_commit_id) or scalar(comment.commit_id)
                local line, start = scalar(comment.line), scalar(comment.start_line)
                if state == 'PENDING' and revision == f.head and comment.subject_type ~= 'file' then
                  line = line or scalar(comment.original_line)
                  start = start or scalar(comment.original_start_line)
                end
                nodes[#nodes + 1] = vim.tbl_extend('force', { id = 'THREAD' .. comment.id,
                  isResolved = (f.resolved or {})[comment.id] == true,
                  viewerCanResolve = f.can_resolve ~= false, viewerCanUnresolve = f.can_unresolve ~= false,
                  isOutdated = revision ~= nil and revision ~= f.head,
                  path = comment.path, line = line or vim.NIL, startLine = start or vim.NIL,
                  diffSide = comment.side, subjectType = comment.subject_type and comment.subject_type:upper() or (line and 'LINE' or 'FILE'),
                  comments = { nodes = { { fullDatabaseId = tostring(comment.id), pullRequestReview = { state = state } } } } }, anchor)
              end
            end
            for _, review_item in ipairs(f.reviews) do if review_item.state == 'PENDING' then
              for _, comment in ipairs(review_item.comments) do add_thread(comment, 'PENDING') end
            end end
            for _, page in ipairs(f.comments) do for _, comment in ipairs(page) do add_thread(comment, 'COMMENTED') end end
            local pages = f.thread_pages or { nodes }
            local page = payload.variables.cursor and tonumber(payload.variables.cursor) or 1
            data = { data = { repository = { pullRequest = { headRefOid = f.thread_head or f.pr.headRefOid, reviewThreads = {
              nodes = pages[page], pageInfo = { hasNextPage = page < #pages, endCursor = tostring(page + 1) },
            } } } } }
          end
        elseif payload.variables.input.threadId then
          if f.resolve_error then data = { errors = { { message = 'Resolution rejected' } } }
          else
            local input = payload.variables.input
            local comment_id = tonumber(input.threadId:match('^THREAD(%d+)$'))
            assert(comment_id, 'Invalid resolution target')
            local action = payload.query:find('unresolveReviewThread', 1, true) and 'unresolveReviewThread' or 'resolveReviewThread'
            f.resolved = f.resolved or {}
            f.resolved[comment_id] = action == 'resolveReviewThread'
            data = { data = { [action] = { thread = { id = input.threadId, isResolved = f.resolved[comment_id] } } } }
          end
        elseif f.graphql_error then data = { errors = { { message = 'GraphQL rejected thread' } } }
        else
          local input = payload.variables.input
          for _, item in ipairs(f.reviews) do if item.node_id == input.pullRequestReviewId then review = item end end
          local comment = new_comment(input)
          review.comments[#review.comments + 1] = comment
          data = { data = { addPullRequestReviewThread = { thread = { id = 'THREAD' .. comment.id,
            comments = { nodes = { { fullDatabaseId = tostring(comment.id) } } } } } } }
        end
      elseif method == 'PATCH' and path:match('/pulls/comments/') then
        local comment_id = tonumber(path:match('/(%d+)$'))
        for _, item in ipairs(f.reviews) do for _, comment in ipairs(item.comments) do
          if comment.id == comment_id then comment.body = payload.body; data = comment end
        end end
      elseif method == 'DELETE' and path:match('/pulls/comments/') then
        local comment_id = tonumber(path:match('/(%d+)$'))
        for _, item in ipairs(f.reviews) do
          item.comments = vim.tbl_filter(function(comment) return comment.id ~= comment_id end, item.comments)
        end
        raw = '' -- REST returns 204 with no JSON body.
      elseif path == 'repos/org/repo/issues/7/comments' then
        data = new_comment(payload); f.discussion[#f.discussion + 1] = data
      elseif path == 'repos/org/repo/pulls/7/comments' and method == 'POST' then
        -- The reported failure persists even with the comfort-fade header.
        error_code = 1
        raw = vim.json.encode({ message = 'Invalid request.', errors = {
          'No subschema in "oneOf" matched.', '"positioning" wasn\'t supplied.',
          '"subject_type" is not a permitted key.', '"line" is not a permitted key.' } })
      elseif opts.stdin then
        if f.reply_error then error_code = 1; raw = '' else data = { id = 401 } end
      else data = vim.deepcopy(f.comments) end
      if f.api_after and f.api_after(path, method, payload, data) then error_code = 1; raw = '' end
    else raw = '' end
    local result = { code = error_code or 0,
      stdout = error_code and f.api_error_response or raw or vim.json.encode(data),
      stderr = error_code and (error_stderr or f.api_error_stderr or 'server rejected write') or '' }
    local handle = { wait = function() return result end, kill = function() end }
    if callback then vim.defer_fn(function() callback(result) end, f.delay) end
    return handle
  end
  local model = require('git.features.pr_model')
  f.original_remote = model.remote
  model.remote = function() return 'origin' end
  vim.cmd('cd ' .. vim.fn.fnameescape(f.root))
  function f.cleanup()
    model.remote = f.original_remote
    vim.system, vim.notify = f.original_system, f.original_notify
    vim.cmd('cd /tmp')
    vim.fn.delete(f.root, 'rf')
  end
  return f
end
return M
