local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function plugin_root()
  local source = debug.getinfo(1, "S").source:gsub("^@", "")
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

function M.run()
  local root = plugin_root()
  local cache_dir = vim.fn.tempname() .. "-backend-thread"
  local state = require("lazyagent.logic.state")
  local previous_opts = state.opts
  state.opts = vim.tbl_deep_extend("force", vim.deepcopy(previous_opts or {}), {
    cache = { dir = cache_dir },
  })

  local killed = false
  local view = {
    create_pane = function(_, done)
      done("thread-test-pane", {})
    end,
    pane_exists = function()
      return not killed
    end,
    kill_pane = function()
      killed = true
      return true
    end,
    debug_snapshot = function()
      return { active_timer_count = 0 }
    end,
  }
  local backend = require("lazyagent.acp.backend").new(view)
  local pane_id
  backend.split(nil, 10, false, {
    on_split = function(created)
      pane_id = created
    end,
    acp = {
      agent_name = "ThreadFixture",
      command = {
        vim.v.progpath,
        "--headless",
        "--clean",
        "-u",
        "NONE",
        "-l",
        root .. "/tests/acp/fake_agent.lua",
      },
      cwd = root,
      root_dir = root,
      additional_directories = { root .. "/tests" },
    },
  })

  assert_equal(pane_id, "thread-test-pane", "backend pane")
  assert(vim.wait(5000, function()
    local snapshot = backend.get_runtime_snapshot(pane_id)
    return snapshot and snapshot.acp_ready == true
  end, 10), "backend thread should become ready")

  local runtime = backend.get_runtime_snapshot(pane_id)
  assert(runtime.acp_thread_id ~= nil, "runtime thread identity")
  assert_equal(runtime.acp_provider_id, "ThreadFixture", "runtime provider identity")
  assert_equal(runtime.acp_thread_store_error, nil, "runtime thread persistence")

  local store = require("lazyagent.acp.thread_store").new({ dir = cache_dir .. "/acp/threads" })
  local persisted = assert(store:get(runtime.acp_thread_id))
  assert_equal(persisted.status, "active", "active persisted thread")
  assert_equal(persisted.native_session_id, runtime.acp_session_id, "native session persistence")
  assert(persisted.process_id ~= nil, "process identity persistence")
  assert_equal(persisted.transcript_path, runtime.acp_transcript_path, "transcript persistence")

  backend.kill_pane(pane_id)
  local closed = assert(store:get(runtime.acp_thread_id))
  assert_equal(closed.status, "closed", "closed persisted thread")
  assert_equal(closed.process_id, nil, "closed process detachment")
  assert_equal(backend.get_debug_snapshot().session_count, 0, "closed backend ownership")

  state.opts = previous_opts
  vim.fn.delete(cache_dir, "rf")
end

return M
