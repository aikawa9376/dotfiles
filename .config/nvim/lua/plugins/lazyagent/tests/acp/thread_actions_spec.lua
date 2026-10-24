local M = {}

local THREAD_ID = "123e4567-e89b-42d3-a456-426614174000"

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local records = {}
  local opened
  local changes_thread_id
  local changes_backend
  local comparison_thread_id
  local create_request
  local resolved_active_agent
  local state = { backends = {}, editor_instance_id = "test-nvim" }
  local view_cache = vim.fn.tempname() .. "-cockpit-view-cache"
  state.opts = { cache = { dir = view_cache } }
  local backend = {}
  local live_records = {}
  local live_backend = {}
  local failed_runtime = false
  local runtime_extra = {}
  local queue_pane, pending_permission, permission_response
  local list_reads = 0
  state.backends.buffer_acp = backend
  state.backends.tmux_acp = live_backend
  function backend.get_thread(thread_id)
    return records[thread_id]
  end
  function live_backend.get_thread(thread_id, opts)
    if opts and opts.include_live then
      return live_records[thread_id] or records[thread_id]
    end
    return records[thread_id]
  end
  function backend.create_thread(attributes)
    local record = vim.tbl_extend("force", vim.deepcopy(attributes), {
      thread_id = THREAD_ID,
      status = "closed",
    })
    records[THREAD_ID] = record
    return vim.deepcopy(record)
  end
  function backend.archive_thread(thread_id)
    records[thread_id].status = "archived"
    return vim.deepcopy(records[thread_id])
  end
  function backend.restore_thread(thread_id)
    records[thread_id].status = "closed"
    return vim.deepcopy(records[thread_id])
  end
  function backend.rename_thread(thread_id, title)
    records[thread_id].title = title
    records[thread_id].metadata = records[thread_id].metadata or {}
    records[thread_id].metadata.title_source = "manual"
    return vim.deepcopy(records[thread_id])
  end
  live_backend.rename_thread = backend.rename_thread
  function backend.update_thread(thread_id, changes, opts)
    local record = records[thread_id]
    if not record then return nil, "not found" end
    local expected_pid = opts and opts.expected_process_id ~= vim.NIL and opts.expected_process_id or nil
    if opts and opts.expected_process_id ~= nil and record.process_id ~= expected_pid then
      return nil, { code = "stale_process" }
    end
    for key, value in pairs(changes or {}) do
      if value == vim.NIL then
        record[key] = nil
      elseif key == "metadata" then
        record[key] = vim.tbl_deep_extend("force", record[key] or {}, vim.deepcopy(value))
      else
        record[key] = vim.deepcopy(value)
      end
    end
    return vim.deepcopy(record)
  end
  function backend.delete_thread(thread_id)
    records[thread_id] = nil
    return true
  end
  function backend.list_threads()
    list_reads = list_reads + 1
    return vim.tbl_values(records)
  end
  function backend.get_cockpit_activity() return runtime_extra.acp_activity end
  function backend.mark_thread_observed(thread_id)
    local record = records[thread_id]
    record.metadata.cockpit_observation = require("lazyagent.acp.cockpit_review").snapshot(record)
    record.metadata.cockpit_observation.observed_at = "2026-10-24T00:00:00Z"
    return record
  end
  function backend.set_thread_review_state(thread_id, review_state, opts)
    local record = records[thread_id]
    local Review = require("lazyagent.acp.cockpit_review")
    if opts.require_enabled and not Review.enabled(record) then return nil, "Tracking was disabled" end
    if opts.expected_version and opts.expected_version ~= Review.version(record) then
      return nil, { code = "stale_cockpit", message = "Thread changed" }
    end
    record.metadata.cockpit_review = {
      thread_id = thread_id, enabled = review_state ~= "off", state = review_state, revision = Review.code_revision(record), fingerprint = opts.fingerprint,
    }
    return record
  end
  function backend.get_runtime_snapshot()
    if failed_runtime then return { acp_failed = true, acp_process_id = 2147483647 } end
    return vim.tbl_extend("force", {
      acp_thread_id = THREAD_ID,
      acp_ready = true,
      acp_prompt_queue = {},
    }, runtime_extra)
  end
  function backend.show_prompt_queue(pane_id) queue_pane = pane_id end
  function backend.get_pending_permission() return pending_permission end
  function backend.respond_permission(pane_id, option_id, scope, request_id)
    if not pending_permission or pending_permission.request_id ~= request_id then return nil, "expired" end
    permission_response = { pane_id, option_id, scope, request_id }
    pending_permission = nil
    return true
  end
  function backend.get_view_snapshot()
    return {
      source = "buffer",
      lines = { "# User", "live prompt", "", "# Assistant", "live mirror" },
      line_count = 5,
      changedtick = 7,
    }
  end
  function backend.show_thread_changes(thread_id)
    changes_thread_id = thread_id
    changes_backend = "buffer_acp"
    return records[thread_id] ~= nil
  end
  function backend.show_thread_changes_since_check(thread_id)
    comparison_thread_id = thread_id
    return true
  end
  function live_backend.show_thread_changes(thread_id)
    changes_thread_id = thread_id
    changes_backend = "tmux_acp"
    return live_records[thread_id] ~= nil or records[thread_id] ~= nil
  end

  local actions = require("lazyagent.logic.session.threads").setup({
    state = state,
    acp_logic = {
      is_acp_backend = function(name)
        return name == "buffer_acp"
      end,
    },
    agent_logic = {
      available_acp_agents = function()
        return { "Codex" }
      end,
      get_interactive_agent = function(provider_id)
        return provider_id == "Codex" and { acp = true } or nil
      end,
    },
    backend_logic = {
      resolve_backend_for_agent = function()
        return "buffer_acp", backend
      end,
    },
    start_interactive_session = function(opts)
      opened = opts
    end,
    close_session = function(key)
      state.sessions[key] = nil
    end,
    resolve_active_acp_session = function(agent_name, callback)
      resolved_active_agent = agent_name
      callback("Codex")
    end,
    editor_registry = {
      targets = function(root)
        return { { instance_id = "target-nvim", label = "Target Neovim", roots = { root } } }
      end,
      request_create_agent = function(target, provider, root)
        create_request = { target = target, provider = provider, root = root }
        return true
      end,
    },
  })

  assert_equal(actions.new_thread("Codex"), true, "new thread action")
  assert_equal(opened.agent_name, "Codex", "new thread provider")
  assert_equal(opened.acp_thread_id, THREAD_ID, "new thread open UUID")
  assert_equal(actions.new_thread_in_workspace("Codex", "/tmp"), true, "workspace thread action")
  assert_equal(records[THREAD_ID].cwd, "/tmp", "workspace thread cwd")
  assert_equal(actions.request_new_agent("/tmp", "Codex"), true, "remote new agent request")
  assert_equal(create_request.provider, "Codex", "remote new agent provider")
  assert_equal(create_request.root, "/tmp", "remote new agent workspace")
  assert_equal(actions.rename_thread(THREAD_ID, "Renamed"), true, "rename thread action")
  assert_equal(records[THREAD_ID].title, "Renamed", "renamed thread title")
  records[THREAD_ID].transcript_path = "/tmp/named-thread.md"
  local PROVIDER_NAMED_ID = "123e4567-e89b-42d3-a456-426614174096"
  records[PROVIDER_NAMED_ID] = {
    thread_id = PROVIDER_NAMED_ID,
    provider_id = "Codex",
    title = "Provider title",
    status = "closed",
    metadata = { title_source = "provider" },
    transcript_path = "/tmp/provider-thread.md",
  }
  local named_items, named_opts, named_callback
  local named_select = vim.ui.select
  vim.ui.select = function(items, opts, callback)
    named_items, named_opts, named_callback = items, opts, callback
  end
  assert_equal(actions.pick_named_threads(), true, "named thread picker action")
  vim.ui.select = named_select
  assert_equal(#named_items, 1, "named picker only includes manual titles")
  assert_equal(named_items[1].thread_id, THREAD_ID, "named picker thread")
  assert_equal(named_opts.kind, "lazyagent-acp-names", "named picker preview UI kind")
  assert_equal(named_opts.previewer, "builtin", "named picker enables transcript preview")
  assert(named_opts.format_item(named_items[1]):find("/tmp/named-thread.md", 1, true),
    "named picker entry carries its transcript path")
  opened = nil
  named_callback(named_items[1])
  assert_equal(opened.acp_thread_id, THREAD_ID, "named picker resumes the selected thread")
  records[PROVIDER_NAMED_ID] = nil
  assert_equal(actions.archive_thread(THREAD_ID), true, "archive thread action")
  assert_equal(records[THREAD_ID].status, "archived", "archived thread status")
  assert_equal(actions.restore_thread(THREAD_ID), true, "restore thread action")
  assert_equal(records[THREAD_ID].status, "closed", "restored thread status")

  local workspace = vim.fn.tempname() .. "-thread-workspace"
  vim.fn.mkdir(workspace, "p")
  local source_path = workspace .. "/source.lua"
  vim.fn.writefile({ "return true" }, source_path)
  records[THREAD_ID].cwd = workspace
  records[THREAD_ID].metadata = { editor = { source_path = source_path } }
  opened = nil
  assert_equal(actions.open_thread(THREAD_ID), true, "open closed workspace thread")
  assert_equal(opened.root_dir, workspace, "closed thread keeps persisted workspace")
  assert_equal(vim.api.nvim_buf_get_name(opened.source_bufnr), source_path, "closed thread restores source anchor")
  records[THREAD_ID].native_session_id = "native-explicit"
  opened = nil
  assert_equal(actions.open_thread(THREAD_ID, { activation_mode = "load" }), true,
    "explicit load uses the shared thread-open path")
  assert_equal(opened.acp.session_bootstrap.session_mode, "load", "explicit load mode remains explicit")
  assert_equal(opened.acp.session_bootstrap.session_id, "native-explicit", "explicit load native identity")

  local FOREIGN_ID = "123e4567-e89b-42d3-a456-426614174099"
  records[THREAD_ID].change_journal = { turns = {} }
  records[THREAD_ID].metadata.editor.owner_pid = vim.fn.getpid()
  records[THREAD_ID].metadata.editor.instance_id = "test-nvim"
  records[THREAD_ID].status = "active"
  records[THREAD_ID].process_id = 42
  live_records[THREAD_ID] = vim.deepcopy(records[THREAD_ID])
  live_records[THREAD_ID].change_journal = { turns = { { changes = { { path = "source.lua" } } } } }
  state.sessions = {
    Codex = {
      pane_id = "acp:live-preview",
      backend = "tmux_acp",
      provider_id = "Codex",
      thread_id = THREAD_ID,
    },
  }
  assert_equal(actions.rename_active_thread("  Active session name  ", "Codex"), true, "rename active thread action")
  assert_equal(resolved_active_agent, "Codex", "rename active thread target")
  assert_equal(records[THREAD_ID].title, "Active session name", "active thread title is trimmed")
  records[FOREIGN_ID] = {
    thread_id = FOREIGN_ID,
    provider_id = "Codex",
    title = "Foreign changes",
    cwd = "/tmp/foreign",
    status = "closed",
    metadata = { editor = { instance_id = "other-nvim", owner_pid = vim.fn.getpid() + 1 } },
    change_journal = { turns = { { changes = { { path = "foreign.lua" } } } } },
  }
  local STOPPED_ID = "123e4567-e89b-42d3-a456-426614174097"
  records[STOPPED_ID] = {
    thread_id = STOPPED_ID,
    provider_id = "Codex",
    title = "Stopped local changes",
    cwd = workspace,
    status = "closed",
    metadata = { editor = { instance_id = "test-nvim", owner_pid = vim.fn.getpid() } },
    change_journal = { turns = { { changes = { { path = "stopped.lua" } } } } },
  }
  local selected_threads
  local previous_select = vim.ui.select
  rawset(vim.ui, "select", function(items) selected_threads = items end)
  changes_thread_id = nil
  changes_backend = nil
  assert_equal(actions.show_thread_changes(), true, "show current Neovim live preview changes")
  assert_equal(selected_threads, nil, "single live changed thread skips picker")
  assert_equal(changes_thread_id, THREAD_ID, "single changed thread opens directly")
  assert_equal(changes_backend, "tmux_acp", "live changes use the owning session backend")

  local SECOND_ID = "123e4567-e89b-42d3-a456-426614174098"
  records[SECOND_ID] = {
    thread_id = SECOND_ID,
    provider_id = "Codex",
    title = "Second local changes",
    cwd = workspace,
    status = "active",
    process_id = 43,
    metadata = { editor = { instance_id = "test-nvim", owner_pid = vim.fn.getpid() } },
    change_journal = { turns = { { changes = { { path = "second.lua" } } } } },
  }
  state.sessions.Second = {
    pane_id = "acp:persisted-preview",
    backend = "buffer_acp",
    provider_id = "Codex",
    thread_id = SECOND_ID,
  }
  selected_threads = nil
  assert_equal(actions.show_thread_changes(), true, "show multiple current Neovim changes")
  rawset(vim.ui, "select", previous_select)
  assert_equal(selected_threads and #selected_threads, 2, "multiple live changed threads keep picker")
  assert(not vim.tbl_contains(selected_threads or {}, records[STOPPED_ID]), "stopped changed thread is excluded")
  records[SECOND_ID] = nil
  live_records[THREAD_ID] = nil
  state.sessions = {}
  records[STOPPED_ID] = nil
  records[FOREIGN_ID] = nil

  local transcript_path = vim.fn.tempname() .. "-thread-transcript.log"
  vim.fn.writefile({ "# User", "hello" }, transcript_path)
  records[THREAD_ID].transcript_path = transcript_path
  local tab_count = vim.fn.tabpagenr("$")
  assert_equal(actions.open_thread_transcript(THREAD_ID), true, "open persisted raw transcript")
  assert_equal(vim.fn.tabpagenr("$"), tab_count + 1, "raw transcript tab")
  assert_equal(vim.api.nvim_buf_get_name(0), transcript_path, "raw transcript path")
  assert_equal(vim.bo.filetype, "markdown", "raw transcript markdown filetype")
  assert_equal(vim.bo.readonly, true, "raw transcript readonly")
  assert_equal(vim.wo.wrap, false, "raw transcript nowrap")
  vim.cmd("tabclose")
  pcall(vim.api.nvim_buf_delete, vim.fn.bufnr(transcript_path), { force = true })
  vim.fn.delete(transcript_path)

  local guard_pid = vim.fn.getpid()
  records[THREAD_ID].process_id = guard_pid
  records[THREAD_ID].status = "active"
  opened = nil
  assert_equal(actions.open_thread(THREAD_ID), false, "foreign live thread open guard")
  assert_equal(opened, nil, "foreign live thread does not launch duplicate")
  local changed_ok, changed_err = actions.open_thread(THREAD_ID, { restart_process_id = guard_pid + 1 })
  assert_equal(changed_ok, false, "native restart rejects changed ownership")
  assert_equal(changed_err, "owner_changed", "native restart ownership mismatch")
  assert_equal(actions.open_thread(THREAD_ID, { restart_process_id = guard_pid }), true,
    "native restart claims the captured process owner")
  assert_equal(records[THREAD_ID].status, "closed", "native restart closes captured owner record")
  assert_equal(records[THREAD_ID].process_id, nil, "native restart clears captured owner process")
  assert_equal(opened.acp_thread_id, THREAD_ID, "native restart resumes the same thread")
  records[THREAD_ID].process_id = 99
  records[THREAD_ID].status = "active"
  opened = nil
  assert_equal(actions.archive_thread(THREAD_ID), false, "active archive guard")
  assert_equal(actions.delete_thread(THREAD_ID), false, "active delete guard")
  local preserved_metadata = records[THREAD_ID].metadata
  records[THREAD_ID].process_id = 2147483647
  assert_equal(actions.close_disconnected_thread(THREAD_ID), true, "recover disconnected thread")
  assert_equal(records[THREAD_ID].status, "closed", "recovered thread status")
  assert_equal(records[THREAD_ID].process_id, nil, "recovered thread process detachment")
  assert_equal(records[THREAD_ID].metadata, preserved_metadata, "recovery preserves thread data")
  records[THREAD_ID].status = "active"
  records[THREAD_ID].process_id = 2147483647
  assert_equal(actions.open_thread(THREAD_ID), true, "dead process resumes without manual recovery")
  assert_equal(records[THREAD_ID].status, "closed", "dead process is persisted as closed before resume")
  records[THREAD_ID].status = "active"
  records[THREAD_ID].process_id = nil
  assert_equal(actions.open_thread(THREAD_ID), true, "missing PID is recoverable before resume")
  assert_equal(records[THREAD_ID].status, "closed", "missing PID is normalized to closed")
  state.sessions = { Stale = { thread_id = THREAD_ID, pane_id = "stale", backend = "buffer_acp" } }
  failed_runtime = true
  opened = nil
  assert_equal(actions.open_thread(THREAD_ID), true, "failed exited runtime can be reopened")
  assert_equal(state.sessions.Stale, nil, "dead runtime is cleaned up before reopening")
  assert_equal(opened.acp_thread_id, THREAD_ID, "dead runtime reopens the same persisted thread")
  failed_runtime = false
  records[THREAD_ID].status = "active"
  records[THREAD_ID].process_id = vim.fn.getpid()
  assert_equal(actions.close_disconnected_thread(THREAD_ID), false, "live process recovery guard")
  assert_equal(records[THREAD_ID].status, "active", "live process remains active")
  local process_exited = false
  local orphan = vim.system({ "sleep", "30" }, {}, function() process_exited = true end)
  records[THREAD_ID].process_id = orphan.pid
  local original_select = vim.ui.select
  local orphan_metadata = records[THREAD_ID].metadata
  records[THREAD_ID].metadata = { editor = { owner_pid = vim.fn.getpid(), instance_id = "other-editor" } }
  assert_equal(actions.close_disconnected_thread(THREAD_ID), false, "another live editor retains process ownership")
  records[THREAD_ID].metadata = orphan_metadata
  vim.ui.select = function(_, _, callback) callback("Cancel") end
  assert_equal(actions.close_disconnected_thread(THREAD_ID), true, "orphan stop offers confirmation")
  assert_equal(require("lazyagent.acp.process").inspect(orphan.pid).alive, true, "cancel keeps process alive")
  assert_equal(records[THREAD_ID].status, "active", "cancel keeps thread active")
  vim.ui.select = function(_, _, callback) callback("Stop process and close thread") end
  local recovering = actions.close_disconnected_thread(THREAD_ID)
  vim.ui.select = original_select
  assert_equal(recovering, true, "disconnected live process can be stopped with confirmation")
  assert(vim.wait(3000, function() return records[THREAD_ID].status == "closed" and process_exited end, 10),
    "stopped disconnected process becomes closed")
  assert_equal(records[THREAD_ID].process_id, nil, "stopping orphan clears PID")
  assert_equal(records[THREAD_ID].metadata, preserved_metadata, "stopping orphan keeps history metadata")
  local stale_transcript_path = vim.fn.tempname() .. "-stale-thread-transcript.log"
  vim.fn.writefile({ "# User", "stale" }, stale_transcript_path)
  records[THREAD_ID].transcript_path = stale_transcript_path
  assert_equal(actions.force_delete_thread(THREAD_ID), true, "force delete active record")
  assert_equal(records[THREAD_ID], nil, "force deleted thread record")
  assert_equal(vim.fn.filereadable(stale_transcript_path), 0, "force deleted thread transcript")

  local cockpit_transcript_path = vim.fn.tempname() .. "-cockpit-live-transcript.log"
  vim.fn.writefile({ "# User", "hello", "", "# Assistant", "ready" }, cockpit_transcript_path)
  records[THREAD_ID] = {
    thread_id = THREAD_ID,
    provider_id = "Codex",
    title = "Live thread",
    cwd = "/tmp/live",
    status = "active",
    process_id = 42,
    transcript_path = cockpit_transcript_path,
    metadata = { has_user_prompt = true },
  }
  local FILTER_ID = "123e4567-e89b-42d3-a456-426614174096"
  local filter_transcript_path = vim.fn.tempname() .. "-cockpit-filter-transcript.log"
  vim.fn.writefile({ "# User", "Filtered preview thread", "", "# Assistant", "archived answer" }, filter_transcript_path)
  records[FILTER_ID] = {
    thread_id = FILTER_ID,
    provider_id = "Codex",
    title = "Codex",
    cwd = "/tmp/filtered",
    status = "closed",
    transcript_path = filter_transcript_path,
    metadata = { has_user_prompt = true },
  }
  -- Sessions started without a pre-created thread keep their provider-only key,
  -- even after the ACP backend assigns a persisted thread UUID.
  local session_key = "Codex"
  state.sessions = {
    [session_key] = {
      pane_id = "acp:1",
      backend = "buffer_acp",
      provider_id = "Codex",
      thread_id = THREAD_ID,
    },
  }
  state.open_agent = session_key
  local origin_winid = vim.api.nvim_get_current_win()
  vim.cmd("rightbelow vsplit")
  local selected_acp_winid = vim.api.nvim_get_current_win()
  local selected_acp_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(selected_acp_winid, selected_acp_bufnr)
  vim.b[selected_acp_bufnr].lazyagent_acp_agent = session_key
  vim.b[selected_acp_bufnr].lazyagent_acp_pane_id = "acp:1"
  vim.wo[selected_acp_winid].winhighlight = "Normal:TestACPActive,NormalNC:TestACPUsual"
  vim.cmd("rightbelow vsplit")
  local other_acp_winid = vim.api.nvim_get_current_win()
  local other_acp_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(other_acp_winid, other_acp_bufnr)
  vim.b[other_acp_bufnr].lazyagent_acp_agent = "Other"
  vim.b[other_acp_bufnr].lazyagent_acp_pane_id = "acp:2"
  vim.wo[other_acp_winid].winhighlight = "Normal:TestOtherActive,NormalNC:TestOtherUsual"
  vim.api.nvim_set_current_win(origin_winid)
  assert_equal(actions.open_cockpit(), true, "open interactive cockpit")
  local cockpit_winid = vim.api.nvim_get_current_win()
  local cockpit_bufnr = vim.api.nvim_get_current_buf()
  assert_equal(vim.bo[cockpit_bufnr].filetype, "lazyagent_acp_cockpit", "cockpit keeps focus beside preview")
  assert(table.concat(vim.api.nvim_buf_get_lines(cockpit_bufnr, 0, -1, false), "\n"):find("● %[idle%].-Live thread"),
    "cockpit marks the thread opened by this Neovim")
  state.open_agent = nil
  vim.cmd("normal r")
  assert(table.concat(vim.api.nvim_buf_get_lines(cockpit_bufnr, 0, -1, false), "\n"):find("● %[idle%].-Live thread"),
    "cockpit refresh preserves the current Neovim marker after scratch closes")
  for line, text in ipairs(vim.api.nvim_buf_get_lines(cockpit_bufnr, 0, -1, false)) do
    if text:find("Live thread", 1, true) then
      vim.api.nvim_win_set_cursor(0, { line, 0 })
      break
    end
  end
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = cockpit_bufnr })
  assert(
    vim.wo[selected_acp_winid].winhighlight:find("NormalNC:TestACPActive", 1, true),
    "cockpit selected live agent uses its active background"
  )
  assert(
    vim.wo[other_acp_winid].winhighlight:find("NormalNC:NormalNC", 1, true),
    "cockpit non-selected agent uses NormalNC"
  )
  local input_map = vim.fn.maparg("i", "n", false, true)
  assert(input_map.buffer == 1, "cockpit live message mapping")
  vim.cmd("normal i")
  assert_equal(opened.agent_name, session_key, "cockpit input reuses the exact runtime session key")
  assert_equal(opened.acp_thread_id, nil, "cockpit input does not derive a duplicate UUID session key")
  assert_equal(opened.window_type, "float", "cockpit input opens popup")
  assert_equal(opened.window_opts.height, 10, "cockpit input popup height")
  assert(vim.fn.maparg("]a", "n", false, true).buffer == 1, "cockpit next live mapping")
  assert(vim.fn.maparg("[a", "n", false, true).buffer == 1, "cockpit previous live mapping")
  assert(vim.fn.maparg("P", "n", false, true).buffer == 1, "cockpit preview toggle mapping")
  assert(vim.fn.maparg("<CR>", "n", false, true).buffer == 1, "cockpit mirror mapping")
  assert(vim.fn.maparg("b", "n", false, true).buffer == 1, "cockpit local branch mapping")
  assert(vim.fn.maparg("o", "n", false, true).buffer == 1, "cockpit open mapping")
  opened = nil
  vim.cmd("normal \r")
  assert_equal(opened, nil, "cockpit mirror does not open or resume thread")
  local preview_found = false
  local cockpit_preview_bufnr
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local preview_buf = vim.api.nvim_win_get_buf(winid)
    if vim.bo[preview_buf].filetype == "markdown" and vim.api.nvim_buf_get_name(preview_buf):find("Cockpit Preview", 1, true) then
      preview_found = true
      cockpit_preview_bufnr = preview_buf
      assert_equal(
        table.concat(vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false), "\n"),
        "# User\nlive prompt\n\n# Assistant\nlive mirror",
        "cockpit mirrors live ACP view text"
      )
      break
    end
  end
  assert_equal(preview_found, true, "cockpit transcript mirror window")
  local preview_winid = vim.fn.bufwinid(cockpit_preview_bufnr)
  assert(
    vim.api.nvim_get_option_value("fillchars", { win = preview_winid }):find("eob: ", 1, true),
    "cockpit preview hides end-of-buffer tildes"
  )
  vim.cmd("normal \r")
  local latest_lines = vim.api.nvim_buf_get_lines(cockpit_preview_bufnr, 0, -1, false)
  assert(table.concat(latest_lines, "\n"):find("ready", 1, true), "cockpit enter toggles back to latest response")

  local Cockpit = require("lazyagent.acp.cockpit")
  local original_response = Cockpit.latest_response
  local response_reads = 0
  Cockpit.latest_response = function(...)
    response_reads = response_reads + 1
    return original_response(...)
  end
  local function move_to(text)
    for row, line in ipairs(vim.api.nvim_buf_get_lines(cockpit_bufnr, 0, -1, false)) do
      if line:find(text, 1, true) then
        vim.api.nvim_win_set_cursor(cockpit_winid, { row, 0 })
        vim.api.nvim_exec_autocmds("CursorMoved", { buffer = cockpit_bufnr })
        return row
      end
    end
    error("missing cockpit row: " .. text)
  end
  move_to("Codex · Filtered") -- The fallback prompt title is rendered at the end of the card.
  vim.wait(250, function() return false end, 10)
  move_to("Live thread")
  vim.wait(300, function() return false end, 10)
  assert_equal(response_reads, 0, "cursor motion resets the 500ms preview debounce")
  move_to("Codex · Filtered")
  vim.wait(450, function() return false end, 10)
  assert_equal(response_reads, 0, "preview does not read transcripts before 500ms")
  assert(vim.wait(400, function() return response_reads > 0 end, 10), "settled cursor updates preview")
  assert_equal(response_reads, 1, "only the last cursor target is previewed")
  Cockpit.latest_response = original_response
  assert(table.concat(vim.api.nvim_buf_get_lines(cockpit_preview_bufnr, 0, -1, false), "\n"):find("archived answer", 1, true),
    "debounced preview displays the final selection")
  move_to("Live thread")
  vim.cmd("normal \r")
  -- The mirror polling timer must not switch selections ahead of the debounce.
  local previous_mirror = table.concat(vim.api.nvim_buf_get_lines(cockpit_preview_bufnr, 0, -1, false), "\n")
  move_to("Codex · Filtered")
  vim.wait(350, function() return false end, 10)
  assert_equal(table.concat(vim.api.nvim_buf_get_lines(cockpit_preview_bufnr, 0, -1, false), "\n"), previous_mirror,
    "mirror polling respects pending cursor delay")
  move_to("Live thread")
  vim.cmd("normal \r")

  for index = 1, 12 do
    local id = "history-page-" .. index
    records[id] = {
      thread_id = id, provider_id = "Codex", title = "Paged history " .. index,
      cwd = "/tmp/paged", status = "closed", updated_at = string.format("2026-10-%02d", index),
    }
  end
  vim.cmd("normal r")
  move_to("More history (2)")
  vim.cmd("normal \r")
  assert(table.concat(vim.api.nvim_buf_get_lines(cockpit_bufnr, 0, -1, false), "\n"):find("Paged history 1\n", 1, true),
    "more control reveals hidden history without opening an agent")
  move_to("Show less history")
  vim.cmd("normal \r")
  assert(table.concat(vim.api.nvim_buf_get_lines(cockpit_bufnr, 0, -1, false), "\n"):find("More history (2)", 1, true),
    "expanded history can be collapsed again")
  local BodySearch = require("lazyagent.acp.cockpit_search")
  local original_search_open, original_search_input = BodySearch.open, vim.ui.input
  local search_request
  BodySearch.open = function(candidates, text, opts)
    search_request = { candidates = candidates, text = text, owner = opts.owner_buf }
    return { close = function() end }
  end
  vim.ui.input = function(_, callback) callback("Search hidden history") end
  vim.cmd("normal g/")
  local paged_sources = 0
  for _, candidate in ipairs(search_request.candidates) do
    if candidate.thread_id:find("history-page-", 1, true) then paged_sources = paged_sources + 1 end
  end
  assert_equal(paged_sources, 12, "body search includes histories hidden by pagination")
  assert_equal(search_request.owner, cockpit_bufnr, "body search belongs to its Cockpit lifetime")
  BodySearch.open, vim.ui.input = original_search_open, original_search_input
  for index = 1, 12 do records["history-page-" .. index] = nil end
  vim.cmd("normal r")

  local saved_metadata = vim.deepcopy(records[THREAD_ID].metadata)
  local saved_unread = records[THREAD_ID].unread
  records[THREAD_ID].metadata.cockpit_completion = { id = "ui-turn" }
  records[THREAD_ID].unread = true
  runtime_extra = {
    acp_goal = { title = "Goal from provider" },
    acp_prompt_queue = { { id = "queued-1", text = "Review the callback" } },
  }
  vim.cmd("normal r")
  move_to("Live thread")
  vim.cmd("normal K")
  local function preview_text() return table.concat(vim.api.nvim_buf_get_lines(cockpit_preview_bufnr, 0, -1, false), "\n") end
  assert(preview_text():find("Goal from provider", 1, true), "details displays current provider goal")
  vim.fn.maparg("<Tab>", "n", false, true).callback()
  assert(preview_text():find("## Changes", 1, true), "Tab opens changes details")
  vim.fn.maparg("<Tab>", "n", false, true).callback()
  assert(preview_text():find("## Tests", 1, true), "Tab opens test details")
  vim.api.nvim_set_current_win(vim.fn.bufwinid(cockpit_preview_bufnr))
  vim.fn.maparg("<Tab>", "n", false, true).callback()
  assert(preview_text():find("Review the callback", 1, true), "preview forwards section keys to Cockpit")
  vim.cmd("normal Q")
  assert_equal(queue_pane, "acp:1", "details queue action targets exact live session")
  vim.api.nvim_set_current_win(cockpit_winid)
  vim.cmd("normal C")
  assert_equal(changes_thread_id, THREAD_ID, "details review uses existing thread changes action")

  pending_permission = { request_id = 10, title = "Write source", choices = { { label = "Allow once", option_id = "allow", scope = "once" } } }
  local saved_select = vim.ui.select
  local permission_callback, permission_choice
  vim.ui.select = function(items, _, callback) permission_choice, permission_callback = items[1], callback end
  vim.cmd("normal A")
  pending_permission = vim.tbl_extend("force", pending_permission, { request_id = 11 })
  permission_callback(permission_choice)
  assert_equal(permission_response, nil, "stale Cockpit permission picker cannot answer replacement request")
  vim.cmd("normal A")
  permission_callback(permission_choice)
  vim.ui.select = saved_select
  assert_equal(permission_response[4], 11, "permission action passes current request identity")

  vim.cmd("normal f")
  local attention_text = table.concat(vim.api.nvim_buf_get_lines(cockpit_bufnr, 0, -1, false), "\n")
  assert(attention_text:find("Attention view", 1, true) and not attention_text:find("Filtered preview thread", 1, true),
    "attention toggle excludes quiet history")
  vim.cmd("normal Z")
  assert(table.concat(vim.api.nvim_buf_get_lines(cockpit_bufnr, 0, -1, false), "\n"):find("No threads need attention", 1, true),
    "snoozed response leaves the attention view")
  vim.cmd("normal f")
  move_to("Live thread")
  vim.cmd("normal Z")
  vim.cmd("normal za")
  local collapsed = table.concat(vim.api.nvim_buf_get_lines(cockpit_bufnr, 0, -1, false), "\n")
  assert(collapsed:find("attention:1 · collapsed", 1, true) and not collapsed:find("Live thread", 1, true),
    "workspace fold preserves pending attention count")
  vim.cmd("normal za")
  move_to("Live thread")
  vim.cmd("normal m")
  assert_equal(records[THREAD_ID].metadata.cockpit_ack_completion, "ui-turn", "completion acknowledgement is persisted")
  assert_equal(records[THREAD_ID].unread, true, "acknowledgement does not change transcript read state")
  local saved_journal = vim.deepcopy(records[THREAD_ID].change_journal)
  records[THREAD_ID].change_journal = { turns = {} }
  vim.cmd("normal V")
  assert(preview_text():find("No checkpoint yet", 1, true), "since view requires an explicit checkpoint")
  vim.cmd("normal u")
  records[THREAD_ID].change_journal.turns[1] = {
    turn_id = "after-check", state = "completed", changes = { { path = "source.lua", after_blob = { hash = "one" } } },
  }
  vim.cmd("normal r")
  assert(preview_text():find("1 new turn(s) · 1 newly completed · 1 changed file(s)", 1, true),
    "since view shows journal changes after the checkpoint")
  vim.cmd("normal gC")
  assert_equal(comparison_thread_id, THREAD_ID, "comparison targets the selected thread")
  vim.api.nvim_set_current_win(vim.fn.bufwinid(cockpit_preview_bufnr))
  vim.cmd("normal u")
  assert(preview_text():find("No recorded changes since this checkpoint", 1, true), "preview forwards mark checked")
  assert_equal(records[THREAD_ID].unread, true, "mark checked preserves transcript unread")
  assert_equal(records[THREAD_ID].metadata.cockpit_ack_completion, "ui-turn", "mark checked preserves completion acknowledgement")
  vim.api.nvim_set_current_win(cockpit_winid)
  local review_choices, review_callback
  vim.ui.select = function(items, _, callback) review_choices, review_callback = items, callback end
  vim.cmd("normal w")
  assert_equal(#review_choices, 1, "unmanaged session only offers explicit enable")
  review_callback(review_choices[1])
  assert_equal(records[THREAD_ID].metadata.cockpit_review.enabled, true, "review tracking is explicitly enabled")
  vim.cmd("normal w")
  review_callback(review_choices[2])
  assert_equal(records[THREAD_ID].metadata.cockpit_review.state, "reviewing", "review picker saves manual state")
  local Fingerprint = require("lazyagent.acp.workspace_fingerprint")
  local saved_capture = Fingerprint.capture
  local fingerprint_callback
  Fingerprint.capture = function(_, callback)
    fingerprint_callback = callback
    return { kill = function() end }
  end
  vim.cmd("normal w")
  review_callback(review_choices[4])
  records[THREAD_ID].change_journal.turns[1].changes[1].after_blob.hash = "two"
  fingerprint_callback("workspace-version")
  assert_equal(records[THREAD_ID].metadata.cockpit_review.state, "reviewing", "done cannot approve a changed picker target")
  vim.cmd("normal w")
  review_callback(review_choices[4])
  fingerprint_callback("workspace-version")
  assert_equal(records[THREAD_ID].metadata.cockpit_review.state, "done", "done saves after workspace verification")
  assert_equal(records[THREAD_ID].metadata.cockpit_review.fingerprint, "workspace-version", "done stores verified workspace")
  vim.cmd("normal w")
  backend.set_thread_review_state(THREAD_ID, "off", {})
  review_callback(review_choices[2])
  assert_equal(records[THREAD_ID].metadata.cockpit_review.enabled, false, "stale state picker cannot re-enable disabled tracking")
  vim.cmd("normal w")
  review_callback(review_choices[1])
  vim.cmd("normal w")
  review_callback(review_choices[5])
  assert_equal(records[THREAD_ID].metadata.cockpit_review.enabled, false, "review tracking can be disabled")
  Fingerprint.capture = saved_capture
  vim.ui.select = saved_select
  records[THREAD_ID].change_journal = saved_journal
  vim.cmd("normal K")
  records[THREAD_ID].metadata = saved_metadata
  records[THREAD_ID].unread = saved_unread
  runtime_extra = {}
  vim.cmd("normal r")

  local Activity = require("lazyagent.acp.cockpit_activity")
  local activity_session = { busy = true, ready = true, cockpit_activity = { phase = "thinking", received_at = os.time() } }
  runtime_extra = { acp_busy = true, acp_activity = Activity.snapshot(activity_session) }
  vim.cmd("normal r")
  vim.wait(1200, function() return false end, 10) -- Drain preceding workflow refresh notifications.
  local activity_reads = list_reads
  activity_session.cockpit_activity.received_at = os.time() + 1
  runtime_extra.acp_activity = Activity.snapshot(activity_session)
  vim.wait(1300, function() return false end, 10)
  assert_equal(list_reads, activity_reads, "stream receipt alone does not reload persisted history")
  activity_session.tool_calls = { test = { title = "Run parser checks", status = "in_progress" } }
  runtime_extra.acp_activity = Activity.snapshot(activity_session)
  assert(vim.wait(1800, function() return list_reads > activity_reads end, 10), "activity transition refreshes without a journal event")
  vim.cmd("normal K")
  vim.fn.maparg("<Tab>", "n", false, true).callback() -- Since check -> Overview.
  assert(preview_text():find("Run parser checks", 1, true), "current tool reaches Overview automatically")
  vim.cmd("normal K")
  runtime_extra = {}
  vim.cmd("normal r")

  local original_input = vim.ui.input
  vim.ui.input = function(_, callback) callback("Filtered preview thread") end
  vim.cmd("normal /")
  vim.ui.input = original_input
  local filtered_cockpit = table.concat(vim.api.nvim_buf_get_lines(cockpit_bufnr, 0, -1, false), "\n")
  assert(filtered_cockpit:find("## /tmp/filtered", 1, true), "cockpit filter matches rendered transcript prompt")
  assert(not filtered_cockpit:find("Live thread", 1, true), "cockpit filter removes the previous selection")
  local filtered_preview = table.concat(vim.api.nvim_buf_get_lines(cockpit_preview_bufnr, 0, -1, false), "\n")
  assert(filtered_preview:find("archived answer", 1, true), "filtered cockpit previews its visible thread")
  BodySearch.open = function(candidates, text)
    search_request = { candidates = candidates, text = text }
    return { close = function() end }
  end
  vim.ui.input = function(_, callback) callback("archived answer") end
  vim.cmd("normal g/")
  assert_equal(#search_request.candidates, 1, "body search respects current metadata filter")
  assert_equal(search_request.text, "archived answer", "body search uses separate literal text")
  BodySearch.open = original_search_open
  vim.ui.input = function(_, callback) callback("unread:maybe") end
  vim.cmd("normal /")
  assert_equal(table.concat(vim.api.nvim_buf_get_lines(cockpit_bufnr, 0, -1, false), "\n"), filtered_cockpit,
    "invalid conditions preserve the previous filter and rows")
  vim.ui.input = function(_, callback) callback("Filtered history") end
  vim.cmd("normal S")
  local stored_views = require("lazyagent.acp.cockpit_views").new({ dir = view_cache .. "/acp/cockpit-views" })
  assert_equal(stored_views:get("Filtered history").query, "Filtered preview thread", "save captures current filter")
  vim.cmd("normal f")
  vim.ui.input = function(_, callback) callback("Attention history") end
  vim.cmd("normal S")
  assert_equal(stored_views:get("Attention history").attention_only, true, "save captures attention-only mode")
  vim.cmd("normal f")
  vim.ui.input = function(_, callback) callback("") end
  vim.cmd("normal /")
  local view_items, view_callback
  vim.ui.select = function(items, _, callback) view_items, view_callback = items, callback end
  vim.cmd("normal F")
  local saved_view
  for _, item in ipairs(view_items) do if item.name == "Filtered history" then saved_view = item end end
  assert(saved_view, "saved view is available alongside built-ins")
  view_callback(saved_view)
  assert(table.concat(vim.api.nvim_buf_get_lines(cockpit_bufnr, 0, -1, false), "\n"):find("View: Filtered history", 1, true),
    "restored view displays its name and filter")
  assert(preview_text():find("archived answer", 1, true), "view switch previews its visible result")
  vim.cmd("normal F")
  for _, item in ipairs(view_items) do if item.name == "Attention history" then view_callback(item); break end end
  assert(vim.api.nvim_buf_get_lines(cockpit_bufnr, 0, 1, false)[1]:find("Attention view", 1, true),
    "saved view restores attention-only mode")
  vim.cmd("normal F")
  view_callback(view_items[1])
  assert(table.concat(vim.api.nvim_buf_get_lines(cockpit_bufnr, 0, -1, false), "\n"):find("Live thread", 1, true),
    "built-in All threads clears filtering")
  vim.cmd("normal gF")
  for _, item in ipairs(view_items) do if item.name == "Filtered history" then view_callback(item); break end end
  assert_equal(view_items[2], "Delete", "delete view requires explicit selection")
  view_callback("Delete")
  assert_equal(#stored_views:list(), 1, "deleting saved view preserves other saved views")
  assert(records[THREAD_ID], "view deletion never deletes threads")
  vim.ui.select = saved_select
  vim.ui.input = function(_, callback) callback("") end
  vim.cmd("normal /")
  vim.ui.input = original_input
  for line, text in ipairs(vim.api.nvim_buf_get_lines(cockpit_bufnr, 0, -1, false)) do
    if text:find("Live thread", 1, true) then
      vim.api.nvim_win_set_cursor(0, { line, 0 })
      break
    end
  end
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = cockpit_bufnr })

  local menu_items, menu_opts, menu_callback
  local menu_select = vim.ui.select
  vim.ui.select = function(items, opts, callback)
    menu_items, menu_opts, menu_callback = items, opts, callback
  end
  vim.cmd("normal ?")
  vim.ui.select = menu_select
  assert_equal(menu_opts.kind, "lazyagent-acp-actions", "cockpit action menu uses compact cursor UI")
  assert_equal(menu_items[1].key, "<CR>", "cockpit action menu lists preview toggle")
  opened = nil
  menu_callback(menu_items[1])
  assert_equal(opened, nil, "cockpit menu preview action does not open thread")
  local mirrored_lines = vim.api.nvim_buf_get_lines(cockpit_preview_bufnr, 0, -1, false)
  assert(table.concat(mirrored_lines, "\n"):find("live mirror", 1, true), "cockpit action menu executes selected action")
  vim.cmd("normal o")
  assert_equal(opened.agent_name, session_key, "cockpit o opens the exact live agent under the cursor")
  assert_equal(opened.acp_thread_id, nil, "cockpit live open bypasses provider thread selection")
  assert_equal(opened.source_winid, cockpit_winid, "cockpit o places the ACP buffer in the cockpit tab")
  assert_equal(opened.origin_winid, cockpit_winid, "cockpit o keeps ACP focus in the cockpit tab")
  assert_equal(opened.relocate_agent_view, true, "cockpit o moves an existing ACP view into the cockpit tab")
  assert_equal(vim.b[opened.source_bufnr].lazyagent_workspace_root, "/tmp/live",
    "cockpit placement preserves the thread workspace context")
  assert_equal(opened.stay_hidden, false, "cockpit o reveals a hidden Team member session")
  assert_equal(opened.open_input, false, "cockpit o opens the ACP buffer without covering it with scratch")
  assert_equal(opened.focus_agent_view, false, "cockpit o leaves focus in the cockpit")
  opened = nil
  vim.cmd("normal O")
  assert_equal(opened.agent_name, session_key, "cockpit O opens the exact live agent under the cursor")
  assert_equal(opened.focus_agent_view, true, "cockpit O focuses the selected ACP buffer")
  vim.cmd("normal q")
  assert(
    vim.wo[selected_acp_winid].winhighlight:find("Normal:TestACPActive,NormalNC:TestACPUsual", 1, true),
    "closing cockpit restores selected ACP background"
  )
  assert(
    vim.wo[other_acp_winid].winhighlight:find("Normal:TestOtherActive,NormalNC:TestOtherUsual", 1, true),
    "closing cockpit restores other ACP background"
  )
  local resource_counts = require("tests.bench.resources")
  vim.wait(1100, function() return false end, 10)
  vim.api.nvim_exec_autocmds("SafeState", {})
  local cockpit_baseline = resource_counts.capture()
  for index = 1, 20 do
    assert_equal(actions.open_cockpit(), true, "reopen cockpit lifecycle fixture")
    local owner_win = vim.api.nvim_get_current_win()
    if index % 2 == 0 then
      vim.cmd("normal q")
    else
      vim.api.nvim_win_close(owner_win, true)
    end
    assert(vim.wait(500, function()
      for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(buffer):find("LazyAgent ACP Cockpit", 1, true) then return false end
      end
      return true
    end, 5), "closing cockpit retained its preview buffer on cycle " .. index)
  end
  vim.api.nvim_exec_autocmds("SafeState", {})
  local cockpit_final = resource_counts.capture()
  for _, kind in ipairs({ "buffers", "autocmds", "timers", "watchers" }) do
    assert_equal(cockpit_final[kind], cockpit_baseline[kind], "cockpit lifecycle releases " .. kind)
  end
  vim.api.nvim_win_close(other_acp_winid, true)
  vim.api.nvim_win_close(selected_acp_winid, true)
  pcall(vim.api.nvim_buf_delete, other_acp_bufnr, { force = true })
  pcall(vim.api.nvim_buf_delete, selected_acp_bufnr, { force = true })
  vim.fn.delete(cockpit_transcript_path)
  vim.fn.delete(view_cache, "rf")
  vim.fn.delete(filter_transcript_path)
  records[FILTER_ID] = nil
  pcall(vim.api.nvim_buf_delete, vim.fn.bufnr(source_path), { force = true })
  vim.fn.delete(workspace, "rf")
end

return M
