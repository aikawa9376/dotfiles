-- Coroutine Git workflows: one asynchronous subprocess at a time, no UI wait.
local M = {}
local tasks, owners = {}, {}
local leaving = false

function M.running()
  return tasks[coroutine.running()]
end

function M.busy(root) return owners[root] ~= nil end

function M.git(root, args, opts)
  local task = assert(M.running(), 'Git workflow must run inside async.run')
  if leaving or task.cancelled then error('Git workflow cancelled', 0) end
  local argv = { 'git', '--no-optional-locks', '-c', 'core.quotePath=false' }
  vim.list_extend(argv, args)
  local result = coroutine.yield({ argv = argv,
    opts = vim.tbl_extend('force', { cwd = root, text = false, timeout = 120000 }, opts or {}) })
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
    if leaving or task.cancelled then finish(false, 'Git workflow cancelled'); return end
    local function pack(...) return { n = select('#', ...), ... } end
    local values = pack(coroutine.resume(co, ...))
    if not values[1] then finish(false, values[2]); return end
    if coroutine.status(co) == 'dead' then finish(true, unpack(values, 2, values.n)); return end
    local request = values[2]
    local ok, job = pcall(vim.system, request.argv, request.opts, function(result)
      vim.schedule(function() task.job = nil; step(result) end)
    end)
    if not ok then step({ code = 1, stderr = tostring(job) }); return end
    task.job = job
  end
  function task.cancel()
    -- Mutations finish their transaction even after their view closes.
    if task.mutation then return end
    task.cancelled = true
    if task.job then pcall(task.job.kill, task.job, 15) end
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
