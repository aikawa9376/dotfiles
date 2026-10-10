local M = {}
function M.new()
  local f = { root = vim.fn.tempname(), calls = {}, notifications = {}, delay = 2 }
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
    author = { login = 'author' }, statusCheckRollup = {
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
    local data, raw, error_code
    if argv[2] == 'repo' then data = { nameWithOwner = 'org/repo', url = 'https://ghe.example.test/org/repo', defaultBranchRef = { name = 'main' } }
    elseif argv[2] == 'pr' and argv[3] == 'view' then data = vim.deepcopy(f.pr)
    elseif argv[2] == 'pr' and argv[3] == 'list' then data = { f.pr }
    elseif argv[2] == 'pr' and argv[3] == 'create' then raw = f.pr.url .. '\n'
    elseif argv[2] == 'run' then data = { { databaseId = 11, name = 'Tests', status = 'completed', conclusion = 'failure', url = 'https://ghe.example.test/org/repo/actions/runs/11', headBranch = 'topic' } }
    elseif argv[2] == 'api' and vim.tbl_contains(argv, 'PATCH') then
      if f.write_error then error_code = 1; raw = ''
      else
        local payload = vim.json.decode(opts.stdin)
        f.pr.title, f.pr.body = payload.title, payload.body; data = f.pr
      end
    elseif argv[2] == 'api' and opts.stdin then
      if f.reply_error then error_code = 1; raw = '' else data = { id = 401 } end
    elseif argv[2] == 'api' then data = vim.deepcopy(f.comments)
    else raw = '' end
    local result = { code = error_code or 0, stdout = raw or vim.json.encode(data), stderr = error_code and 'server rejected write' or '' }
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
