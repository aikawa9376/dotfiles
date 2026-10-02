-- Real backend, real transcript buffers, deterministic local ACP child only.
local source = debug.getinfo(1, 'S').source:gsub('^@', '')
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
vim.opt.rtp:prepend(root)
package.path = root .. '/?.lua;' .. root .. '/?/init.lua;' .. package.path
local output = assert(vim.env.LAZYAGENT_BENCH_OUT, 'set LAZYAGENT_BENCH_OUT')
local loops = math.max(1, tonumber(vim.env.LAZYAGENT_BENCH_LIFECYCLE_LOOPS) or 20)
local temporary = vim.fn.tempname() .. '-lifecycle-bench'
local workspace = temporary .. '/workspace'
vim.fn.mkdir(workspace, 'p')
local state = require('lazyagent.logic.state')
state.opts = {
  cache = { dir = temporary .. '/cache' },
  acp = { auto_permission = 'allow_once', footer_animation = false, permissions = { dir = temporary .. '/permissions' } },
}
local view = require('lazyagent.acp.view_buffer')
local backend = require('lazyagent.acp.backend').new(view)
local resources = require('tests.bench.resources')
local source_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(source_buf, workspace .. '/source.lua')
local source_win = vim.api.nvim_get_current_win()
local fake = { vim.v.progpath, '--headless', '--clean', '-u', 'NONE', '-l', root .. '/tests/acp/fake_agent.lua' }
local report = { loops = loops, samples = {} }
local Client = require('lazyagent.acp.client')
local new_client = Client.new
local weak_clients = setmetatable({}, { __mode = 'k' })
Client.new = function(...)
  local client = new_client(...)
  weak_clients[client] = true
  return client
end

local function sample(phase)
  -- -l/vim.wait never enters the editor's ordinary input loop. Flush the
  -- one-shot matchparen SafeState callbacks as an idle interactive editor does.
  vim.api.nvim_exec_autocmds('SafeState', {})
  collectgarbage('collect')
  -- Finalized luv userdata can release Lua callbacks during the first GC;
  -- a second pass collects the objects those callbacks owned.
  collectgarbage('collect')
  local snapshot = resources.capture()
  local owned = backend.get_debug_snapshot()
  snapshot.phase = phase
  snapshot.sessions = owned.session_count
  snapshot.children = owned.child_process_count
  snapshot.callbacks = owned.callback_count
  snapshot.owner_count = #owned.owners
  snapshot.view = view.debug_snapshot()
  snapshot.ui = require('lazyagent.acp.ui_queue').snapshot()
  snapshot.retained_clients = vim.tbl_count(weak_clients)
  report.samples[#report.samples + 1] = snapshot
  return snapshot
end

local function open(thread_id, index)
  local pane
  local forced_load = thread_id and index % 2 == 0
  backend.split(nil, 8, false, {
    on_split = function(id) pane = id end,
    acp = {
      agent_name = 'LifecycleFixture', thread_id = thread_id, command = fake,
      cwd = workspace, root_dir = workspace, additional_directories = { root .. '/tests' },
      agent_cfg = { yolo = true }, release_buffer_on_hide = true, footer_animation = false,
      transcript_max_lines = 12000, source_winid = source_win, source_bufnr = source_buf,
      env = vim.tbl_extend('force', { LAZYAGENT_FAKE_SIMPLE_PROMPT = '1' }, forced_load
        and { LAZYAGENT_FAKE_DISABLE_RESUME = '1', LAZYAGENT_FAKE_REPLAY_ON_LOAD = '1' } or {}),
    },
  })
  assert(vim.wait(5000, function()
    local runtime = pane and backend.get_runtime_snapshot(pane)
    return runtime and runtime.acp_ready == true
  end, 5), 'fake backend became ready')
  return pane
end

local function close(pane)
  backend.kill_pane(pane)
  assert(vim.wait(3000, function()
    local owned = backend.get_debug_snapshot()
    return owned.session_count == 0 and #owned.owners == 0
  end, 5), 'backend released all owned resources')
  -- Let the bounded session-close fallback and queued callbacks expire too.
  vim.wait(1100, function() return false end, 10)
  backend.cleanup_if_idle()
  local snapshot = sample('closed')
  assert(snapshot.processes == 0 and snapshot.callbacks == 0 and snapshot.owner_count == 0)
  assert(snapshot.view.buffer_count == 0 and snapshot.view.layout_count == 0 and snapshot.view.config_count == 0)
  assert(snapshot.ui.active == nil and #snapshot.ui.pending == 0)
  if snapshot.retained_clients > 0 then
    report.retained = {}
    for client in pairs(weak_clients) do
      report.retained[#report.retained + 1] = client:debug_snapshot()
    end
    vim.fn.writefile({ vim.json.encode(report) }, output)
  end
  assert(snapshot.retained_clients == 0, 'closed ACP clients retained Lua references')
end

local function same_resources(before, after)
  for _, kind in ipairs({ 'buffers', 'loaded_buffers', 'autocmds', 'processes', 'timers', 'watchers', 'terminals' }) do
    assert(after[kind] == before[kind], kind .. ' grew over lifecycle cycles')
  end
end

-- Prime one-time module/autocmd allocations before measuring repeated cycles.
close(open(nil, 1))
report.baseline = sample('warm-baseline')
for index = 1, loops do
  close(open(nil, index))
  assert(#backend.list_threads({ include_archived = true }) == 0, 'promptless close retained a thread')
end
report.empty_final = sample('empty-final')
same_resources(report.baseline, report.empty_final)
local thread_id
for index = 1, loops do
  local pane = open(thread_id, index)
  local runtime = backend.get_runtime_snapshot(pane)
  thread_id = runtime.acp_thread_id
  assert(backend.paste_and_submit(pane, 'fixture prompt ' .. index))
  assert(vim.wait(5000, function() return not backend.is_busy(pane) end, 5), 'fake prompt completed')
  sample('prompt-complete')
  backend.break_pane(pane)
  assert(view.debug_snapshot().buffer_count == 0, 'explicit hide retained the transcript')
  for _ = 1, 3 do
    local joined
    backend.join_pane(pane, 8, false, function(ok) joined = ok end)
    assert(vim.wait(1000, function() return joined ~= nil end, 5) and joined)
    local debug = view.debug_snapshot().panes[pane]
    assert(debug)
    vim.api.nvim_win_close(vim.fn.bufwinid(debug.bufnr), true)
    assert(vim.wait(200, function() return view.debug_snapshot().buffer_count == 0 end, 5))
  end
  close(pane)
  assert(#backend.list_threads({ include_archived = true }) == 1, 'reopen duplicated history')
  if index == 1 then report.prompt_baseline = sample('prompt-baseline') end
end
report.final = sample('final')
vim.fn.writefile({ vim.json.encode(report) }, output)
same_resources(report.prompt_baseline, report.final)
Client.new = new_client
vim.fn.delete(temporary, 'rf')
print('PASS lifecycle: ' .. loops .. ' empty closes, ' .. loops .. ' prompt/resume/load closes, ' .. (loops * 3) .. ' native hides')
