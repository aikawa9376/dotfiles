-- Synthetic large-history persistence; never reads or writes user thread data.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
vim.opt.rtp:prepend(root)
local output = assert(vim.env.LAZYAGENT_BENCH_OUT, "set LAZYAGENT_BENCH_OUT")
local count = tonumber(vim.env.LAZYAGENT_BENCH_THREADS) or 223
local bytes = tonumber(vim.env.LAZYAGENT_BENCH_RECORD_BYTES) or 96000
local directory = vim.fn.tempname() .. "-thread-store-bench"
vim.fn.mkdir(directory, "p")
local manifest = { schema_version = 1, updated_at = "2026-01-01T00:00:00Z", threads = {} }
for i = 1, count do
  manifest.threads[i] = {
    thread_id = string.format("123e4567-e89b-42d3-a456-%012x", i),
    provider_id = "fixture", status = "closed", cwd = directory,
    metadata = { padding = tostring(i) .. string.rep("x", bytes) },
  }
end
local path = directory .. "/manifest.json"
vim.fn.writefile({ vim.json.encode(manifest) }, path)
manifest = nil
local store = require("lazyagent.acp.thread_store").new({ dir = directory })
local samples = {}
local function measure(phase, callback)
  collectgarbage("collect")
  local started = vim.uv.hrtime()
  callback()
  local sample = {
    phase = phase, ms = (vim.uv.hrtime() - started) / 1e6,
    lua_kib_after = collectgarbage("count"), rss_after = vim.uv.resident_set_memory(),
  }
  collectgarbage("collect")
  sample.lua_kib_after_gc = collectgarbage("count")
  samples[#samples + 1] = sample
end
local thread_id
measure("cold-read", function()
  local loaded = assert(store:_read())
  thread_id = loaded.threads[1].thread_id
end)
for i = 1, 10 do
  measure("view-state-save", function()
    assert(store:update(thread_id, { view_state = { follow_output = false, view = { lnum = i } } }))
  end)
end
assert(#store:list({ include_archived = true }) == count)
assert(store:get(thread_id).view_state.view.lnum == 10)
vim.fn.writefile({ vim.json.encode({ threads = count, record_bytes = bytes, samples = samples }) }, output)
vim.fn.delete(directory, "rf")
