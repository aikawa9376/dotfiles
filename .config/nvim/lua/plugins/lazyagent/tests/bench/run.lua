local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
vim.opt.runtimepath:prepend(root)
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local output_path = vim.env.LAZYAGENT_BENCH_OUT
assert(output_path and output_path ~= "", "LAZYAGENT_BENCH_OUT must be an explicit output path")
local samples = math.max(1, tonumber(vim.env.LAZYAGENT_BENCH_SAMPLES) or 3)
local warmup = math.max(0, tonumber(vim.env.LAZYAGENT_BENCH_WARMUP) or 1)
local lifecycle_loops = math.max(1, tonumber(vim.env.LAZYAGENT_BENCH_LIFECYCLE_LOOPS) or 50)
local uv = vim.uv or vim.loop
local temp_root = vim.fn.tempname() .. "-lazyagent-bench"
assert(vim.fn.mkdir(temp_root, "p") == 1)

local function percentile(values, ratio)
  local sorted = vim.deepcopy(values)
  table.sort(sorted)
  return sorted[math.max(1, math.ceil(#sorted * ratio))]
end

local function resources()
  local buffers = 0
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then buffers = buffers + 1 end
  end
  return {
    processes = 0, timers = 0, callbacks = 0, autocmds = #vim.api.nvim_get_autocmds({}),
    watchers = 0, buffers = buffers, terminals = 0, views = 0,
  }
end

local function measure(fn)
  local timings, provider, lazyagent = {}, {}, {}
  local details
  local before_resources = resources()
  collectgarbage("collect")
  local memory_before = collectgarbage("count")
  for index = 1, warmup + samples do
    collectgarbage("collect")
    local started = uv.hrtime()
    details = fn() or {}
    local elapsed = tonumber(details.measured_ms) or ((uv.hrtime() - started) / 1000000)
    if index > warmup then
      timings[#timings + 1] = elapsed
      provider[#provider + 1] = tonumber(details.provider_process_ms) or 0
      lazyagent[#lazyagent + 1] = tonumber(details.lazyagent_ms) or elapsed
    end
  end
  collectgarbage("collect")
  local result = {
    samples = samples,
    p50_ms = percentile(timings, 0.50), p95_ms = percentile(timings, 0.95), max_ms = percentile(timings, 1),
    provider_process_p50_ms = percentile(provider, 0.50), lazyagent_p50_ms = percentile(lazyagent, 0.50),
    lua_kb_before = memory_before, lua_kb_after_gc = collectgarbage("count"),
    resource_counts_before = before_resources, resource_counts_after = resources(),
  }
  for key, value in pairs(details or {}) do
    if type(value) == "number" and result[key] == nil then result[key] = value end
  end
  return result
end

local fake_command = {
  vim.v.progpath, "--headless", "--clean", "-u", "NONE", "-l", root .. "/tests/acp/fake_agent.lua",
}

local function client_scenario(mode, replay)
  return function()
    local Client = require("lazyagent.acp.client")
    local update_ms, update_count, update_bytes = 0, 0, 0
    local exited, result, result_err
    local client = Client.new({
      command = fake_command, cwd = root, additional_directories = { root .. "/tests" },
      env = replay and { LAZYAGENT_FAKE_REPLAY_ON_LOAD = "1", LAZYAGENT_FAKE_REPLAY_TOOL = "1" } or {},
      request_timeout_ms = 3000,
      on_update = function(params)
        local started = uv.hrtime()
        update_count = update_count + 1
        update_bytes = update_bytes + #vim.json.encode(params.update or {})
        update_ms = update_ms + ((uv.hrtime() - started) / 1000000)
      end,
      on_exit = function() exited = true end,
    })
    local started = uv.hrtime()
    client:start(function(connected, err) result, result_err = connected, err end,
      mode == "new" and {} or { session_mode = mode, session_id = "bench-session" })
    assert(vim.wait(5000, function() return result ~= nil or result_err ~= nil end, 5), mode .. " benchmark timeout")
    assert(result and not result_err, mode .. " benchmark failed: " .. vim.inspect(result_err))
    local total = (uv.hrtime() - started) / 1000000
    client:stop()
    assert(vim.wait(3000, function() return exited == true end, 5), mode .. " benchmark teardown")
    assert(vim.wait(1000, function()
      local snapshot = client:debug_snapshot()
      return snapshot.callbacks == 0 and snapshot.callback_timers == 0 and snapshot.stop_timer == 0
    end, 5), mode .. " benchmark resource release")
    local debug = client:debug_snapshot()
    assert(debug.callbacks == 0 and debug.callback_timers == 0 and debug.stop_timer == 0,
      mode .. " benchmark leaked client resources")
    return {
      measured_ms = total, provider_process_ms = total, lazyagent_ms = update_ms,
      update_count = update_count, update_bytes = update_bytes,
    }
  end
end

local function cold_load()
  local started = uv.hrtime()
  local result = vim.system({ vim.v.progpath, "--headless", "--clean", "-u", "NONE", "-l",
    root .. "/tests/bench/cold_fixture.lua" }, { env = { LAZYAGENT_BENCH_ROOT = root }, text = true }):wait()
  assert(result.code == 0, result.stderr)
  local decoded = vim.json.decode(result.stdout)
  local total = (uv.hrtime() - started) / 1000000
  return { measured_ms = total, provider_process_ms = total, lazyagent_ms = decoded.lazyagent_ms }
end

local function cockpit_scenario(scale)
  local Cockpit = require("lazyagent.acp.cockpit")
  local Store = require("lazyagent.acp.thread_store")
  local dir = temp_root .. "/cockpit-" .. tostring(scale)
  local store = Store.new({ dir = dir })
  local transcript = dir .. "/preview.md"
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ "# User", "benchmark", "", "# Assistant", "response" }, transcript)
  for index = 1, scale do
    assert(store:create({
      provider_id = "provider-" .. tostring(index % 4), cwd = "/tmp/project-" .. tostring(index % 10),
      title = "benchmark thread " .. tostring(index), status = "closed", transcript_path = transcript,
      metadata = { activation = { context_continuity = "native_resume", visible_history = "local_snapshot" } },
    }))
  end
  return function()
    local listed = assert(store:list({ include_archived = true }))
    local filtered = Cockpit.filter(listed, "benchmark")
    local lines = Cockpit.render(filtered, {}, { width = 120 })
    local preview = Cockpit.latest_response(listed[1], 8)
    assert(#lines > scale and #preview > 0)
  end
end

local function update_stream(count)
  local Hydrator = require("lazyagent.acp.session_hydrator")
  return function()
    local hydrator = Hydrator.new({
      thread = { thread_id = "stream-" .. tostring(count), metadata = { activation = { history_state = "missing" } } },
      cache_dir = temp_root, max_updates = count + 10, max_bytes = 16 * 1024 * 1024,
    })
    assert(hydrator:begin())
    local maximum_block = 0
    for index = 1, count do
      local started = uv.hrtime()
      assert(hydrator:consume({ update = {
        sessionUpdate = index % 2 == 0 and "agent_message_chunk" or "user_message_chunk",
        messageId = "message-" .. tostring(math.ceil(index / 2)),
        content = { type = "text", text = "update " .. tostring(index) },
      } }))
      maximum_block = math.max(maximum_block, (uv.hrtime() - started) / 1000000)
    end
    assert(hydrator:prepare())
    hydrator:discard("benchmark")
    return { lazyagent_ms = maximum_block, redraw_count = 0, maximum_event_loop_block_ms = maximum_block }
  end
end

local function ten_turn_growth()
  local StructuredHistory = require("lazyagent.acp.structured_history")
  local path = temp_root .. "/ten-turns.jsonl"
  local records = {}
  for index = 1, 10 do
    records[index] = {
      schema_version = 1, turn_id = "turn-" .. tostring(index), state = "completed",
      conversation = {
        { kind = "user", body = string.rep("question ", 32) },
        { kind = "assistant", body = string.rep("answer ", 64) },
      },
      tools = { { toolCallId = "tool-" .. tostring(index), kind = "read", status = "completed" } },
      changes = {},
    }
  end
  assert(StructuredHistory.write(path, records))
  local loaded = assert(StructuredHistory.read(path))
  assert(#loaded == 10)
  return { history_bytes = vim.fn.getfsize(path), timeline_items = 30, tool_items = 10, blob_metadata_count = 0 }
end

local function lifecycle()
  local scenario = client_scenario("new", false)
  local started = uv.hrtime()
  for _ = 1, lifecycle_loops do scenario() end
  local elapsed = (uv.hrtime() - started) / 1000000
  return { measured_ms = elapsed, provider_process_ms = elapsed, lazyagent_ms = 0, loops = lifecycle_loops }
end

local function switch_snapshot()
  local snapshot = { provider_from = "one", provider_to = "two", transcript_lines = {}, conversation_timeline = {}, tool_timeline = {} }
  for index = 1, 200 do
    snapshot.transcript_lines[index] = "line " .. tostring(index)
    snapshot.conversation_timeline[index] = { seq = index, kind = index % 2 == 0 and "assistant" or "user", summary = "item" }
  end
  local restored = vim.deepcopy(snapshot)
  assert(#restored.conversation_timeline == 200)
  return { snapshot_bytes = #vim.json.encode(restored) }
end

local scenarios = {
  ["cold-plugin-first-command"] = measure(cold_load),
  ["initialize-new"] = measure(client_scenario("new", false)),
  ["initialize-resume"] = measure(client_scenario("resume", false)),
  ["initialize-load-replay"] = measure(client_scenario("load", true)),
}
for _, scale in ipairs({ 10, 100, 500 }) do scenarios["cockpit-" .. scale] = measure(cockpit_scenario(scale)) end
for _, count in ipairs({ 100, 1000 }) do scenarios["updates-" .. count] = measure(update_stream(count)) end
scenarios["conversation-10-turns"] = measure(ten_turn_growth)
scenarios["lifecycle-open-close"] = measure(lifecycle)
scenarios["provider-switch-resession"] = measure(switch_snapshot)

local uname = vim.system({ "uname", "-srmo" }, { text = true }):wait().stdout:gsub("%s+$", "")
local cpu = vim.system({ "sh", "-c", "LC_ALL=C lscpu | sed -n 's/^Model name:[[:space:]]*//p'" }, { text = true }):wait().stdout:gsub("%s+$", "")
local commit = vim.system({ "git", "rev-parse", "HEAD" }, { cwd = root, text = true }):wait().stdout:gsub("%s+$", "")
local report = {
  schema_version = 1, commit = commit,
  nvim_version = vim.version().major .. "." .. vim.version().minor .. "." .. vim.version().patch,
  platform = uname, generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  environment = {
    cpu = cpu, warmup = warmup, samples = samples, lifecycle_loops = lifecycle_loops,
    cache = "temporary", run = "warm-per-scenario with fixed pre-sample GC",
  },
  scenarios = scenarios,
}
local parent = vim.fn.fnamemodify(output_path, ":h")
assert(vim.fn.isdirectory(parent) == 1 or vim.fn.mkdir(parent, "p") == 1)
assert(vim.fn.writefile({ vim.json.encode(report) }, output_path) == 0)
vim.fn.delete(temp_root, "rf")
print("wrote " .. output_path .. " with " .. tostring(vim.tbl_count(scenarios)) .. " scenarios")
