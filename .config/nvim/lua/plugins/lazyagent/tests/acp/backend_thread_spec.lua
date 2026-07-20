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
    acp = { auto_permission = "allow_once", permissions = { dir = cache_dir .. "/permissions" } },
  })

  local killed = false
  local pane_seq = 0
  local transcript_is_read = false
  local on_transcript_read
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
    transcript_is_read = function()
      return transcript_is_read
    end,
    on_session_created = function(session)
      on_transcript_read = session.on_transcript_read
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
      editor = { instance_id = "backend-editor", owner_pid = vim.fn.getpid(), source_path = root .. "/README.md" },
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
  assert(backend.set_read_only_guard(pane_id, "fixture-review", true, "fixture review is read-only"))
  assert_equal(backend.get_runtime_snapshot(pane_id).acp_read_only_reason, "fixture review is read-only",
    "runtime exposes the active read-only guard")
  assert(backend.set_read_only_guard(pane_id, "fixture-review", false))
  assert_equal(backend.get_runtime_snapshot(pane_id).acp_read_only_reason, nil, "read-only guard is released")

  local store = require("lazyagent.acp.thread_store").new({ dir = cache_dir .. "/acp/threads" })
  local persisted = assert(store:get(runtime.acp_thread_id))
  assert_equal(persisted.status, "active", "active persisted thread")
  assert_equal(persisted.native_session_id, runtime.acp_session_id, "native session persistence")
  assert(persisted.process_id ~= nil, "process identity persistence")
  assert_equal(persisted.transcript_path, runtime.acp_transcript_path, "transcript persistence")
  assert_equal(persisted.metadata.editor.instance_id, "backend-editor", "editor ownership persistence")

  local previous_status_session = state.sessions.ThreadFixture
  local status_session = { backend = "buffer_acp", pane_id = pane_id }
  state.sessions.ThreadFixture = status_session
  local agentmux = require("lazyagent.integrations.agentmux")
  local previous_agentmux_sync = agentmux.sync
  agentmux.sync = function() return true end

  local previous_select = vim.ui.select
  vim.ui.select = function() end
  state.opts.acp.auto_permission = nil
  state.opts.acp_auto_permission = nil
  state.opts.acp.permission_rules = {}
  state.opts.acp_permission_rules = {}
  state._fix_requested = false
  assert(backend.paste_and_submit(pane_id, "exercise mobile permission", { "C-m" }, {}))
  local permission_pending = vim.wait(3000, function() return backend.get_pending_permission(pane_id) ~= nil end, 10)
  assert(permission_pending, "backend permission should become pending: " .. vim.inspect({
    client = backend.get_runtime_snapshot(pane_id).acp_client_debug,
    events = backend.get_runtime_snapshot(pane_id).acp_protocol_events,
    acp = state.opts.acp,
  }))
  local pending = backend.get_pending_permission(pane_id)
  assert_equal(pending.tool_call_id, "tool-1", "pending permission tool")
  assert_equal(assert(store:get(runtime.acp_thread_id)).metadata.has_user_prompt, true, "first prompt persistence marker")
  assert(vim.tbl_contains(vim.tbl_map(function(choice) return choice.scope end, pending.choices), "project"),
    "pending permission project scope")
  assert(backend.respond_permission(pane_id, "allow-once", "project"))
  assert_equal(backend.get_pending_permission(pane_id), nil, "mobile permission response clears pending state")
  assert_equal(status_session.agent_status, "thinking", "accepted permission resumes agent status")

  state.opts.acp.auto_permission = "allow_once"
  vim.ui.select = previous_select
  agentmux.sync = previous_agentmux_sync
  state.sessions.ThreadFixture = previous_status_session

  local export_path = cache_dir .. "/exports/thread.md"
  assert_equal(backend.export_thread_markdown(pane_id, export_path), export_path, "thread Markdown export path")
  local exported_markdown = table.concat(vim.fn.readfile(export_path), "\n")
  assert(exported_markdown:match("# ThreadFixture"), "thread Markdown export title")
  assert(exported_markdown:match("Connecting ACP session"), "thread Markdown export content")

  assert(backend.update_thread(runtime.acp_thread_id, {
    change_journal = {
      turns = { { turn_id = runtime.acp_thread_id .. ":checkpoint", changes = {
        { operation = "modified", path = "fixture.bin", binary = true },
        (function()
          local blobs = require("lazyagent.acp.blob_store").new({
            dir = cache_dir .. "/acp/blobs",
            max_blob_bytes = false,
          })
          local before = assert(blobs:put(string.rep("a", 1100 * 1024)))
          local after = assert(blobs:put(string.rep("b", 1100 * 1024)))
          return {
            operation = "modified",
            path = "large.txt",
            binary = false,
            before_blob = before,
            after_blob = after,
          }
        end)(),
      } } },
    },
  }))
  local review = assert(backend.get_thread_review(runtime.acp_thread_id))
  assert_equal(review.changes[1].path, "fixture.bin", "mobile review snapshot")
  assert_equal(review.changes[2].diff, "Diff omitted because the file pair exceeds 2 MiB.",
    "large review is classified from blob sizes before diffing")
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
  assert_equal(assert(backend.get_thread(runtime.acp_thread_id)).metadata.editor.instance_id, "backend-editor",
    "reopen preserves editor ownership metadata")
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
  assert_equal(type(on_transcript_read), "function", "transcript read callback")
  assert(backend.update_thread(runtime.acp_thread_id, { unread = true }))
  on_transcript_read()
  assert_equal(backend.get_runtime_snapshot(pane_id).acp_thread_unread, false, "returning to transcript end marks read")
  assert(backend.set_thread_draft(runtime.acp_thread_id, "updated draft"))
  assert_equal(backend.get_runtime_snapshot(pane_id).acp_thread_draft, "updated draft", "thread draft update")

  local previous_open_agent = state.open_agent
  state.open_agent = nil
  transcript_is_read = false
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
  assert_equal(backend.get_thread(first_parallel.acp_thread_id), nil, "promptless first thread is discarded")
  assert_equal(backend.get_thread(second_parallel.acp_thread_id), nil, "promptless second thread is discarded")
  assert_equal(vim.fn.filereadable(first_parallel.acp_transcript_path), 0, "promptless first transcript is discarded")
  assert_equal(vim.fn.filereadable(second_parallel.acp_transcript_path), 0, "promptless second transcript is discarded")

  state.opts = previous_opts
  vim.fn.delete(cache_dir, "rf")
end

return M
