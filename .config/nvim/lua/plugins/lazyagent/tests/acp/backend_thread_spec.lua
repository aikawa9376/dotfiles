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
  local fake_command = {
    vim.v.progpath,
    "--headless",
    "--clean",
    "-u",
    "NONE",
    "-l",
    root .. "/tests/acp/fake_agent.lua",
  }
  local cache_dir = vim.fn.tempname() .. "-backend-thread"
  local state = require("lazyagent.logic.state")
  local previous_opts = state.opts
  state.opts = vim.tbl_deep_extend("force", vim.deepcopy(previous_opts or {}), {
    cache = { dir = cache_dir },
    acp = { auto_permission = "allow_once" },
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
      command = fake_command,
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

  pane_id = nil
  backend.split(nil, 10, false, {
    on_split = function(created)
      pane_id = created
    end,
    acp = {
      agent_name = "ThreadFixture",
      thread_id = runtime.acp_thread_id,
      command = fake_command,
      cwd = root,
      root_dir = root,
      additional_directories = { root .. "/tests" },
    },
  })
  assert_equal(pane_id, "thread-test-pane", "reopened backend pane")
  assert(vim.wait(5000, function()
    local snapshot = backend.get_runtime_snapshot(pane_id)
    return snapshot and snapshot.acp_ready == true
  end, 10), "reopened backend thread should become ready")

  local reopened_runtime = backend.get_runtime_snapshot(pane_id)
  assert_equal(reopened_runtime.acp_thread_id, runtime.acp_thread_id, "reopened thread identity")
  assert_equal(reopened_runtime.acp_transcript_path, runtime.acp_transcript_path, "reopened transcript identity")
  assert_equal(reopened_runtime.acp_resume_strategy, "native_resume", "native resume strategy")
  assert_equal(reopened_runtime.acp_has_pending_carryover, false, "native resume carryover")
  assert_equal(#assert(backend.list_threads({ include_archived = true })), 1, "reopen should not duplicate thread")
  assert_equal(assert(backend.get_thread(runtime.acp_thread_id)).status, "active", "reopened persisted status")
  backend.kill_pane(pane_id)

  assert(backend.update_thread(runtime.acp_thread_id, {
    draft = "saved thread draft",
    unread = true,
    config = {
      {
        id = "fast",
        name = "Fast",
        type = "boolean",
        currentValue = false,
      },
    },
  }))

  pane_id = nil
  backend.split(nil, 10, false, {
    on_split = function(created)
      pane_id = created
    end,
    acp = {
      agent_name = "ThreadFixture",
      thread_id = runtime.acp_thread_id,
      command = fake_command,
      env = {
        LAZYAGENT_FAKE_DISABLE_RESUME = "1",
        LAZYAGENT_FAKE_DISABLE_LOAD = "1",
      },
      cwd = root,
      root_dir = root,
      additional_directories = { root .. "/tests" },
    },
  })
  assert(vim.wait(5000, function()
    local snapshot = backend.get_runtime_snapshot(pane_id)
    return snapshot and snapshot.acp_ready == true
  end, 10), "local carryover thread should become ready")
  local fallback_runtime = backend.get_runtime_snapshot(pane_id)
  assert_equal(fallback_runtime.acp_resume_strategy, "local_carryover", "local carryover strategy")
  assert_equal(fallback_runtime.acp_has_pending_carryover, true, "local carryover prompt context")
  assert_equal(fallback_runtime.acp_thread_draft, "saved thread draft", "restored thread draft")
  assert_equal(fallback_runtime.acp_thread_unread, true, "restored unread state")
  assert(vim.wait(2000, function()
    local snapshot = backend.get_runtime_snapshot(pane_id)
    return snapshot
      and snapshot.acp_config_options[1]
      and snapshot.acp_config_options[1].currentValue == false
  end, 10), "saved config should be restored")

  assert(backend.mark_thread_read(runtime.acp_thread_id))
  assert_equal(backend.get_runtime_snapshot(pane_id).acp_thread_unread, false, "thread read state")
  assert(backend.set_thread_draft(runtime.acp_thread_id, "updated draft"))
  assert_equal(backend.get_runtime_snapshot(pane_id).acp_thread_draft, "updated draft", "thread draft update")

  local previous_open_agent = state.open_agent
  state.open_agent = nil
  backend.paste_and_submit(pane_id, "exercise unread state")
  assert(vim.wait(5000, function()
    local snapshot = backend.get_runtime_snapshot(pane_id)
    return snapshot and snapshot.acp_thread_unread == true
  end, 10), "background assistant output should mark thread unread")
  state.open_agent = previous_open_agent
  local fallback_thread = assert(backend.get_thread(runtime.acp_thread_id))
  assert_equal(fallback_thread.metadata.resume_strategy, "local_carryover", "persisted resume strategy")
  assert(
    backend.capture_pane_sync(pane_id):find("Continuation: local transcript carryover", 1, true),
    "local carryover should be visible in transcript"
  )
  backend.kill_pane(pane_id)

  state.opts = previous_opts
  vim.fn.delete(cache_dir, "rf")
end

return M
