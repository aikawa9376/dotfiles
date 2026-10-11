-- Coroutine Git workflows with cancellable subprocesses and joined reads.
local M = {}
local tasks, owners = {}, {}
local leaving = false

function M.running()
  return tasks[coroutine.running()]
end

function M.busy(root) return owners[root] ~= nil end

-- Independent reads return settled results in input order. The parent keeps
-- worktree ownership until every child completes; children never acquire it.
function M.gather(reads)
  local task = assert(M.running(), 'Workflow must run inside async.run')
  if leaving or task.cancelled then error('Workflow cancelled', 0) end
  if #reads == 0 then return {} end
  return coroutine.yield({ reads = reads })
end

-- GitHub and Git share cancellation, scheduling and worktree ownership.
function M.system(root, argv, opts)
  local task = assert(M.running(), 'Workflow must run inside async.run')
  if leaving or task.cancelled then error('Workflow cancelled', 0) end
  return coroutine.yield({ argv = argv,
    opts = vim.tbl_extend('force', { cwd = root, text = true, timeout = 120000 }, opts or {}) })
end

function M.git(root, args, opts)
  local argv = { 'git', '--no-optional-locks', '-c', 'core.quotePath=false' }
  vim.list_extend(argv, args)
  local result = M.system(root, argv, vim.tbl_extend('force', { text = false }, opts or {}))
  if result.code ~= 0 then
    local err = vim.trim(result.stderr or result.stdout or '')
    return nil, err ~= '' and err or ('Git failed (exit ' .. result.code .. ')')
  end
  return result.stdout or '', nil, result
end

function M.run(root, fn, callback, opts)
  opts = opts or {}
  if leaving then return nil, 'Neovim is exiting' end
  if opts.mutation and owners[root] then return nil, 'A Git history operation is already running' end
  local task = { root = root, mutation = opts.mutation }
  local co = coroutine.create(fn)
  tasks[co] = task
  if task.mutation then owners[root] = task end
  local function finish(ok, ...)
    if task.completed then return end
    task.completed = true
    tasks[co] = nil
    if owners[root] == task then owners[root] = nil end
    if not leaving and not task.cancelled and callback then callback(ok, ...) end
  end
  local function step(...)
    if task.completed then return end
    if leaving or task.cancelled then finish(false, 'Git workflow cancelled'); return end
    local function pack(...) return { n = select('#', ...), ... } end
    local values = pack(coroutine.resume(co, ...))
    if not values[1] then finish(false, values[2]); return end
    if coroutine.status(co) == 'dead' then finish(true, unpack(values, 2, values.n)); return end
    local request = values[2]
    if request.reads then
      local results, remaining, launching = {}, #request.reads, true
      task.children = {}
      for i, read in ipairs(request.reads) do
        local function settled(ok, value)
          results[i] = { ok = ok, value = value }
          remaining = remaining - 1
          if remaining == 0 and not launching then
            task.children = nil
            step(results)
          end
        end
        local child, err = M.run(root, read, settled)
        if not child then settled(false, err) end
        if child and not child.completed then task.children[#task.children + 1] = child end
      end
      launching = false
      if remaining == 0 then task.children = nil; step(results) end
      return
    end
    local ok, job = pcall(vim.system, request.argv, request.opts, function(result)
      vim.schedule(function() task.job = nil; step(result) end)
    end)
    if not ok then step({ code = 1, stderr = tostring(job) }); return end
    task.job = job
  end
  function task.cancel()
    if task.completed then return end
    -- Mutations finish their transaction even after their view closes.
    if task.mutation then return end
    task.cancelled = true
    if task.job then pcall(task.job.kill, task.job, 15) end
    for _, child in ipairs(task.children or {}) do child.cancel() end
    finish(false, 'Git workflow cancelled')
  end
  step()
  return task
end

vim.api.nvim_create_autocmd('VimLeavePre', {
  group = vim.api.nvim_create_augroup('GitAsyncWorkflows', { clear = true }),
  callback = function()
    leaving = true
    for _, task in pairs(tasks) do
      if task.job then pcall(task.job.kill, task.job, 15) end
    end
    tasks, owners = {}, {}
  end,
})
return M
