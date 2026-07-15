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
  local pane_seq = 0
  local view = {
    create_pane = function(_, done)
      pane_seq = pane_seq + 1
      done("thread-test-pane-" .. tostring(pane_seq), {})
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

  assert_equal(pane_id, "thread-test-pane-1", "backend pane")
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

  local export_path = cache_dir .. "/exports/thread.md"
  assert_equal(backend.export_thread_markdown(pane_id, export_path), export_path, "thread Markdown export path")
  local exported_markdown = table.concat(vim.fn.readfile(export_path), "\n")
  assert(exported_markdown:match("# ThreadFixture"), "thread Markdown export title")
  assert(exported_markdown:match("Connecting ACP session"), "thread Markdown export content")

  assert(backend.update_thread(runtime.acp_thread_id, {
    change_journal = {
      turns = { { turn_id = runtime.acp_thread_id .. ":checkpoint", changes = {} } },
    },
  }))
  local branch = assert(backend.branch_thread_checkpoint(runtime.acp_thread_id, runtime.acp_thread_id .. ":checkpoint"))
  assert_equal(branch.metadata.client_local_branch, true, "checkpoint local branch")
  assert_equal(branch.metadata.parent_thread_id, runtime.acp_thread_id, "checkpoint branch parent")
  assert_equal(branch.native_session_id, nil, "checkpoint branch native isolation")
  assert_equal(vim.fn.filereadable(branch.transcript_path), 1, "checkpoint branch transcript copy")
  assert_equal(backend.delete_thread(branch.thread_id), true, "checkpoint branch fixture cleanup")

  local imported, created = backend.import_native_session(pane_id, {
    sessionId = "native-imported",
    cwd = root,
    title = "Imported contract session",
    summary = "import fixture",
    updatedAt = "2026-07-15T00:00:00Z",
  })
  assert_equal(created, true, "native thread import result")
  assert_equal(imported.provider_id, "ThreadFixture", "native thread provider")
  assert_equal(imported.native_session_id, "native-imported", "native thread session identity")
  assert_equal(imported.metadata.imported_from_native, true, "native thread import metadata")
  local duplicate, duplicate_created = backend.import_native_session(pane_id, {
    sessionId = "native-imported",
    cwd = root,
  })
  assert_equal(duplicate.thread_id, imported.thread_id, "native thread import deduplication")
  assert_equal(duplicate_created, false, "native thread duplicate result")

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
  assert_equal(pane_id, "thread-test-pane-2", "reopened backend pane")
  assert(vim.wait(5000, function()
    local snapshot = backend.get_runtime_snapshot(pane_id)
    return snapshot and snapshot.acp_ready == true
  end, 10), "reopened backend thread should become ready")

  local reopened_runtime = backend.get_runtime_snapshot(pane_id)
  assert_equal(reopened_runtime.acp_thread_id, runtime.acp_thread_id, "reopened thread identity")
  assert_equal(reopened_runtime.acp_transcript_path, runtime.acp_transcript_path, "reopened transcript identity")
  assert_equal(reopened_runtime.acp_resume_strategy, "native_resume", "native resume strategy")
  assert_equal(reopened_runtime.acp_has_pending_carryover, false, "native resume carryover")
  assert_equal(#assert(backend.list_threads({ include_archived = true })), 2, "reopen and import should not duplicate threads")
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

  local parallel_panes = {}
  for index = 1, 2 do
    backend.split(nil, 10, false, {
      on_split = function(created)
        parallel_panes[index] = created
      end,
      acp = {
        agent_name = "ParallelFixture-" .. tostring(index),
        provider_id = "ParallelFixture",
        command = fake_command,
        cwd = root,
        root_dir = root,
        additional_directories = { root .. "/tests" },
      },
    })
  end
  assert(vim.wait(5000, function()
    if #parallel_panes ~= 2 then
      return false
    end
    local first = backend.get_runtime_snapshot(parallel_panes[1])
    local second = backend.get_runtime_snapshot(parallel_panes[2])
    return first and first.acp_ready == true and second and second.acp_ready == true
  end, 10), "parallel provider threads should become ready")
  local first_parallel = backend.get_runtime_snapshot(parallel_panes[1])
  local second_parallel = backend.get_runtime_snapshot(parallel_panes[2])
  assert(first_parallel.acp_thread_id ~= second_parallel.acp_thread_id, "parallel threads need distinct UUIDs")
  assert_equal(first_parallel.acp_provider_id, "ParallelFixture", "first parallel provider")
  assert_equal(second_parallel.acp_provider_id, "ParallelFixture", "second parallel provider")
  local parallel_debug = backend.get_debug_snapshot()
  assert_equal(parallel_debug.session_count, 2, "parallel backend sessions")
  assert_equal(parallel_debug.child_process_count, 2, "parallel child processes")
  backend.kill_pane(parallel_panes[1])
  assert_equal(backend.get_debug_snapshot().session_count, 1, "independent parallel close")
  assert_equal(assert(backend.get_thread(second_parallel.acp_thread_id)).status, "active", "surviving parallel thread")
  backend.kill_pane(parallel_panes[2])
  assert_equal(backend.get_debug_snapshot().session_count, 0, "parallel teardown")

  state.opts = previous_opts
  vim.fn.delete(cache_dir, "rf")
end

return M
