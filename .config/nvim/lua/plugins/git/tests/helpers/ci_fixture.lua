local M = {}
function M.new()
  local f = require('helpers.pr_fixture').new()
  f.ci_calls, f.responses, f.ci_delay = {}, {}, 2
  local system, executable = vim.system, vim.fn.executable
  f.ci_run = { id = 901, node_id = 'CHECK901', name = 'test', app = { slug = 'github-actions' }, head_sha = f.head,
    status = 'completed', conclusion = 'failure', details_url = f.pr.statusCheckRollup[1].detailsUrl,
    output = { title = 'Test suite', summary = 'One assertion failed' } }
  f.ci_job = { id = 12, run_id = 11, run_attempt = 2, workflow_name = 'CI', head_sha = f.head,
    check_run_url = 'https://ghe.example.test/api/v3/repos/org/repo/check-runs/901',
    started_at = '2026-10-12T01:00:00Z', completed_at = '2026-10-12T01:00:42Z', steps = {
      { number = 1, name = 'Setup', status = 'completed', conclusion = 'success' },
      { number = 16, name = 'Run tests', status = 'completed', conclusion = 'failure' },
      { number = 17, name = 'Artifact', status = 'completed', conclusion = 'skipped' },
    } }
  local p = 'repos/org/repo/'
  f.responses[p .. 'commits/' .. f.head .. '/check-runs?filter=all&per_page=100&page=1'] = function() return { check_runs = { f.ci_run } } end
  f.responses[p .. 'commits/' .. f.head .. '/statuses?per_page=100&page=1'] = { { id = 19, context = 'external', state = 'pending', target_url = 'https://ci.example.test/build/1', description = 'Waiting for external CI' } }
  f.responses[p .. 'check-runs/901'] = function() return f.ci_run end
  f.responses[p .. 'check-runs/901/annotations?per_page=100&page=1'] = { { path = 'src/test.lua', start_line = 42, annotation_level = 'failure', message = 'Expected 200, got 401' } }
  f.responses[p .. 'actions/jobs/12'] = function() return f.ci_job end
  f.responses[p .. 'actions/jobs/12/steps/0/logs'] = { raw = 'SETUP\n' }
  f.responses[p .. 'actions/jobs/12/steps/1/logs'] = { raw = '\27[31mFAIL\27[0m\r\nExpected 200\0\n' }
  f.responses[p .. 'actions/jobs/12/logs'] = { raw = 'FULL JOB\n' }
  function f.count(fragment)
    local n = 0; for _, call in ipairs(f.ci_calls) do if call.path:find(fragment, 1, true) then n = n + 1 end end
    return n
  end
  vim.fn.executable = function(name) if name == 'circleci' then return f.modern_cli and 1 or 0 end; return executable(name) end
  vim.system = function(argv, opts, callback)
    local path
    if argv[1] == 'gh' and argv[2] == 'api' then
      for _, arg in ipairs(argv) do if arg:match('^repos/') then path = arg end end
      if not path or not (path:find('/check-runs', 1, true) or path:find('/statuses', 1, true) or path:find('/actions/', 1, true)) then return system(argv, opts, callback) end
    elseif argv[1] == 'curl' then path = assert(opts.stdin:match('url = "([^"]+)"'))
    elseif argv[1] == 'circleci' then path = table.concat(argv, ' ')
    else return system(argv, opts, callback) end
    f.ci_calls[#f.ci_calls + 1] = { path = path, argv = vim.deepcopy(argv), opts = opts }
    local response = f.responses[path]
    if type(response) == 'function' then response = response() end
    response = vim.deepcopy(response or { code = 1, stderr = 'gh: Not Found (HTTP 404)' })
    local output = response.raw or vim.json.encode(response)
    local result = { code = response.code or 0, stderr = response.stderr or '', stdout = output }
    if argv[1] == 'curl' then result.stdout = output .. '\n' .. tostring(response.http or 200) end
    local job = { killed = false, kill = function(self) self.killed = true end }
    vim.defer_fn(function()
      if opts.stdout then opts.stdout(nil, result.stdout); result.stdout = nil end
      callback(result)
    end, response.delay or f.ci_delay)
    return job
  end
  local cleanup = f.cleanup
  function f.cleanup() vim.fn.executable = executable; cleanup() end
  return f
end
return M
