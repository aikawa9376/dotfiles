-- Real Git target identities and mocked GH reads: reuse, races and API bounds.
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local related = require('git.features.github_related')
local function wait(fn, label) assert(vim.wait(5000, fn, 5), label) end
local function count(command, subcommand)
  local n = 0
  for _, call in ipairs(f.calls) do
    if call.argv[2] == command and (not subcommand or call.argv[3] == subcommand) then n = n + 1 end
  end
  return n
end
local function request(opts)
  local result = {}
  result.handle = related.request(vim.tbl_extend('force', { root = f.root }, opts), function(ok, value)
    result.done, result.ok, result.value = true, ok, value
  end)
  return result
end
local function finish(result)
  wait(function() return result.done end, 'Related PR result did not arrive')
  return result
end
f.api_response = function(path)
  if path:find('/commits/', 1, true) then return { data = { f.pr } } end
end
-- Short and full IDs share one request, with independent mutable results.
local a, b = request({ commit = f.base:sub(1, 9) }), request({ commit = f.base })
assert(finish(a).ok and finish(b).ok)
assert(count('api') == 1 and count('repo') == 1, 'Concurrent equivalent targets duplicated remote reads')
a.value.items[1].title = 'changed by caller'
assert(b.value.items[1].title == f.pr.title, 'Subscribers shared a mutable PR table')
local before = #f.calls
assert(finish(request({ commit = f.base })).value.items[1].title == f.pr.title)
assert(#f.calls == before, 'Warm lookup made a remote request')
assert(finish(request({ commit = f.head })).ok)
assert(count('api') == 2 and count('repo') == 1, 'New commits did not reuse repository discovery')
before = count('api')
assert(finish(request({ commit = f.base, host = 'ghe.example.test', repo = 'org/repo' })).ok)
assert(count('api') == before, 'Explicit and discovered contexts duplicated the same repository/commit')
assert(finish(request({ commit = f.base, host = 'another.example.test', repo = 'org/repo' })).ok)
assert(count('api') == before + 1, 'Another GitHub host reused the former host result')
local other_root = vim.fn.tempname()
f.git({ 'clone', '-q', f.root, other_root })
before = count('api')
assert(finish(request({ root = other_root, commit = f.base })).ok)
assert(count('api') == before + 1, 'Another worktree reused a root-owned result')
vim.fn.delete(other_root, 'rf')
-- Actual branch switches and remote changes participate in local identity.
local branch = finish(request({})); assert(branch.ok)
before = count('pr', 'list')
finish(request({ branch = 'topic', branch_kind = 'local_' }))
assert(count('pr', 'list') == before, 'Current-file and local-branch targets did not share results')
f.git({ 'checkout', '-q', 'main' })
assert(finish(request({})).ok and count('pr', 'list') == before + 1, 'Branch change reused another branch')
f.git({ 'remote', 'set-url', 'origin', 'git@ghe.example.test:fork/repo.git' })
before = #f.calls
assert(finish(request({ commit = f.base })).ok and #f.calls > before, 'Remote change reused the old cache')
-- Empty results and errors have bounded lifetimes without minute-long sleeps.
local real_now, clock = vim.uv.now, vim.uv.now()
vim.uv.now = function() return clock end
related.invalidate(f.root)
f.api_response = function() return { data = {} } end
a = finish(request({ commit = f.base })); assert(a.ok and #a.value.items == 0)
before = #f.calls
finish(request({ commit = f.base })); assert(#f.calls == before, 'Empty results were not cached')
clock = clock + 300001
finish(request({ commit = f.base })); assert(#f.calls > before, 'Expired PR/repository results were reused')
related.invalidate(f.root)
f.api_response = function() return { code = 1, stderr = 'offline', data = {} } end
a = finish(request({ commit = f.base })); assert(not a.ok and a.value:find('offline', 1, true))
before = #f.calls
finish(request({ commit = f.base })); assert(#f.calls == before, 'Errors were retried immediately')
clock = clock + 10001
f.api_response = function() return { data = { f.pr } } end
assert(finish(request({ commit = f.base })).ok and #f.calls > before, 'Short-lived failure prevented recovery')
vim.uv.now = real_now
-- Explicit invalidation on GitHub mutation clears results for this root.
before = #f.calls
require('git.features.github').changed({ root = f.root })
finish(request({ commit = f.base })); assert(#f.calls > before, 'GitHubChanged retained stale PR information')
-- Hold branch reads to measure sharing, detach, queueing and late completion.
related.invalidate(f.root)
local transport, held, active, peak = vim.system, {}, 0, 0
vim.system = function(argv, opts, callback)
  if argv[1] ~= 'gh' or argv[2] ~= 'pr' or argv[3] ~= 'list' then return transport(argv, opts, callback) end
  local head
  for i, value in ipairs(argv) do if value == '--head' then head = argv[i + 1] end end
  active = active + 1; peak = math.max(peak, active)
  local job = { head = head }
  function job.reply(number)
    active = active - 1
    local pr = vim.deepcopy(f.pr); pr.number, pr.url = number or 7, f.pr.url:gsub('/7$', '/' .. (number or 7))
    callback({ code = 0, stdout = vim.json.encode({ pr }), stderr = '' })
  end
  held[#held + 1] = job
  return { kill = function() job.killed = true end }
end
a, b = request({ branch = 'shared' }), request({ branch = 'shared' })
wait(function() return #held == 1 end, 'Shared branch read')
a.handle.cancel(); held[1].reply()
assert(finish(b).ok and not a.done and not held[1].killed, 'Detaching one view cancelled another subscriber')
a = request({ branch = 'background' })
wait(function() return #held == 2 end, 'Background read')
a.handle.cancel(); held[2].reply(); vim.wait(30, function() return false end, 5)
assert(finish(request({ branch = 'background' })).ok and #held == 2, 'Detached read did not warm the shared cache')
-- Invalidated in-flight data must not overwrite a fresh result.
a = request({ branch = 'race' }); wait(function() return #held == 3 end, 'Old race read')
related.invalidate(f.root)
b = request({ branch = 'race' }); wait(function() return #held == 4 end, 'Fresh race read')
held[4].reply(8); finish(b); held[3].reply(9); finish(a)
assert(finish(request({ branch = 'race' })).value.items[1].number == 8, 'Late old read replaced refreshed data')
-- More than four distinct targets queue; a cancelled queued target never runs.
local pending = {}
for i = 1, 6 do pending[i] = request({ branch = 'queued-' .. i }) end
wait(function() return #held == 8 end, 'Four active reads')
local started, cancelled = {}, nil
for i = 5, 8 do started[held[i].head] = true end
for i = 1, 6 do if not started['queued-' .. i] then cancelled = i; break end end
assert(cancelled)
pending[cancelled].handle.cancel()
held[5].reply()
wait(function() return #held == 9 end, 'Queued read did not start')
assert(held[9].head ~= 'queued-' .. cancelled)
for i = 6, 9 do held[i].reply() end
for i, result in ipairs(pending) do if i ~= cancelled then finish(result) end end
assert(peak <= 4 and not pending[cancelled].done, 'Remote concurrency or queued cancellation failed')
vim.system = transport
-- Completed cache storage is bounded even across many visited targets.
local cache, reads, completions = require('git.features.github_related_cache'), 0, 0
local function load() reads = reads + 1; return {} end
local function done() completions = completions + 1 end
for i = 1, 260 do cache.get(f.root, 'capacity-' .. i, load, done) end
wait(function() return completions == 260 end, 'Capacity fixture did not settle')
cache.get(f.root, 'capacity-1', load, done)
wait(function() return completions == 261 end, 'Evicted cache entry did not finish')
assert(reads == 261, 'Old completed entries were retained without a bound')
f.cleanup()
print('PASS: canonical shared PR reads, context identity, TTL/error/empty caches, invalidation, cancellation and concurrency')
