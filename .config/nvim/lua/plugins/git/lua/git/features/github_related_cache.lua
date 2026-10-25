-- Bounded shared reads. A view cancels its subscription, not another view's job.
local M = {}
local async = require('git.features.async')
local entries, queue, generations = {}, {}, {}
local running, serial = 0, 0
local TTL, ERROR_TTL, LIMIT, CONCURRENCY = 300000, 10000, 256, 4
local pump
local function now() return vim.uv.now() end
local function prune()
  local completed = {}
  for key, entry in pairs(entries) do
    if entry.expires then
      if entry.expires <= now() then entries[key] = nil
      else completed[#completed + 1] = entry end
    end
  end
  table.sort(completed, function(a, b) return a.used > b.used end)
  for i = LIMIT + 1, #completed do entries[completed[i].key] = nil end
end
local function deliver(waiter, entry)
  vim.schedule(function()
    if not waiter.cancelled then waiter.callback(entry.ok, vim.deepcopy(entry.value), entry.expires) end
  end)
end
pump = function()
  while running < CONCURRENCY and #queue > 0 do
    local entry = table.remove(queue, 1)
    if not entry.abandoned then
      running, entry.started = running + 1, true
      local function done(ok, value)
        entry.ok, entry.value = ok, value
        entry.expires = now() + (ok and TTL or ERROR_TTL)
        running = running - 1
        for waiter in pairs(entry.waiters) do deliver(waiter, entry) end
        entry.waiters = {}
        prune()
        pump()
      end
      local load = entry.load
      entry.load = nil
      local task, err = async.run(entry.root, load, done)
      if not task then done(false, err) end
    end
  end
end

function M.get(root, key, load, callback)
  prune()
  serial = serial + 1
  local entry = entries[key]
  if not entry then
    entry = { root = root, key = key, load = load, waiters = {} }
    entries[key], queue[#queue + 1] = entry, entry
  end
  entry.used = serial
  local waiter = { callback = callback }
  local handle = {}
  function handle.cancel()
    waiter.cancelled = true
    entry.waiters[waiter] = nil
    -- Reads already sent finish and warm the cache. Unneeded queued reads
    -- can still be discarded before they consume an API request.
    if not entry.started and not next(entry.waiters) then
      entry.abandoned = true
      if entries[key] == entry then entries[key] = nil end
      for i = #queue, 1, -1 do if queue[i] == entry then table.remove(queue, i); break end end
    end
  end
  if entry.expires then deliver(waiter, entry)
  else entry.waiters[waiter] = true; pump() end
  return handle
end

function M.generation(root) return generations[root] or 0 end
function M.invalidate(root)
  if root then generations[root] = M.generation(root) + 1 end
  for key, entry in pairs(entries) do
    if not root or entry.root == root then
      if not root then generations[entry.root] = M.generation(entry.root) + 1 end
      -- Detached in-flight entries can finish for their subscribers, but
      -- cannot overwrite a replacement or repopulate the invalidated cache.
      entries[key] = nil
    end
  end
end
return M
